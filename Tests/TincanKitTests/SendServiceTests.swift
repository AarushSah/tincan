import Foundation
import Testing

@testable import TincanKit

/// Which service a send continues on: the one a conversation's recent messages actually
/// use, when Messages lists the conversation as SMS or RCS but both people have been
/// writing over iMessage. Nothing here sends.
@Suite("Send service")
struct SendServiceTests {
    static let priya = Contact(id: "priya", givenName: "Priya", familyName: "Shah", phones: [SampleContacts.phone("+14155550148")])
    static let omar = Contact(id: "omar", givenName: "Omar", familyName: "Nasser", phones: [SampleContacts.phone("+14155550149")])
    static let dana = Contact(id: "dana", givenName: "Dana", familyName: "Wolfe", phones: [SampleContacts.phone("+14155550151")])

    let fixture: MessagesFixture
    /// Listed as RCS; both people have been writing over iMessage.
    let priyaChat: Int64
    /// Listed as RCS; only your own messages went over iMessage.
    let omarChat: Int64
    /// Listed as SMS, and its newest message went over SMS.
    let danaChat: Int64

    init() throws {
        fixture = try MessagesFixture()
        let priya = try fixture.addHandle("+14155550148", service: "RCS")
        let omar = try fixture.addHandle("+14155550149", service: "RCS")
        let dana = try fixture.addHandle("+14155550151", service: "SMS")
        priyaChat = try fixture.addChat("any;-;+14155550148", service: "RCS", participants: [priya])
        omarChat = try fixture.addChat("any;-;+14155550149", service: "RCS", participants: [omar])
        danaChat = try fixture.addChat("any;-;+14155550151", service: "SMS", participants: [dana])

        try fixture.addMessage("see you at 6", in: priyaChat, from: .meTo(priya), at: .minute(1))
        let reply = try fixture.addMessage("perfect", in: priyaChat, from: .handle(priya), at: .minute(2))
        // Reactions and a message Messages failed to send say nothing about the service.
        let love = try fixture.addReaction(.love, to: reply, in: priyaChat, from: .meTo(priya), at: .minute(3))
        try fixture.database.execute("UPDATE message SET service = 'SMS' WHERE ROWID = \(love.rowID)")
        try fixture.addMessage("did it go?", in: priyaChat, from: .meTo(priya), at: .minute(4)) {
            $0.service = "SMS"
            $0.error = 22
        }

        try fixture.addMessage("hello?", in: omarChat, from: .meTo(omar), at: .minute(5))

        try fixture.addMessage("new phone, who dis", in: danaChat, from: .handle(dana), at: .minute(6)) { $0.service = "iMessage" }
        try fixture.addMessage("it's me", in: danaChat, from: .meTo(dana), at: .minute(7)) { $0.service = "SMS" }
    }

    func planner(excluding excluded: Set<Int64> = [], contacts: [Contact] = [Self.priya, Self.omar, Self.dana]) throws -> SendPlanner {
        let messages = try fixture.open(excluding: excluded)
        let resolver = Resolver(
            directory: Directory(contacts: contacts, region: "US"),
            chats: try messages.allChats(), handles: Array(try messages.handles().values), excludedChatIDs: excluded,
            activity: try messages.lastActivityByChat()
        )
        return SendPlanner(
            resolver: resolver, region: "US", activity: resolver.activity, exclusions: [], ownAddresses: { ["+14155550101"] },
            relativeTime: { _ in "recently" },
            conditions: SendPlanner.Conditions(accessibilityAllowed: { false }, screenLocked: { false }, messagesInUse: { false }),
            recentServices: { (try? messages.recentServices(inChat: $0, since: nil, limit: SendPlanner.recentMessageCount)) ?? [] }
        )
    }

    func planning(_ reference: String, service: MessageService? = nil) throws -> (plan: SendPlan, warnings: [PlanWarning]) {
        var warnings: [PlanWarning] = []
        let request = SendPlanner.Request(reference: reference, bubbles: ["hi"], service: service, typing: .paced, wordsPerMinute: 42, seed: 7)
        let plan = try planner().plan(request, warnings: &warnings)
        return (plan, warnings)
    }

    @Test func recentServicesSkipReactionsFailuresAndExcludedConversations() throws {
        let messages = try fixture.open()
        let recent = try messages.recentServices(inChat: priyaChat, since: nil, limit: 10)
        #expect(recent.map(\.service) == [.iMessage, .iMessage])
        #expect(recent.map(\.isFromMe) == [false, true])
        #expect(try messages.recentServices(inChat: priyaChat, since: .minute(1), limit: 10).count == 1)
        #expect(try messages.recentServices(inChat: priyaChat, since: nil, limit: 1).count == 1)
        #expect(try fixture.open(excluding: [priyaChat]).recentServices(inChat: priyaChat, since: nil, limit: 10).isEmpty)
    }

