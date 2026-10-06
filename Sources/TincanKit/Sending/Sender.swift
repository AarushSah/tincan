import CryptoKit
import Foundation

/// How a bubble was delivered to Messages.
public enum SendMethod: String, Sendable, Codable {
    /// Typed into Messages; the recipient saw the typing bubble.
    case keyboard
    /// Handed to Messages after waiting as long as typing would take.
    case paced
    /// Handed to Messages immediately.
    case immediate
}

/// What happened to one bubble.
public struct BubbleOutcome: Sendable {
    public enum Status: String, Sendable, Codable {
        /// Messages recorded it and finished sending it.
        case sent
        /// The recipient's device received it.
        case delivered
        /// The recipient read it (only when they share read receipts).
        case read
        /// Messages reported an error.
        case failed
        /// tincan handed it over but did not see Messages finish sending it: no row appeared,
        /// the row was still sending when time ran out, or Messages did not answer. It may
        /// still go out.
        case unconfirmed
        /// Not attempted because an earlier bubble failed or was not confirmed.
        case skipped
    }

    public var text: String
    public var status: Status
    public var method: SendMethod?
    public var message: Message?
    public var error: String?
    /// Why the keyboard method was not used for this bubble, when it was requested.
    public var note: String?
    /// macOS refused to let tincan control Messages (Automation is off).
    public var automationDenied = false
    /// The carrier's notice that it didn't deliver this SMS or RCS bubble, which made it
    /// `failed` after Messages had sent it.
    public var bounce: Message?
}

/// Progress for live display.
public enum SendEvent: Sendable {
    case waiting(bubble: Int, seconds: TimeInterval)
    case typing(bubble: Int, seconds: TimeInterval)
    case sent(bubble: Int, outcome: BubbleOutcome)
    case fallback(bubble: Int, reason: String)
}

/// Sends bubbles one at a time, paced like a person, and confirms each one in Messages'
/// database before moving on: a new row with the bubble's text that Messages finished
/// sending. It never reports success it has not seen, and anything short of success stops
/// the remaining bubbles and files.
public final class Sender {
    public struct Request: Sendable {
        public var destination: SendDestination
        /// The conversation to confirm sends in, when one exists.
        public var chatID: Int64?
        public var plan: TypingPlan
        public var files: [String]
        public var method: SendMethod
        /// For the keyboard method: the address and titles that identify the conversation.
        public var keyboardAddress: String?
        public var keyboardService: MessageService
        public var expectedTitles: [String]

        public init(
            destination: SendDestination, chatID: Int64?, plan: TypingPlan, files: [String], method: SendMethod, keyboardAddress: String?,
            keyboardService: MessageService, expectedTitles: [String]
        ) {
            self.destination = destination
            self.chatID = chatID
            self.plan = plan
            self.files = files
            self.method = method
            self.keyboardAddress = keyboardAddress
            self.keyboardService = keyboardService
            self.expectedTitles = expectedTitles
        }
    }

    private let messages: MessagesDatabase
    private let automation: MessageSending
    /// How long to look for a sent message in the database.
    public var confirmationTimeout: TimeInterval = 12

    public init(messages: MessagesDatabase, automation: MessageSending) {
        self.messages = messages
        self.automation = automation
    }

