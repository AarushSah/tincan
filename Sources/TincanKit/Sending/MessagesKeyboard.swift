import AppKit
import ApplicationServices
import Foundation

/// Shows the other person the typing bubble by filling Messages' message field at a
/// person's pace.
///
/// Text goes into the field through Accessibility, one character at a time, without
/// keystrokes or bringing Messages forward. `Sender` then sends the exact text through
/// AppleScript and empties the field. Before typing, tincan checks that Messages shows the
/// intended conversation and that its message field is empty. Before every change to the
/// field, it checks that the conversation is still shown and that the field holds only what
/// tincan put there: someone who switched conversations or started typing owns the field,
/// and tincan stops without touching it. Any doubt throws before anything is sent.
public final class MessagesKeyboard {
    public enum Failure: Error, CustomStringConvertible, Sendable {
        case notTrusted
        case messagesNotRunning
        case conversationNotShown(expected: String)
        case messageFieldMissing
        case draftInField
        case keystrokesNotArriving
        case textMismatch
        /// The message field holds something tincan didn't put there.
        case fieldChanged
        /// Messages refused a change to the message field, or didn't answer in time.
        case fieldNotChanged(code: Int32)

        public var description: String {
            switch self {
            case .notTrusted: return "Accessibility isn't allowed for \(PermissionHost.current.subject)"
            case .messagesNotRunning: return "Messages is not running"
            case .conversationNotShown(let expected): return "Messages did not show the conversation with \(expected)"
            case .messageFieldMissing: return "the message field was not found"
            case .draftInField: return "there is unsent text in that conversation's message field"
            case .keystrokesNotArriving: return "typed text did not reach Messages"
            case .textMismatch: return "the message field did not match the text to send"
            case .fieldChanged: return "the message field changed while typing; someone may be using Messages"
            case .fieldNotChanged(let code):
                return code == AXError.cannotComplete.rawValue
                    ? "Messages did not answer Accessibility within \(Int(MessagesKeyboard.messagingTimeout)) seconds"
                    : "Messages did not accept a change to its message field (Accessibility error \(code))"
            }
        }
    }

    private let application: AXUIElement

    /// Longest wait for Messages to answer one Accessibility request. A Messages that stops
    /// answering then fails the typing, and the send paces instead of hanging.
    static let messagingTimeout: Float = 2

    public init() throws {
        guard AXIsProcessTrusted() else { throw Failure.notTrusted }
        if NSRunningApplication.runningApplications(withBundleIdentifier: Permissions.messagesBundleID).isEmpty {
            Permissions.launchMessagesInBackground()
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Permissions.messagesBundleID).first else {
            throw Failure.messagesNotRunning
        }
        application = AXUIElementCreateApplication(app.processIdentifier)
        // A timeout set on one element covers only that element; the system-wide one sets
        // this process's default, which covers the window and message field found later.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), Self.messagingTimeout)
        AXUIElementSetMessagingTimeout(application, Self.messagingTimeout)
        previousApplication = NSWorkspace.shared.frontmostApplication
    }

