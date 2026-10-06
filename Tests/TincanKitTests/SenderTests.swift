import Foundation
import Testing

@testable import TincanKit

/// `Sender` against a fake Messages app that writes rows into a fixture database the way
/// Messages would. Every bubble must be confirmed by a new row with its text before the next
/// one goes out; anything else stops the rest.
@Suite("Sending")
struct SenderTests {
    typealias Behavior = FakeMessagesApp.Behavior

    let fixture: MessagesFixture
    let maya: Int64
    let chat: Int64

    init() throws {
        fixture = try MessagesFixture()
        maya = try fixture.addHandle("+14155550142")
        chat = try fixture.addChat("any;-;+14155550142", participants: [maya])
    }

    /// Sends `texts` and `files` through the fake app. `beforeSending` runs once the database
    /// is open.
    private func send(
        _ texts: [String], files: [String] = [], behaviors: [Behavior], beforeSending: () throws -> Void = {}
    ) async throws -> (outcomes: [BubbleOutcome], app: FakeMessagesApp) {
        let app = FakeMessagesApp(fixture: fixture, chat: chat, recipient: maya, behaviors: behaviors)
        let sender = Sender(messages: try fixture.open(), automation: app)
        // Generous: the full suite runs many processes at once, and late updates still land in time.
        sender.confirmationTimeout = 4
        try beforeSending()
        let request = Sender.Request(
            destination: .chat(guid: "any;-;+14155550142", service: .iMessage, address: "+14155550142"), chatID: chat,
            plan: .immediate(texts), files: files, method: .immediate, keyboardAddress: nil, keyboardService: .iMessage, expectedTitles: []
        )
        return (await sender.run(request) { _ in }, app)
    }

    @Test func bubblesAreConfirmedOneAtATime() async throws {
        let (outcomes, app) = try await send(["running late", "10 min"], behaviors: [])
        #expect(outcomes.map(\.status) == [.sent, .sent])
        #expect(outcomes.map { $0.message?.text } == ["running late", "10 min"])
        #expect(app.texts == ["running late", "10 min"])
    }

    /// A send that starts a conversation is confirmed only in a conversation with its
    /// recipient. Messages writes the fake's rows into Maya's conversation.
    @Test func aNewConversationIsConfirmedOnlyWithItsRecipient() async throws {
        func sendNew(to address: String) async throws -> [BubbleOutcome] {
            let app = FakeMessagesApp(fixture: fixture, chat: chat, recipient: maya)
            let sender = Sender(messages: try fixture.open(), automation: app)
            sender.confirmationTimeout = 1
            let request = Sender.Request(
                destination: .address(address, service: .iMessage), chatID: nil, plan: .immediate(["hello"]), files: [], method: .immediate,
                keyboardAddress: nil, keyboardService: .iMessage, expectedTitles: [])
            return await sender.run(request) { _ in }
        }
        #expect(try await sendNew(to: "+14155550142").map(\.status) == [.sent])
        #expect(try await sendNew(to: "+14155550199").map(\.status) == [.unconfirmed])
    }

    @Test func anEarlierIdenticalMessageNeverConfirmsANewOne() async throws {
        try fixture.addMessage("ok", in: chat, from: .meTo(maya), at: .minute(1))
        let (outcomes, _) = try await send(["ok"], behaviors: [.silent])
        #expect(outcomes.map(\.status) == [.unconfirmed])
    }

    @Test func aBubbleThatNeverFinishesSendingStopsTheRest() async throws {
        let (outcomes, app) = try await send(["one", "two"], behaviors: [.pending])
        #expect(outcomes.map(\.status) == [.unconfirmed, .skipped])
        #expect(app.texts == ["one"])
    }

    @Test func aBubbleThatFailsAfterAppearingStopsTheRest() async throws {
        let (outcomes, app) = try await send(["one", "two"], behaviors: [.failsLater(after: 0.3)])
        #expect(outcomes.map(\.status) == [.failed, .skipped])
        #expect(app.texts == ["one"])
    }

    @Test func aRefusedSendStopsTheRest() async throws {
        let (outcomes, app) = try await send(["one", "two"], behaviors: [.throwing(.messagesFailed(code: -1708, message: "refused"))])
        #expect(outcomes.map(\.status) == [.failed, .skipped])
        #expect(app.texts == ["one"])
    }

    @Test func aTimedOutSendIsLookedForInsteadOfReportedFailed() async throws {
        let (outcomes, _) = try await send(["one"], behaviors: [.recordsThenThrows(.timedOut(seconds: 45))])
        #expect(outcomes.map(\.status) == [.sent])
    }