    /// Choosing between a person's conversations shows the service each would be sent over.
    @Test func candidatesShowTheServiceASendWouldUse() throws {
        let email = try fixture.addHandle("priya@example.com", service: "iMessage")
        let emailChat = try fixture.addChat("iMessage;-;priya@example.com", service: "iMessage", participants: [email])
        try fixture.addMessage("old thread", in: emailChat, from: .handle(email), at: .minute(0))
        var priya = Self.priya
        priya.emails = [Contact.Email(label: "home", value: "priya@example.com")]
        var warnings: [PlanWarning] = []
        let request = SendPlanner.Request(reference: "Priya", bubbles: ["hi"], service: nil, typing: .paced, wordsPerMinute: 42, seed: 7)
        let planner = try planner(contacts: [priya, Self.omar, Self.dana])
        let refused = try #require(refusal { try planner.plan(request, warnings: &warnings) }, "Priya has two conversations")
        guard case .issue(let issue) = refused else {
            Issue.record("Expected the planner's own refusal")
            return
        }
        #expect(issue.code == "ambiguous_destination")
        let phone = try #require(issue.candidates.first { $0.reference == "chat:\(priyaChat)" })
        #expect(phone.name == "+1 (415) 555-0148 · iMessage")
        #expect(phone.detail == "last message recently · Messages lists it as RCS")
        let mail = try #require(issue.candidates.first { $0.reference == "chat:\(emailChat)" })
        #expect(mail.name == "priya@example.com · iMessage")
        #expect(mail.detail == "last message recently")
    }

    private func refusal(_ body: () throws -> SendPlan) -> PlanRefusal? {
        do {
            _ = try body()
            return nil
        } catch let refusal as PlanRefusal {
            return refusal
        } catch {
            return nil
        }
    }

    @Test func aConversationListedAsRCSThatBothPeopleUseOverIMessageContinuesOverIMessage() throws {
        let (plan, warnings) = try planning("Priya")
        #expect(plan.route.chat?.id == priyaChat)
        #expect(plan.route.service == .iMessage)
        #expect(plan.route.serviceSwitched)
        #expect(plan.request.destination == .chat(guid: "any;-;+14155550148", service: .iMessage, address: "+14155550148"))
        #expect(plan.request.chatID == priyaChat)
        #expect(plan.route.reason == "your conversation with Priya Shah, over iMessage like its recent messages")
        #expect(warnings.map(\.code) == ["service_switched"])

        // The same by number, and by the conversation's reference.
        #expect(try planning("+14155550148").plan.route.service == .iMessage)
        let named = try planning("chat:\(priyaChat)")
        #expect(named.plan.route.service == .iMessage)
        #expect(named.plan.route.reason == "the conversation you named, over iMessage like its recent messages")
        #expect(named.warnings.map(\.code) == ["service_switched"])
    }

    @Test func aServiceAskedForAlwaysWins() throws {
        let (plan, warnings) = try planning("Priya", service: .rcs)
        #expect(plan.route.service == .rcs)
        #expect(!plan.route.serviceSwitched)
        #expect(plan.route.reason == "your conversation with Priya Shah; its recent messages went over iMessage")
        #expect(warnings.map(\.code) == ["service_differs"])
        let rcs = try planning("chat:\(priyaChat)", service: .rcs)
        #expect(rcs.plan.route.service == .rcs)
    }

    @Test func askingForIMessageContinuesTheConversationItsMessagesUse() throws {
        // Not a new conversation: Messages keeps one conversation for the number.
        let (plan, warnings) = try planning("Priya", service: .iMessage)
        #expect(plan.route.chat?.id == priyaChat)
        #expect(plan.request.destination == .chat(guid: "any;-;+14155550148", service: .iMessage, address: "+14155550148"))
        #expect(warnings.isEmpty)
        #expect(try planning("chat:\(priyaChat)", service: .iMessage).plan.route.service == .iMessage)
        // A service the conversation never used is still refused for a reference.
        #expect(throws: PlanRefusal.self) { try planning("chat:\(omarChat)", service: .sms) }
    }

    @Test func onlyYourOwnIMessagesDontShowTheOtherPersonHasIt() throws {
        let (plan, warnings) = try planning("Omar")
        #expect(plan.route.service == .rcs)
        #expect(!plan.route.serviceSwitched)
        #expect(plan.route.reason == "your conversation with Omar Nasser; its recent messages went over iMessage")
        #expect(warnings.map(\.code) == ["service_differs"])
    }

    @Test func aMixedConversationKeepsTheServiceMessagesLists() throws {
        // The newest message went over SMS, as Messages lists it: nothing to say.
        let (plan, warnings) = try planning("Dana")
        #expect(plan.route.service == .sms)
        #expect(!plan.route.serviceSwitched)
        #expect(plan.route.reason == "your conversation with Dana Wolfe")
        #expect(warnings.isEmpty)
    }

    @Test func withoutRecentMessagesTheServiceIsTheOneMessagesLists() throws {
        let messages = try fixture.open()
        let resolver = Resolver(
            directory: Directory(contacts: [Self.priya], region: "US"), chats: try messages.allChats(), handles: Array(try messages.handles().values))
        let planner = SendPlanner(
            resolver: resolver, region: "US", activity: [:], exclusions: [], ownAddresses: { [] }, relativeTime: { _ in "" },
            conditions: SendPlanner.Conditions(accessibilityAllowed: { false }, screenLocked: { false }, messagesInUse: { false }))
        var warnings: [PlanWarning] = []
        let plan = try planner.plan(SendPlanner.Request(reference: "Priya", bubbles: ["hi"], typing: .paced, wordsPerMinute: 42, seed: 7), warnings: &warnings)
        #expect(plan.route.service == .rcs)
        #expect(warnings.isEmpty)
    }
}
