import Foundation
import os

/// Where a send goes: an existing conversation, or an address on a service.
public enum SendDestination: Sendable, Equatable {
    /// An existing conversation by `chat.guid` (such as `any;-;+14155550142`), keeping its
    /// service. `address` is the other person in a one-to-one conversation, used when
    /// Messages' AppleScript does not know the conversation by any form of its GUID.
    case chat(guid: String, service: MessageService, address: String?)
    /// A phone number or email, on a service, for someone without a conversation yet.
    case address(String, service: MessageService)
}

public enum AutomationError: Error, CustomStringConvertible, Sendable {
    case notAuthorized
    case messagesFailed(code: Int, message: String)
    case attachmentUnreadable(String)
    /// Messages did not answer in time. The request stays queued in Messages, so it may
    /// still be sent.
    case timedOut(seconds: Int)

    public var description: String {
        switch self {
        case .notAuthorized: return "\(PermissionHost.current.subject) isn't allowed to control Messages"
        case .messagesFailed(_, let message): return "Messages refused the send: \(message)"
        case .attachmentUnreadable(let path): return "can't read \(path)"
        case .timedOut(let seconds): return "Messages did not respond within \(seconds) seconds and may still send it"
        }
    }
}

/// Hands messages to Messages. `MessagesAutomation` is the real one; tests use their own.
public protocol MessageSending: AnyObject {
    /// Sends `text`. Returning means Messages took it; throwing means it refused or did not
    /// answer (`AutomationError.timedOut`).
    func send(text: String, to destination: SendDestination) throws
    /// Sends the file at `path` the same way.
    func send(file path: String, to destination: SendDestination) throws
}

/// Sends through Messages' AppleScript interface. Message text is passed as a parameter
/// to a compiled handler, never pasted into script source, so no text can change the script.
public final class MessagesAutomation: MessageSending {
    private let handlers: Handlers

    private static let source = """
        on sendToChat(messageText, chatID)
            tell application "Messages" to send messageText to chat id chatID
        end sendToChat

        on sendToAddress(messageText, address, serviceName)
            tell application "Messages"
                set targetAccount to my accountFor(serviceName)
                send messageText to participant address of targetAccount
            end tell
        end sendToAddress

        on sendFileToChat(filePath, chatID)
            tell application "Messages" to send (POSIX file filePath) to chat id chatID
        end sendFileToChat

        on sendFileToAddress(filePath, address, serviceName)
            tell application "Messages"
                set targetAccount to my accountFor(serviceName)
                send (POSIX file filePath) to participant address of targetAccount
            end tell
        end sendFileToAddress

        on accountFor(serviceName)
            tell application "Messages"
                if serviceName is "SMS" then return 1st account whose service type = SMS
                if serviceName is "RCS" then return 1st account whose service type = RCS
                return 1st account whose service type = iMessage
            end tell
        end accountFor
        """

    /// Compiles the handlers on the main thread. Callers must not be on the main thread.
    public init() throws {
        let timeout: TimeInterval = 45
        guard let compiled = Self.onMainThread(timeout: timeout, { try Handlers() }) else {
            throw AutomationError.messagesFailed(code: 0, message: "compiling the AppleScript took longer than \(Int(timeout)) seconds")
        }
        handlers = try compiled.get()
    }

    /// The compiled script. NSAppleScript isn't thread-safe and must be used only on the main
    /// thread, so it is compiled, kept and run there, and only strings and errors leave it.
    @MainActor
    private final class Handlers {
        private let script: NSAppleScript

        init() throws {
            guard let script = NSAppleScript(source: MessagesAutomation.source) else {
                throw AutomationError.messagesFailed(code: 0, message: "could not create the AppleScript")
            }
            var error: NSDictionary?
            guard script.compileAndReturnError(&error) else {
                throw AutomationError.messagesFailed(code: 0, message: (error?[NSAppleScript.errorMessage] as? String) ?? "could not compile the AppleScript")
            }
            self.script = script
        }