    /// Whether Messages is the app in front, which means someone may be using it.
    public static var messagesIsFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Permissions.messagesBundleID
    }

    /// Whether someone is using Messages: it is in front and the Mac had input recently.
    public static var messagesInUse: Bool {
        messagesIsFrontmost && Permissions.idleSeconds() < 30
    }

    /// The titles of the conversation tincan opened.
    private var expectedTitles: [String] = []
    /// What tincan last put in the message field. The field is tincan's only while it
    /// holds this.
    private var written = ""

    // MARK: Conversation

    /// Opens the one-to-one conversation with `address` without bringing Messages forward,
    /// then waits until Messages shows it. The title must switch to one that exactly equals
    /// an expected name or number; a title that merely contains the name (another "Maya"
    /// already on screen) is never accepted.
    public func openConversation(address: String, service: MessageService, expectedTitles: [String]) async throws {
        self.expectedTitles = expectedTitles
        let before = conversationTitles()
        if before.contains(where: { Self.title($0, exactlyMatches: expectedTitles) }) { return }
        let scheme = service == .sms || service == .rcs ? "sms" : "imessage"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+@._-"))
        guard let encoded = address.addingPercentEncoding(withAllowedCharacters: allowed),
            let url = URL(string: "\(scheme):\(encoded)")
        else { throw Failure.conversationNotShown(expected: address) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try? await NSWorkspace.shared.open(url, configuration: configuration)
        for _ in 0..<40 {
            let titles = conversationTitles()
            if titles != before, titles.contains(where: { Self.title($0, exactlyMatches: expectedTitles) }) {
                await restoreFocus(settle: true)
                return
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        await restoreFocus(settle: true)
        throw Failure.conversationNotShown(expected: expectedTitles.first ?? address)
    }

    private var previousApplication: NSRunningApplication?

    /// Messages can come forward when a conversation opens even when asked not to. Give the
    /// screen back to whatever app was in front before tincan started.
    public func restoreFocus(settle: Bool = false) async {
        if settle { try? await Task.sleep(nanoseconds: 400_000_000) }
        guard let previous = previousApplication, previous.bundleIdentifier != Permissions.messagesBundleID,
            Self.messagesIsFrontmost
        else { return }
        previous.activate()
    }

    /// Titles Messages shows for the current conversation: the window title (full name) and
    /// the header button (often a short name).
    public func conversationTitles() -> [String] {
        guard let window = attribute(application, kAXMainWindowAttribute) as! AXUIElement? ?? mainWindowFallback() else { return [] }
        var titles: [String] = []
        if let title = attribute(window, kAXTitleAttribute) as? String, !title.isEmpty { titles.append(title) }
        if let button = find(in: window, identifier: "ConversationTitle"), let description = attribute(button, kAXDescriptionAttribute) as? String,
            !description.isEmpty
        {
            titles.append(description)
        }
        return titles
    }

    /// A name as titles are compared: its letters and digits, ignoring case, accents,
    /// punctuation and spaces.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).filter { $0.isLetter || $0.isNumber }
    }

    /// Exact comparison: the same letters and digits ignoring case, accents and punctuation,
    /// or the same phone number (identical digits, allowing a leading North American 1).
    static func title(_ title: String, exactlyMatches expected: [String]) -> Bool {
        func digits(_ text: String) -> String {
            var value = text.filter(\.isNumber)
            if value.count == 11, value.hasPrefix("1") { value.removeFirst() }
            return value
        }
        let shown = fold(title)
        let shownDigits = digits(title)
        guard !shown.isEmpty else { return false }
        for candidate in expected {
            let wanted = fold(candidate)
            if wanted.count >= 2, shown == wanted { return true }
            let wantedDigits = digits(candidate)
            if wantedDigits.count >= 7, shownDigits == wantedDigits, title.filter(\.isLetter).isEmpty { return true }
        }
        return false
    }

    /// Fails unless Messages still shows the expected conversation, right before sending.
    public func verifyStillShowing(_ expectedTitles: [String]) throws {
        guard conversationTitles().contains(where: { Self.title($0, exactlyMatches: expectedTitles) }) else {
            throw Failure.conversationNotShown(expected: expectedTitles.first ?? "the recipient")
        }
    }

    // MARK: Typing

    /// Text currently in the message field.
    public func fieldText() throws -> String {
        guard let field = messageField() else { throw Failure.messageFieldMissing }
        return (attribute(field, kAXValueAttribute) as? String) ?? ""
    }

    public func ensureFieldEmpty() throws {
        if !(try fieldText()).isEmpty { throw Failure.draftInField }
        written = ""
    }

    /// The message field, while Messages still shows the conversation tincan opened and the
    /// field holds only what tincan put there, allowing for smart quotes and capitals.
    private func ownedField() throws -> AXUIElement {
        try verifyStillShowing(expectedTitles)
        guard let field = messageField() else { throw Failure.messageFieldMissing }
        let current = (attribute(field, kAXValueAttribute) as? String) ?? ""
        guard current == written || TextFolding.fold(current) == TextFolding.fold(written) else { throw Failure.fieldChanged }
        return field
    }

    /// Enters `text` into the message field at a person's pace, so Messages reports that you
    /// are typing. Messages ignores synthetic keystrokes while it is in the background, so
    /// tincan updates the field's text through Accessibility one character at a time.
    public func type(_ text: String, delays: [TimeInterval]) async throws {
        // No focus change: focusing the field would bring Messages to the front.
        var typed = ""
        for (index, character) in text.enumerated() {
            let delay = index < delays.count ? delays[index] : 0.1
            try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            let field = try ownedField()
            typed.append(character)
            try setValue(field, typed)
            written = typed
            // Early check that the field accepts text (a locked screen or a changed window won't).
            if typed.count == min(3, text.count) {
                try await Task.sleep(nanoseconds: 80_000_000)
                if (try? fieldText())?.isEmpty ?? true { throw Failure.keystrokesNotArriving }
            }
        }
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    /// Makes the field hold exactly `text`, fixing autocorrect or smart punctuation.
    public func correct(to text: String) throws {
        let field = try ownedField()
        if (attribute(field, kAXValueAttribute) as? String) == text { return }
        try setValue(field, text)
        written = text
        guard (attribute(field, kAXValueAttribute) as? String) == text else { throw Failure.textMismatch }
    }

    /// Empties the message field after a send, or after a failure so nothing half-typed is
    /// left behind. A field that is already empty is fine. Throws, leaving the field as it
    /// is, when it is gone, Messages refuses the change, or the field is no longer tincan's.
    public func clearField() throws {
        guard let field = messageField() else { throw Failure.messageFieldMissing }
        if ((attribute(field, kAXValueAttribute) as? String) ?? "").isEmpty {
            written = ""
            return
        }
        try setValue(try ownedField(), "")
        written = ""
    }

    private func setValue(_ field: AXUIElement, _ text: String) throws {
        let result = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, text as CFString)
        guard result == .success else { throw Failure.fieldNotChanged(code: result.rawValue) }
    }

    // MARK: Accessibility helpers

    private func messageField() -> AXUIElement? {
        guard let window = (attribute(application, kAXMainWindowAttribute) as! AXUIElement?) ?? mainWindowFallback() else { return nil }
        return find(in: window, identifier: "messageBodyField")
    }

    private func mainWindowFallback() -> AXUIElement? {
        (attribute(application, kAXWindowsAttribute) as? [AXUIElement])?.first
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func find(in element: AXUIElement, identifier: String, depth: Int = 0) -> AXUIElement? {
        if (attribute(element, kAXIdentifierAttribute) as? String) == identifier { return element }
        guard depth < 16 else { return nil }
        for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            // The transcript can hold thousands of bubbles; the message field is never inside it.
            if (attribute(child, kAXIdentifierAttribute) as? String) == "TranscriptCollectionView" { continue }
            if let found = find(in: child, identifier: identifier, depth: depth + 1) { return found }
        }
        return nil
    }
}