    public func run(_ request: Request, progress: (SendEvent) -> Void) async -> [BubbleOutcome] {
        var outcomes: [BubbleOutcome] = []
        var keyboard: MessagesKeyboard?
        var keyboardNote: String?
        if request.method == .keyboard, let address = request.keyboardAddress {
            do {
                let typist = try MessagesKeyboard()
                try await typist.openConversation(address: address, service: request.keyboardService, expectedTitles: request.expectedTitles)
                try typist.ensureFieldEmpty()
                keyboard = typist
            } catch {
                keyboardNote = "typing indicator unavailable: \(error)"
                progress(.fallback(bubble: 0, reason: keyboardNote!))
            }
        } else if request.method == .keyboard {
            keyboardNote = "typing indicator is only available in one-to-one conversations"
            progress(.fallback(bubble: 0, reason: keyboardNote!))
        }

        var failed = false
        for (index, bubble) in request.plan.bubbles.enumerated() {
            if failed {
                outcomes.append(Self.skipped(bubble.text))
                continue
            }
            if bubble.pauseBefore > 0 {
                progress(.waiting(bubble: index, seconds: bubble.pauseBefore))
                await sleep(bubble.pauseBefore)
            }
            // Someone who starts using Messages partway through owns its message field.
            if keyboard != nil, MessagesKeyboard.messagesInUse {
                keyboard = nil
                keyboardNote = "typing stopped: someone is using Messages"
                progress(.fallback(bubble: index, reason: keyboardNote!))
            }
            var method = request.method
            var note = keyboardNote
            var outcome: BubbleOutcome
            func send(_ method: SendMethod) -> BubbleOutcome {
                hand(bubble.text, method: method) { try automation.send(text: bubble.text, to: request.destination) }
            }
            func confirm(_ outcome: BubbleOutcome, _ baseline: Int64) async -> BubbleOutcome {
                await finish(outcome, afterRowID: baseline, in: request.chatID, timeout: confirmationTimeout) { row in
                    Self.normalize(row.text) == Self.normalize(bubble.text) && isWithRecipient(row)
                }
            }
            // A send that starts a conversation has no chat to look in, so the row it finds
            // must be in a conversation with the address it went to.
            func isWithRecipient(_ row: Message) -> Bool {
                guard request.chatID == nil, case .address(let address, _) = request.destination else { return true }
                guard let chatID = row.chatID, let participants = try? messages.currentParticipants(ofChat: chatID) else { return false }
                let wanted = Address(address, region: nil).value
                return participants.contains { Address($0, region: nil).value == wanted }
            }

            // Confirmation only accepts rows newer than this, so an identical earlier message
            // can never be mistaken for this one. Without it nothing can be confirmed, so
            // nothing is sent.
            if let baseline = try? messages.latestRowID() {
                if let typist = keyboard {
                    progress(.typing(bubble: index, seconds: bubble.typingDuration))
                    do {
                        try await typist.type(bubble.text, delays: bubble.keystrokeDelays)
                        try typist.correct(to: bubble.text)
                        try typist.verifyStillShowing(request.expectedTitles)
                        // Send the exact text through Messages, then empty the field, the way pressing
                        // Return does. Synthetic Return presses don't reach Messages in the background.
                        outcome = send(.keyboard)
                        do {
                            try typist.clearField()
                        } catch {
                            // Already handed to Messages: never send it again. Pace the rest.
                            keyboard = nil
                            keyboardNote = "typing stopped: \(error); the message field may still hold the text"
                            note = keyboardNote
                            progress(.fallback(bubble: index, reason: keyboardNote!))
                        }
                        outcome = await confirm(outcome, baseline)
                    } catch {
                        // Clears only text tincan typed, in the conversation it opened.
                        let cleared = (try? typist.clearField()) != nil
                        keyboard = nil
                        note = "typing stopped: \(error)" + (cleared ? "" : "; the message field may still hold the text")
                        progress(.fallback(bubble: index, reason: note!))
                        method = .paced
                        outcome = send(method)
                        outcome = await confirm(outcome, baseline)
                    }
                } else {
                    if request.method != .immediate {
                        method = .paced
                        progress(.typing(bubble: index, seconds: bubble.typingDuration))
                        await sleep(bubble.typingDuration)
                    }
                    let sendBaseline = (try? messages.latestRowID()) ?? baseline
                    outcome = send(method)
                    outcome = await confirm(outcome, sendBaseline)
                }
            } else {
                outcome = Self.unreadable(bubble.text)
            }
            outcome.note = note
            progress(.sent(bubble: index, outcome: outcome))
            outcomes.append(outcome)
            if outcome.status == .failed || outcome.status == .unconfirmed { failed = true }
        }

        await keyboard?.restoreFocus()

        for file in request.files {
            if failed {
                outcomes.append(Self.skipped(file))
                continue
            }
            let name = (file as NSString).lastPathComponent
            var outcome = Self.unreadable(file)
            if let baseline = try? messages.latestRowID() {
                outcome = hand(file, method: .immediate) { try automation.send(file: file, to: request.destination) }
                outcome = await finish(outcome, afterRowID: baseline, in: request.chatID, timeout: confirmationTimeout * 2) {
                    $0.attachments.contains { $0.name == name }
                }
            }
            progress(.sent(bubble: outcomes.count, outcome: outcome))
            outcomes.append(outcome)
            if outcome.status == .failed || outcome.status == .unconfirmed { failed = true }
        }
        return outcomes
    }