    @Test func aTimedOutSendThatNeverAppearsIsUnconfirmedNotFailed() async throws {
        // Messages keeps the request queued and may still send it; "failed" would invite a resend.
        let (outcomes, app) = try await send(["one", "two"], behaviors: [.throwing(.timedOut(seconds: 45))])
        #expect(outcomes.map(\.status) == [.unconfirmed, .skipped])
        #expect(app.texts == ["one"])
    }

    @Test func anUnconfirmedFileStopsTheRemainingFiles() async throws {
        let (outcomes, app) = try await send(["photos"], files: ["/private/tmp/a.png", "/private/tmp/b.png"], behaviors: [.sent, .silent])
        #expect(outcomes.map(\.status) == [.sent, .unconfirmed, .skipped])
        #expect(app.files == ["/private/tmp/a.png"])
    }

    @Test func filesAreReportedSkippedAfterAFailedBubble() async throws {
        let (outcomes, app) = try await send(["one"], files: ["/private/tmp/a.png"], behaviors: [.throwing(.notAuthorized)])
        #expect(outcomes.map(\.status) == [.failed, .skipped])
        #expect(outcomes.map(\.text) == ["one", "/private/tmp/a.png"])
        #expect(app.files.isEmpty)
    }

    @Test func nothingIsSentWithoutABaseline() async throws {
        // Without the newest ROWID before sending, any earlier "ok" could confirm this one.
        try fixture.addMessage("ok", in: chat, from: .meTo(maya), at: .minute(1))
        defer { try? fixture.database.execute("COMMIT") }
        let (outcomes, app) = try await send(["ok"], behaviors: []) { try fixture.database.execute("BEGIN EXCLUSIVE") }
        #expect(outcomes.map(\.status) == [.failed])
        #expect(app.texts.isEmpty)
    }

    /// Sends `texts` over `service` through the fake app, then looks for a carrier bounce
    /// for up to `timeout` seconds while `afterSending` writes what arrives.
    private func sendAndCheck(
        _ texts: [String], service: String, timeout: TimeInterval = 4, afterSending: @escaping @Sendable (MessagesFixture) -> Void = { _ in }
    ) async throws -> [BubbleOutcome] {
        let app = FakeMessagesApp(fixture: fixture, chat: chat, recipient: maya)
        app.service = service
        let sender = Sender(messages: try fixture.open(), automation: app)
        sender.confirmationTimeout = 4
        let request = Sender.Request(
            destination: .chat(guid: "any;-;+14155550142", service: .rcs, address: "+14155550142"), chatID: chat,
            plan: .immediate(texts), files: [], method: .immediate, keyboardAddress: nil, keyboardService: .rcs, expectedTitles: []
        )
        let sent = await sender.run(request) { _ in }
        afterSending(fixture)
        return await sender.checkForBounces(sent, in: chat, from: "+14155550142", region: "US", timeout: timeout)
    }

    @Test func aCarrierNoticeAfterAnSMSMakesItFailed() async throws {
        let maya = self.maya
        let chat = self.chat
        let outcomes = try await sendAndCheck(["running late"], service: "SMS") { fixture in
            _ = try? fixture.addMessage(
                "Free Msg: Unable to send message - Message Blocking is active.", in: chat, from: .handle(maya), at: .minute(500)
            ) { $0.service = "SMS" }
        }
        #expect(outcomes.map(\.status) == [.failed])
        #expect(outcomes.first?.bounce?.text == "Free Msg: Unable to send message - Message Blocking is active.")
        #expect(outcomes.first?.message?.text == "running late")
    }

    @Test func aReplyIsNotABounce() async throws {
        let maya = self.maya
        let chat = self.chat
        let outcomes = try await sendAndCheck(["running late"], service: "SMS", timeout: 1) { fixture in
            _ = try? fixture.addMessage("no worries, I was unable to leave either", in: chat, from: .handle(maya), at: .minute(500)) { $0.service = "SMS" }
        }
        #expect(outcomes.map(\.status) == [.sent])
        #expect(outcomes.first?.bounce == nil)
    }

    @Test func aNoticeFromSomeoneElseIsNotABounce() async throws {
        let other = try fixture.addHandle("+14155550160", service: "SMS")
        let elsewhere = try fixture.addChat("any;-;+14155550160", service: "SMS", participants: [other])
        let outcomes = try await sendAndCheck(["running late"], service: "SMS", timeout: 1) { fixture in
            _ = try? fixture.addMessage("Free Msg: Unable to send message", in: elsewhere, from: .handle(other), at: .minute(500)) { $0.service = "SMS" }
        }
        #expect(outcomes.map(\.status) == [.sent])
    }