        /// Runs one handler with string arguments and turns a failure into `AutomationError`.
        func run(_ handler: String, _ arguments: [String]) throws {
            let event = NSAppleEventDescriptor(
                eventClass: MessagesAutomation.appleScriptSuite,
                eventID: MessagesAutomation.subroutineEvent,
                targetDescriptor: NSAppleEventDescriptor.currentProcess(),
                returnID: AEReturnID(kAutoGenerateReturnID),
                transactionID: AETransactionID(kAnyTransactionID)
            )
            event.setParam(NSAppleEventDescriptor(string: handler), forKeyword: MessagesAutomation.subroutineName)
            let list = NSAppleEventDescriptor.list()
            for (index, argument) in arguments.enumerated() {
                list.insert(NSAppleEventDescriptor(string: argument), at: index + 1)
            }
            event.setParam(list, forKeyword: keyDirectObject)

            var error: NSDictionary?
            script.executeAppleEvent(event, error: &error)
            guard let error else { return }
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            if code == -1743 { throw AutomationError.notAuthorized }
            throw AutomationError.messagesFailed(code: code, message: (error[NSAppleScript.errorMessage] as? String) ?? "error \(code)")
        }
    }

    public func send(text: String, to destination: SendDestination) throws {
        try deliver(destination, textHandler: "sendtoaddress", chatHandler: "sendtochat", payload: text)
    }

    /// Copies `path` into Messages' attachments folder first; Messages reads files there
    /// reliably, while Desktop or Downloads can fail under its sandbox.
    public func send(file path: String, to destination: SendDestination) throws {
        Self.pruneStaging()
        let staged = try Self.stage(path)
        try deliver(destination, textHandler: "sendfiletoaddress", chatHandler: "sendfiletochat", payload: staged)
    }

    private var scriptIDs: [String: String] = [:]

    /// Hands `payload` to Messages for `destination`.
    ///
    /// One-to-one conversations are addressed by the other person's address on the
    /// conversation's service, which keeps the thread. Groups need the conversation's
    /// AppleScript id; current macOS stores `any;+;…` in the database while AppleScript may
    /// know `iMessage;+;…`, so each form is tried in turn. Messages rejects an unknown id
    /// before sending anything, so trying candidates can never send twice. (Asking Messages
    /// for a conversation's name to test an id can hang indefinitely, so tincan never does.)
    private func deliver(_ destination: SendDestination, textHandler: String, chatHandler: String, payload: String) throws {
        let knownID: String?
        if case .chat(let guid, _, _) = destination { knownID = scriptIDs[guid] } else { knownID = nil }
        let used = try Self.deliver(destination, textHandler: textHandler, chatHandler: chatHandler, payload: payload, knownChatID: knownID) {
            try call($0, $1)
        }
        if case .chat(let guid, _, _) = destination, let used { scriptIDs[guid] = used }
    }

    /// The handler calls behind `deliver`, with `call` running one AppleScript handler.
    /// Returns the conversation id that worked, when one was used.
    static func deliver(
        _ destination: SendDestination, textHandler: String, chatHandler: String, payload: String, knownChatID: String?,
        call: (String, [String]) throws -> Void
    ) throws -> String? {
        switch destination {
        case .address(let address, let service):
            try call(textHandler, [payload, address, serviceName(service)])
            return nil
        case .chat(let guid, let service, let address):
            if let address {
                do {
                    try call(textHandler, [payload, address, serviceName(service)])
                    return nil
                } catch AutomationError.messagesFailed(let code, _) where code == -1728 || code == -1719 {
                    // Not found on that account; fall back to the conversation id below.
                }
            }
            let candidates = knownChatID.map { [$0] } ?? candidateChatIDs(guid: guid, service: service)
            var lastError: Error = AutomationError.messagesFailed(code: -1728, message: "Messages doesn't know this conversation")
            for candidate in candidates {
                do {
                    try call(chatHandler, [payload, candidate])
                    return candidate
                } catch AutomationError.messagesFailed(let code, let message)
                    where code == -1728 || message.contains("Can’t get chat") || message.contains("Can't get chat")
                {
                    lastError = AutomationError.messagesFailed(code: code, message: message)
                    continue
                }
            }
            throw lastError
        }
    }