    /// Re-reads sent messages until they are delivered or read, up to `timeout`.
    public func waitForReceipts(_ outcomes: [BubbleOutcome], until wanted: BubbleOutcome.Status, timeout: TimeInterval) async -> [BubbleOutcome] {
        var current = outcomes
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var pending = false
            for index in current.indices {
                guard let message = current[index].message, [.sent, .delivered].contains(current[index].status) else { continue }
                if let fresh = try? messages.message(id: message.id) {
                    current[index].message = fresh
                    current[index].status = Self.status(of: fresh)
                }
                let done = wanted == .read ? current[index].status == .read : current[index].status != .sent
                if !done && current[index].status != .failed { pending = true }
            }
            if !pending { break }
            await sleep(1)
        }
        return current
    }

    /// Looks for up to `timeout` seconds for a carrier's notice that SMS or RCS bubbles
    /// Messages sent didn't reach the recipient: an incoming message after them, in
    /// `chatID` or from `address` (canonical, read in `region`), that `CarrierBounce`
    /// recognizes. Every such bubble sent before a notice, and not delivered, becomes
    /// `failed` with the first notice after it in `bounce`, since a notice doesn't say which
    /// bubble it is about. Stops early once every SMS or RCS bubble is delivered or bounced.
    /// iMessage bubbles are left alone.
    public func checkForBounces(
        _ outcomes: [BubbleOutcome], in chatID: Int64?, from address: String?, region: String?, timeout: TimeInterval
    ) async -> [BubbleOutcome] {
        var current = outcomes
        func watched() -> [Int] {
            current.indices.filter { index in
                guard current[index].status == .sent, let message = current[index].message else { return false }
                return [.sms, .rcs].contains(message.service)
            }
        }
        guard timeout > 0, let first = watched().compactMap({ current[$0].message?.id }).min() else { return current }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let rows = try? messages.messages(afterRowID: first, limit: 50, includeFromMe: false) {
                let from = { (message: Message) -> Bool in
                    if let chatID, message.chatID == chatID { return true }
                    guard let address, let sender = message.sender else { return false }
                    return Address(sender, region: region).value == address
                }
                let notices = rows.filter { from($0) && CarrierBounce.matches($0.text) }
                for index in watched() {
                    guard let id = current[index].message?.id, let notice = notices.first(where: { $0.id > id }) else { continue }
                    current[index].status = .failed
                    current[index].bounce = notice
                    current[index].error = "the carrier sent back a notice that it wasn't delivered"
                }
            }
            for index in watched() {
                if let id = current[index].message?.id, let fresh = try? messages.message(id: id) {
                    current[index].message = fresh
                    if fresh.deliveredAt != nil || fresh.readAt != nil || fresh.failed { current[index].status = Self.status(of: fresh) }
                }
            }
            if watched().isEmpty || Date() >= deadline { return current }
            await sleep(0.5)
        }
    }

    // MARK: Internals

    /// Hands one bubble or file to Messages. A refusal fails it. A request Messages did not
    /// answer stays queued there and may still go out, so it is looked for like any other.
    private func hand(_ text: String, method: SendMethod, _ send: () throws -> Void) -> BubbleOutcome {
        do {
            try send()
            return BubbleOutcome(text: text, status: .sent, method: method, message: nil, error: nil, note: nil)
        } catch {
            var unanswered = false
            if case AutomationError.timedOut = error { unanswered = true }
            var outcome = BubbleOutcome(
                text: text, status: unanswered ? .unconfirmed : .failed, method: method, message: nil, error: String(describing: error), note: nil)
            if case AutomationError.notAuthorized = error { outcome.automationDenied = true }
            return outcome
        }
    }

    /// Looks for what `outcome` handed over: a row newer than `baseline` that `matches`, which
    /// Messages finished sending or failed. A row still sending when time runs out, or no row
    /// at all, is unconfirmed.
    private func finish(
        _ outcome: BubbleOutcome, afterRowID baseline: Int64, in chatID: Int64?, timeout: TimeInterval, matches: (Message) -> Bool
    ) async -> BubbleOutcome {
        guard outcome.status != .failed else { return outcome }
        let deadline = Date().addingTimeInterval(timeout)
        var sending: Message?
        while true {
            if let rows = try? messages.outgoing(inChat: chatID, afterRowID: baseline), let match = rows.first(where: matches) {
                if Self.isSettled(match) {
                    return BubbleOutcome(
                        text: outcome.text, status: Self.status(of: match), method: outcome.method, message: match,
                        error: match.failed ? "Messages error \(match.errorCode)" : nil, note: nil
                    )
                }
                sending = match
            }
            if Date() >= deadline { break }
            await sleep(0.4)
        }
        let error =
            outcome.error
            ?? (sending == nil
                ? "Messages did not record it within \(Int(timeout)) seconds" : "Messages had not finished sending it after \(Int(timeout)) seconds")
        return BubbleOutcome(text: outcome.text, status: .unconfirmed, method: outcome.method, message: sending, error: error, note: nil)
    }

    /// Whether Messages finished with a message: sent, delivered, read or failed.
    static func isSettled(_ message: Message) -> Bool {
        message.failed || message.isSent || message.deliveredAt != nil || message.readAt != nil
    }

    private static func skipped(_ text: String) -> BubbleOutcome {
        BubbleOutcome(text: text, status: .skipped, method: nil, message: nil, error: nil, note: nil)
    }

    private static func unreadable(_ text: String) -> BubbleOutcome {
        BubbleOutcome(
            text: text, status: .failed, method: nil, message: nil, error: "could not read Messages' database before sending, so nothing was sent", note: nil)
    }

    static func status(of message: Message) -> BubbleOutcome.Status {
        if message.failed { return .failed }
        if message.readAt != nil { return .read }
        if message.deliveredAt != nil { return .delivered }
        return .sent
    }

    /// Compares texts the way Messages may rewrite them: smart quotes, dashes and spacing.
    static func normalize(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacements: [(String, String)] = [
            ("\u{2018}", "'"), ("\u{2019}", "'"), ("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{2014}", "--"), ("\u{2013}", "-"), ("\u{2026}", "..."),
            ("\u{00A0}", " "),
        ]
        for (from, to) in replacements { result = result.replacingOccurrences(of: from, with: to) }
        return result
    }

    private func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