    @Test func iMessageBubblesAreNotCheckedForBounces() async throws {
        let maya = self.maya
        let chat = self.chat
        let outcomes = try await sendAndCheck(["running late"], service: "iMessage") { fixture in
            _ = try? fixture.addMessage("Free Msg: Unable to send message", in: chat, from: .handle(maya), at: .minute(500)) { $0.service = "SMS" }
        }
        #expect(outcomes.map(\.status) == [.sent])
    }

    @Test func aNoticeOnlyCountsForBubblesSentBeforeIt() async throws {
        let maya = self.maya
        let chat = self.chat
        let fixture = self.fixture
        try fixture.addMessage("Free Msg: Unable to send message", in: chat, from: .handle(maya), at: .minute(50)) { $0.service = "SMS" }
        let outcomes = try await sendAndCheck(["one", "two"], service: "SMS", timeout: 1)
        // The only notice came before either bubble.
        #expect(outcomes.map(\.status) == [.sent, .sent])
    }

    @Test(
        "Carrier notices are recognized narrowly",
        arguments: [
            ("Free Msg: Unable to send message - Message Blocking is active.", true),
            ("free msg: unable to send message – message blocking is active", true),
            ("Message Blocking is active", true),
            ("Free Msg: Your message could not be delivered.", true),
            ("Free Msg: Your bill is ready to view.", false),
            ("I was unable to send the photos, trying again", false),
            ("blocked the whole afternoon for you", false),
        ])
    func carrierNotices(text: String, bounce: Bool) {
        #expect(CarrierBounce.matches(text) == bounce)
    }