    /// The ids to try for the conversation `guid` over `service`: its own id when that
    /// names `service` or `any`, then `service`, then `any`. Never another service, which
    /// Messages would send over without saying so, as SMS where iMessage was planned.
    public static func candidateChatIDs(guid: String, service: MessageService) -> [String] {
        let parts = guid.components(separatedBy: ";")
        guard parts.count >= 3 else { return [guid] }
        let rest = parts.dropFirst().joined(separator: ";")
        let planned = serviceName(service)
        var prefixes = parts[0] == planned || parts[0] == "any" ? [parts[0]] : []
        for prefix in [planned, "any"] where !prefixes.contains(prefix) { prefixes.append(prefix) }
        return prefixes.map { "\($0);\(rest)" }
    }

    /// AppleScript runs on the main thread while the caller waits with a timeout, so a
    /// Messages that stops answering becomes an error instead of a hung command. Callers must
    /// not be on the main thread. Apple Events cannot be cancelled, so after a timeout this
    /// instance refuses further work.
    private var stalled = false
    /// Longest wait for Messages to answer one request.
    public var timeout: TimeInterval = 45

    private func call(_ handler: String, _ arguments: [String]) throws {
        if stalled { throw AutomationError.messagesFailed(code: -1712, message: "Messages stopped responding earlier in this command") }
        let handlers = self.handlers
        guard let result = Self.onMainThread(timeout: timeout, { try handlers.run(handler, arguments) }) else {
            stalled = true
            throw AutomationError.timedOut(seconds: Int(timeout))
        }
        try result.get()
    }

    /// Runs `body` on the main thread and waits for it at most `timeout` seconds. Nil when
    /// it didn't finish in time; it may still be running then, and its result is dropped.
    private static func onMainThread<T: Sendable>(timeout: TimeInterval, _ body: @escaping @MainActor @Sendable () throws -> T) -> Result<T, Error>? {
        let outcome = OSAllocatedUnfairLock<Result<T, Error>?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            let result = MainActor.assumeIsolated { Result { try body() } }
            outcome.withLock { $0 = result }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        return outcome.withLock { $0 }
    }

    // OpenScripting four-character codes: 'ascr', 'psbr' and 'snam'.
    private static let appleScriptSuite: AEEventClass = 0x6173_6372
    private static let subroutineEvent: AEEventID = 0x7073_6272
    private static let subroutineName: AEKeyword = 0x736E_616D

    static func serviceName(_ service: MessageService) -> String {
        switch service {
        case .sms: return "SMS"
        case .rcs: return "RCS"
        default: return "iMessage"
        }
    }

    static var stagingDirectory: String {
        NSString(string: "~/Library/Messages/Attachments/tincan").expandingTildeInPath
    }

    /// Removes staged copies older than a day; Messages has its own copy by then.
    static func pruneStaging(olderThan age: TimeInterval = 86_400) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(atPath: stagingDirectory) else { return }
        for entry in entries {
            let path = stagingDirectory + "/" + entry
            if let modified = (try? manager.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                Date().timeIntervalSince(modified) > age
            {
                try? manager.removeItem(atPath: path)
            }
        }
    }

    /// Copies the file at `path` into its own folder in `staging` and returns the copy's
    /// path. The file is opened without following a symbolic link, checked with
    /// `Attachments` from the open file itself, and copied from that same open file, so a
    /// folder, a link, or a file swapped in after the checks is never sent.
    static func stage(_ path: String, into staging: String = stagingDirectory, protected: [String] = Attachments.protectedPaths()) throws -> String {
        let source = NSString(string: path).expandingTildeInPath
        let input = try Attachments.open(source)
        defer { close(input) }
        _ = try Attachments.inspect(input, path: source, rules: Attachments.rules(protected: protected))

        let directory = staging + "/" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = directory + "/" + (source as NSString).lastPathComponent
        let output = Darwin.open(destination, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw AutomationError.attachmentUnreadable(path) }
        defer { close(output) }
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = read(input, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw AutomationError.attachmentUnreadable(path)
            }
            var written = 0
            while written < count {
                let result = buffer.withUnsafeBytes { write(output, $0.baseAddress! + written, count - written) }
                if result < 0 {
                    if errno == EINTR { continue }
                    throw AutomationError.attachmentUnreadable(path)
                }
                written += result
            }
        }
        return destination
    }
}
