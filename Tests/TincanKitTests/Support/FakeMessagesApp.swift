import Foundation

@testable import TincanKit

/// Stands in for Messages when testing `Sender`: it records each send and, as scripted,
/// writes the row Messages would write into a `MessagesFixture`. Nothing is ever sent.
final class FakeMessagesApp: MessageSending {
    enum Behavior {
        /// Messages records the bubble as sent.
        case sent
        /// Messages records the bubble but never finishes sending it.
        case pending
        /// Messages records the bubble, then marks it failed after `after` seconds.
        case failsLater(after: TimeInterval)
        /// Messages records nothing.
        case silent
        /// The call throws; Messages records nothing.
        case throwing(AutomationError)
        /// Messages records the bubble as sent, but the call throws anyway (a timed-out event).
        case recordsThenThrows(AutomationError)
    }

    let fixture: MessagesFixture
    let chat: Int64
    let recipient: Int64
    /// What each send does, in order. Sends past the end behave like `.sent`.
    var behaviors: [Behavior]
    /// The service Messages records each message on.
    var service = "iMessage"
    private(set) var texts: [String] = []
    private(set) var files: [String] = []
    private var minute = 100

    init(fixture: MessagesFixture, chat: Int64, recipient: Int64, behaviors: [Behavior] = []) {
        self.fixture = fixture
        self.chat = chat
        self.recipient = recipient
        self.behaviors = behaviors
    }

    func send(text: String, to destination: SendDestination) throws {
        texts.append(text)
        try perform { try self.record(text: text, attachment: nil, configure: $0) }
    }

    func send(file path: String, to destination: SendDestination) throws {
        files.append(path)
        try perform { try self.record(text: nil, attachment: (path as NSString).lastPathComponent, configure: $0) }
    }

    private func perform(_ record: ((inout MessagesFixture.MessageColumns) -> Void) throws -> MessagesFixture.Row) throws {
        switch behaviors.isEmpty ? .sent : behaviors.removeFirst() {
        case .sent:
            _ = try record { _ in }
        case .pending:
            _ = try record { $0.isSent = false }
        case .failsLater(let delay):
            let row = try record { $0.isSent = false }
            let database = fixture.database
            Later.run(after: delay) {
                try? database.execute("UPDATE message SET error = 22 WHERE ROWID = \(row.rowID)")
            }
        case .silent:
            break
        case .throwing(let error):
            throw error
        case .recordsThenThrows(let error):
            _ = try record { _ in }
            throw error
        }
    }

    private func record(text: String?, attachment: String?, configure: (inout MessagesFixture.MessageColumns) -> Void) throws -> MessagesFixture.Row {
        minute += 1
        let row = try fixture.addMessage(text, in: chat, from: .meTo(recipient), at: .minute(minute)) { columns in
            columns.service = service
            configure(&columns)
        }
        if let attachment { try fixture.addAttachment(to: row, name: attachment, mimeType: "image/png") }
        return row
    }
}

/// Runs work after a delay on its own thread. The shared dispatch queues can be saturated
/// while the whole suite runs, which made delayed fake updates arrive seconds late.
enum Later {
    static func run(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) {
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: delay)
            work()
        }
    }
}