    @Test func theLedgerKeepsGUIDsAndTimesOnly() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tincan-ledger-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("sent.jsonl").path
        #expect(SendLedger.guids(at: path).isEmpty)
        try SendLedger.append([.init(at: .minute(1), guid: "AT-1"), .init(at: .minute(2), guid: "AT-2")], to: path)
        try SendLedger.append([.init(at: .minute(3), guid: "AT-3")], to: path)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let first = try #require(text.split(separator: "\n").first)
        let keys = try #require(try JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any]).keys
        #expect(Set(keys) == ["at", "guid"], "no text, recipient or anything else")
        #expect(SendLedger.guids(at: path) == ["AT-1", "AT-2", "AT-3"])
        #expect((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) == 0o600)
        // Lines that aren't entries, such as an older ledger's, are skipped.
        try (text + #"{"at":"2026-01-01T00:04:00Z","to":"+14155550142","text_sha256":"ab"}"# + "\nnot json\n").write(
            toFile: path, atomically: true, encoding: .utf8)
        #expect(SendLedger.guids(at: path) == ["AT-1", "AT-2", "AT-3"])
    }

    @Test func receiptsAreAwaited() async throws {
        let messages = try fixture.open()
        let app = FakeMessagesApp(fixture: fixture, chat: chat, recipient: maya)
        let sender = Sender(messages: messages, automation: app)
        let request = Sender.Request(
            destination: .address("+14155550142", service: .iMessage), chatID: chat, plan: .immediate(["hi"]), files: [],
            method: .immediate, keyboardAddress: nil, keyboardService: .iMessage, expectedTitles: []
        )
        let sent = await sender.run(request) { _ in }
        let id = try #require(sent.first?.message?.id)
        let database = fixture.database
        let failure = WriteFailure()
        Later.run(after: 0.3) {
            // Retry: under a busy test run the write can meet a lock that outlasts the timeout.
            for attempt in 1...20 {
                do {
                    try database.execute(
                        "UPDATE message SET is_delivered = 1, date_delivered = \(MessagesFixture.nanoseconds(.minute(200))) WHERE ROWID = \(id)")
                    return
                } catch {
                    if attempt == 20 { failure.record(String(describing: error)) }
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
        }
        // Returns as soon as the receipt lands; the margin is for a saturated test run.
        let delivered = await sender.waitForReceipts(sent, until: .delivered, timeout: 30)
        #expect(failure.message == nil)
        #expect(delivered.map(\.status) == [.delivered])
    }
}

/// How a send finds its conversation in Messages' AppleScript: it must never reach Messages
/// twice for one bubble.
@Suite("Delivery to Messages")
struct DeliveryTests {
    final class Calls {
        var made: [(handler: String, arguments: [String])] = []
        var results: [Error?] = []

        func call(_ handler: String, _ arguments: [String]) throws {
            made.append((handler, arguments))
            if !results.isEmpty, let error = results.removeFirst() { throw error }
        }
    }

    static let group = SendDestination.chat(guid: "any;+;chat100", service: .iMessage, address: nil)
    static let direct = SendDestination.chat(guid: "any;-;+14155550142", service: .iMessage, address: "+14155550142")
    static let unknown = AutomationError.messagesFailed(code: -1728, message: "Can’t get chat id \"x\".")

    private func deliver(_ destination: SendDestination, known: String? = nil, results: [Error?]) -> (used: Result<String?, Error>, calls: Calls) {
        let calls = Calls()
        calls.results = results
        let used = Result {
            try MessagesAutomation.deliver(destination, textHandler: "text", chatHandler: "chat", payload: "hi", knownChatID: known, call: calls.call)
        }
        return (used, calls)
    }

    @Test func aDirectSendThatWorksIsNotRepeatedThroughChatIDs() throws {
        let (used, calls) = deliver(Self.direct, results: [nil])
        #expect(try used.get() == nil)
        #expect(calls.made.map(\.handler) == ["text"])
        #expect(calls.made.first?.arguments == ["hi", "+14155550142", "iMessage"])
    }

    @Test func anUnknownParticipantFallsBackToTheConversationID() throws {
        let (used, calls) = deliver(Self.direct, results: [AutomationError.messagesFailed(code: -1728, message: "Can’t get participant")])
        #expect(try used.get() == "any;-;+14155550142")
        #expect(calls.made.map(\.handler) == ["text", "chat"])
    }

    /// A conversation Messages lists as SMS, sent over iMessage like its recent messages,
    /// never falls back to its SMS id when iMessage doesn't know the address.
    @Test func theFallbackNeverSwitchesToAnotherService() throws {
        let switched = SendDestination.chat(guid: "SMS;-;+14155550142", service: .iMessage, address: "+14155550142")
        let notFound = AutomationError.messagesFailed(code: -1728, message: "Can’t get participant")
        let (used, calls) = deliver(switched, results: [notFound, Self.unknown, Self.unknown])
        #expect(throws: AutomationError.self) { try used.get() }
        #expect(calls.made.map { $0.arguments.last } == ["iMessage", "iMessage;-;+14155550142", "any;-;+14155550142"])
        #expect(MessagesAutomation.candidateChatIDs(guid: "RCS;-;+14155550142", service: .sms) == ["SMS;-;+14155550142", "any;-;+14155550142"])
        #expect(MessagesAutomation.candidateChatIDs(guid: "SMS;-;+14155550142", service: .sms) == ["SMS;-;+14155550142", "any;-;+14155550142"])
    }

    @Test func groupIDsAreTriedUntilMessagesKnowsOne() throws {
        let (used, calls) = deliver(Self.group, results: [Self.unknown, nil])
        #expect(try used.get() == "iMessage;+;chat100")
        #expect(calls.made.map { $0.arguments.last } == ["any;+;chat100", "iMessage;+;chat100"])
    }

    @Test(
        "Any other error stops at once",
        arguments: [
            AutomationError.timedOut(seconds: 45), .notAuthorized, .messagesFailed(code: -1708, message: "refused"),
        ])
    func otherErrorsStop(error: AutomationError) {
        let (direct, directCalls) = deliver(Self.direct, results: [error])
        #expect(throws: AutomationError.self) { try direct.get() }
        #expect(directCalls.made.count == 1)
        let (group, groupCalls) = deliver(Self.group, results: [Self.unknown, error])
        #expect(throws: AutomationError.self) { try group.get() }
        #expect(groupCalls.made.count == 2)
    }

    @Test func aRememberedIDIsTheOnlyOneTried() {
        let (used, calls) = deliver(Self.group, known: "iMessage;+;chat100", results: [Self.unknown])
        #expect(throws: AutomationError.self) { try used.get() }
        #expect(calls.made.map { $0.arguments.last } == ["iMessage;+;chat100"])
    }

    @Test func addressesAreSentOnce() throws {
        let (used, calls) = deliver(.address("maya@example.com", service: .iMessage), results: [nil])
        #expect(try used.get() == nil)
        #expect(calls.made.map(\.handler) == ["text"])
    }
}

/// Collects an error from a background write so the test can report it.
final class WriteFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    var message: String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func record(_ text: String) {
        lock.lock()
        value = text
        lock.unlock()
    }
}