/// Recognizes the notices carriers text back when they refuse to deliver an SMS or RCS
/// message, such as "Free Msg: Unable to send message - Message Blocking is active". The
/// match is deliberately narrow, since it turns a sent message into a failed one: the text
/// must contain "Unable to send message" or "Message Blocking is active", or start with
/// "Free Msg:" and say the message couldn't be sent or delivered or was blocked. Case,
/// curly quotes and spacing don't matter.
public enum CarrierBounce {
    static let phrases = ["unable to send message", "message blocking is active"]
    static let freeMessageFailures = ["unable to send", "unable to deliver", "could not be sent", "could not be delivered", "not delivered", "blocked"]

    public static func matches(_ text: String) -> Bool {
        let folded = Sender.normalize(text).lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if phrases.contains(where: folded.contains) { return true }
        return folded.hasPrefix("free msg:") && freeMessageFailures.contains(where: folded.contains)
    }
}

/// The messages tincan sent: one JSON line per bubble Messages confirmed, with its GUID and
/// time, so reading can tell them from the ones you typed. It holds no text and no
/// recipient; those stay in Messages. A bubble Messages never confirmed has no GUID to
/// record.
public enum SendLedger {
    /// Where the ledger for this Mac's Messages is.
    public static var defaultPath: String {
        NSString(string: "~/Library/Application Support/tincan/sent.jsonl").expandingTildeInPath
    }

    public struct Entry: Codable, Sendable, Equatable {
        public let at: Date
        /// The message's GUID in Messages, which survives database rebuilds.
        public let guid: String

        public init(at: Date, guid: String) {
            self.at = at
            self.guid = guid
        }
    }

    /// Appends `entries` to the ledger at `path`, readable only by you.
    public static func append(_ entries: [Entry], to path: String = defaultPath) throws {
        guard !entries.isEmpty else { return }
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: path]) }
        defer { try? handle.close() }
        try handle.seekToEnd()
        var data = Data()
        for entry in entries {
            data.append(try encoder.encode(entry))
            data.append(0x0A)
        }
        try handle.write(contentsOf: data)
    }

    /// The GUIDs in the ledger at `path`. Lines that aren't entries are skipped.
    public static func guids(at path: String = defaultPath) -> Set<String> {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        var guids = Set<String>()
        for line in data.split(separator: 0x0A) {
            if let entry = try? decoder.decode(Entry.self, from: line) { guids.insert(entry.guid) }
        }
        return guids
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
