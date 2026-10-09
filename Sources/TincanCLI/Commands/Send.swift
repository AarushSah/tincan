import ArgumentParser
import Foundation
import TincanKit

struct Send: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Send messages, one bubble at a time, paced like a person typing.",
        discussion: """
            Each text argument is one bubble. tincan types each bubble at your typing speed and sends it before starting the next, so the other person sees a natural conversation. With Accessibility allowed, it types into Messages so they see the typing indicator.

            tincan continues the conversation you already have with the person, in the thread Messages would use, and confirms every bubble in Messages, stopping if one fails. When Messages lists a conversation as SMS or RCS but its recent messages, theirs included, went over iMessage, tincan sends over iMessage and warns service_switched; --service always wins. "sent" means Messages finished sending, not that the recipient got it. After an SMS or RCS send, tincan looks for --bounce-wait seconds for a carrier's notice that it wasn't delivered, and reports those bubbles failed (carrier_bounce). --wait delivered waits for the recipient's device to confirm; SMS never does. In a terminal it asks before sending. Without a terminal (scripts, assistants) nothing is sent unless you pass --yes, and a first message to someone new also needs --new-conversation. `me` continues your conversation with yourself on any of your addresses; without one, it starts one like any new conversation.

            A dry run says when sending would start a new conversation, and lists everyone in a group. With no conversation to show which service an address uses, tincan asks for iMessage and Messages decides, so the preview marks the service as a guess. With --json, each bubble Messages confirmed carries its ref (m:<id>), and next.command watches the conversation for a reply. When the number is on other contact cards too, tincan warns: a message there reaches whoever uses it. A number without its country code that your region can't complete is refused, with the full numbers it could be, as are numbers of fewer than five digits that Messages has no conversation with. Bubbles can hold new lines and tabs, but no other control characters, nor characters that reorder or break the text differently from the preview (bidirectional overrides, line separators), nor invisible characters that spell hidden text (tag characters outside emoji flags, variation selectors carrying data).

            Groups are sent to by chat:<id>. The people in a group can rename it, so a group's name alone stops with `ambiguous` and lists the group and who is in it. When a group is named like the person, tincan paces instead of typing into Messages.

            Reading bubbles from stdin with - means there is no terminal to ask in, so pass --yes after checking the text with --dry-run.

            Examples:
              tincan send Maya "running 5 min late" "save me a seat 🙏"
              tincan send chat:42 "I'm in!" --typing paced
              tincan send +14155550142 "Hi, it's Sam from the climbing gym" --dry-run
              tincan send me "test from tincan"
              echo "on my way" | tincan send Maya - --yes
            """
    )

    @Argument(
        help: ArgumentHelp(
            "A name, phone number, email, address:<address>, contact:<id>, chat:<id> (the only way to name a group), or `me` for yourself.", valueName: "who"))
    var who: String

    @Argument(help: "One or more bubbles. Use - to read bubbles from stdin, separated by blank lines.")
    var texts: [String] = []

    @Option(
        help: ArgumentHelp(
            "Attach a file, sent after the text. Repeatable. From your home folder, /Volumes, /tmp or your temporary folder, never from a Library folder or a hidden file or folder in them, and at most 100 MB.",
            valueName: "path"))
    var file: [String] = []

    @Option(help: "How the other person sees typing: auto, keyboard (the typing indicator), paced (wait, no indicator) or off. Default from `tincan config`.")
    var typing: Config.TypingMode?

    @Option(help: "Typing speed in words per minute, from 5 to 250. Default from `tincan config` (80).")
    var wpm: Double?

    @Option(help: "Send over this service, in its own thread with the person.")
    var service: MessageService?

    @Option(help: "After sending, wait for delivered or read receipts.")
    var wait: WaitTarget?

    @Option(help: "Seconds to wait with --wait.")
    var timeout: Double = 60

    @Option(help: "Seconds to look for a carrier's notice that an SMS or RCS bubble wasn't delivered, from 0 (don't look) to 60.")
    var bounceWait: Double = Send.defaultBounceWait

    /// Carriers text a refusal back within seconds.
    static let defaultBounceWait: Double = 10

    @Flag(help: "Show the plan without sending.")
    var dryRun = false

    @Flag(name: .shortAndLong, help: "Send without asking. Required when there's no terminal to ask in (scripts and assistants).")
    var yes = false

    @Flag(help: "Allow starting a conversation with someone you have never messaged. Required without a terminal.")
    var newConversation = false

    @Option(help: "Seed for the pacing plan, to reproduce a --dry-run exactly.")
    var seed: UInt64?

    @OptionGroup var global: GlobalOptions

    enum WaitTarget: String, CaseIterable, ExpressibleByArgument { case delivered, read }

    struct PlanItem: Encodable {
        let text: String
        let pauseSeconds: Double
        let typingSeconds: Double
    }

    /// An attachment: where the file really is (links followed), and its size.
    struct FileRef: Encodable {
        let path: String
        let bytes: Int64
    }

    struct BubbleResult: Encodable {
        let text: String
        let status: String
        let method: String?
        let messageId: Int64?
        /// `m:<id>` of a bubble Messages confirmed, for `read --around` and `watch --after`.
        let ref: String?
        let at: Date?
        let deliveredAt: Date?
        let readAt: Date?
        let error: String?
        /// `carrier_bounce` when the carrier sent back a notice that it wasn't delivered.
        let errorCode: String?
        /// The carrier's notice, for a bubble that bounced.
        let bounce: Bounce?
        let note: String?

        init(
            text: String, status: String, method: String?, messageId: Int64?, at: Date?, deliveredAt: Date?, readAt: Date?, error: String?,
            errorCode: String? = nil, bounce: Bounce? = nil, note: String?
        ) {
            self.text = text
            self.status = status
            self.method = method
            self.messageId = messageId
            // Only a bubble seen going out is a message to point at.
            ref = Send.confirmedStatuses.contains(status) ? messageId.map(messageCursor) : nil
            self.at = at
            self.deliveredAt = deliveredAt
            self.readAt = readAt
            self.error = error
            self.errorCode = errorCode
            self.bounce = bounce
            self.note = note
        }
    }

    /// A carrier's notice that a bubble wasn't delivered, as it arrived in Messages.
    struct Bounce: Encodable {
        let ref: String
        let text: String
        let at: Date
    }

    /// Statuses of a bubble Messages recorded as going out.
    static let confirmedStatuses = Set([BubbleOutcome.Status.sent, .delivered, .read].map(\.rawValue))

    /// How to wait for a reply: watch `conversation` from the last bubble confirmed, so only
    /// what comes after it prints. Nil when no bubble has a reference.
    static func replyNext(after bubbles: [BubbleResult], in conversation: String) -> Output.Next? {
        guard let last = bubbles.last(where: { $0.ref != nil })?.ref else { return nil }
        return Output.Next(cursor: last, command: "tincan watch --in \(shellQuote(conversation)) --after \(last) --json")
    }

    struct Result: Encodable {
        let to: Payload.PersonRef
        let chat: String?
        /// Messages filed the conversation under Unknown Senders or Junk.
        let filtered: Bool?
        /// True when no conversation exists yet, so sending starts one.
        let newConversation: Bool?
        /// Everyone in a group conversation, besides you.
        let participants: [Payload.PersonRef]?
        let service: String
        /// True when no conversation shows which service the address uses: tincan asks for
        /// `service`, and Messages decides whether it goes that way.
        let serviceGuessed: Bool?
        /// Why this conversation: the one named, the thread with the address given, or the
        /// most recent of one address's threads.
        let routeReason: String
        let method: String
        let methodReason: String
        let dryRun: Bool?
        let plan: [PlanItem]?
        let bubbles: [BubbleResult]?
        let files: [FileRef]?
        /// After a send: whether every bubble reached the recipient's device (`delivered` or
        /// `read`). `sent` alone means Messages finished sending, not that it arrived.
        let delivered: Bool?
        /// After an SMS or RCS send: how long tincan looked for a carrier's notice that a
        /// bubble wasn't delivered.
        let bounceCheckSeconds: Double?
        let ok: Bool

        init(
            _ send: SendPlan, to: Payload.PersonRef, participants: [Payload.PersonRef], dryRun: Bool?, plan: [PlanItem]?, bubbles: [BubbleResult]?,
            files: [FileRef]?, delivered: Bool? = nil, bounceCheckSeconds: Double? = nil, ok: Bool
        ) {
            let route = send.route
            self.to = to
            chat = route.chat?.reference
            filtered = route.chat?.isFiltered == true ? true : nil
            newConversation = route.chat == nil ? true : nil
            self.participants = participants.isEmpty ? nil : participants
            service = route.service.rawValue
            serviceGuessed = route.serviceGuessed ? true : nil
            routeReason = route.reason
            method = send.method.rawValue
            methodReason = send.methodReason
            self.dryRun = dryRun
            self.plan = plan
            self.bubbles = bubbles
            self.files = files
            self.delivered = delivered
            self.bounceCheckSeconds = bounceCheckSeconds
            self.ok = ok
        }
    }

    func run() async throws {
        try await runCommand("send", options: global) { context in
            let bubbles = try readBubbles()
            let attachments = try context.plan { _ in try SendPlanner.check(bubbles, files: file, wordsPerMinute: wpm, to: who) }
            guard timeout > 0 else {
                throw TincanError.usage("--timeout must be more than 0 seconds.", hint: "For example: --wait delivered --timeout 60")
            }
            guard (0...60).contains(bounceWait) else {
                throw TincanError.usage("--bounce-wait must be from 0 to 60 seconds.", hint: "For example: --bounce-wait 10, or 0 not to look.")
            }

            let config = try context.config()
            let database = try context.messages()
            let resolver = try context.resolver()
            let planner = SendPlanner(
                resolver: resolver, region: context.region, activity: resolver.activity, exclusions: config.excludedChats,
                ownAddresses: { try database.ownAddresses() }, relativeTime: { Formatting.relative($0) },
                recentServices: { chatID in
                    // Unreadable history leaves the service as Messages lists it.
                    (try? database.recentServices(
                        inChat: chatID, since: Date().addingTimeInterval(-SendPlanner.recentWindow), limit: SendPlanner.recentMessageCount)) ?? []
                }
            )
            let request = SendPlanner.Request(
                reference: who, bubbles: bubbles, files: attachments, service: service,
                typing: typing ?? config.typing, wordsPerMinute: wpm ?? config.wordsPerMinute, seed: seed
            )
            let plan = try context.plan { warnings in try planner.plan(request, warnings: &warnings) }
            let route = plan.route
            let to = Self.person(route, resolver: resolver, region: context.region)
            let participants = route.participants.map { Payload.person($0, resolver: resolver) }
            let planItems = plan.typing.bubbles.map {
                PlanItem(text: $0.text, pauseSeconds: Self.round($0.pauseBefore), typingSeconds: Self.round($0.typingDuration))
            }
            let files = attachments.isEmpty ? nil : attachments.map { FileRef(path: $0.path, bytes: $0.bytes) }

            if dryRun {
                if let warning = plan.newConversationWarning { context.warn([warning]) }
                context.output.result(Result(plan, to: to, participants: participants, dryRun: true, plan: planItems, bubbles: nil, files: files, ok: true))
                if !context.output.json { renderPlan(plan, to: to, participants: participants, context: context, dryRun: true) }
                return
            }
            let interactive = !context.output.json && Terminal.canPrompt
            if !interactive {
                // Scripts and assistants must state intent explicitly; nothing sends by default.
                guard yes else {
                    throw TincanError(
                        code: "confirmation_required",
                        message: "Sending without a terminal needs --yes.",
                        hint: "Only add --yes after the person approved this exact text and recipient. Preview with --dry-run.",
                        exit: .needsInput
                    )
                }
                try context.plan { _ in try plan.checkNewConversation(allowed: newConversation) }
            }
            if interactive && !yes {
                renderPlan(plan, to: to, participants: participants, context: context, dryRun: false)
                // Warnings such as a shared number belong before the question, not after it.
                context.output.flushWarnings()
                guard confirm(plan.question, context: context) else {
                    context.output.line(context.style.muted("Nothing was sent."))
                    context.programStatus.idle("Nothing was sent.")
                    return
                }
            }
            // The terminal's status counts what Messages confirmed, bubbles and files alike.
            let total = plan.typing.bubbles.count + plan.files.count
            let recipient = route.isSelf ? "yourself" : route.name
            let sending = "Sending \(Formatting.plural(total, "message")) to \(recipient)"
            context.programStatus.keepsOutcome = true
            context.programStatus.working(sending, progress: 0)
            if context.sources.isOverridden {
                // Messages would really send, to people from other data, and tincan could
                // never confirm it in a database Messages doesn't write to.
                let variables = Formatting.list(context.sources.overrides.map(\.variable))
                throw TincanError(
                    code: "sending_unavailable",
                    message: "tincan doesn't send while \(variables) \(context.sources.overrides.count == 1 ? "is" : "are") set.",
                    hint: "Sending is off while tincan reads other data, so nothing was sent. --dry-run still shows the plan."
                )
            }

            let automation: MessagesAutomation
            do {
                automation = try MessagesAutomation()
            } catch {
                throw TincanError(
                    code: "automation_unavailable", message: TincanError.sentence(String(describing: error)),
                    hint: "Run `tincan doctor` to check that Messages can be controlled.")
            }
            let sender = Sender(messages: database, automation: automation)
            if !context.output.json && yes {
                // No question was asked, so say where this is going before it goes.
                let width = min(context.terminal.width, 100)
                context.output.status(Self.header(route, to: to, region: context.region, width: width, style: context.style))
                for line in Self.fileLines(attachments, width: width, style: context.style) { context.output.status(line) }
                context.output.flushWarnings()
            }
            let live = LiveProgress(context: context, plan: plan.typing, status: sending, total: total)
            var outcomes = await sender.run(plan.request) { live.handle($0) }
            // Carriers text a refusal back within seconds, after Messages already said sent.
            let checksBounces =
                bounceWait > 0 && outcomes.contains { $0.status == .sent && [.sms, .rcs].contains($0.message?.service ?? route.service) }
            if checksBounces {
                live.status("Checking with the carrier…")
                outcomes = await sender.checkForBounces(outcomes, in: route.chat?.id, from: route.address, region: context.region, timeout: bounceWait)
                for (index, outcome) in outcomes.enumerated() where outcome.bounce != nil { live.handle(.sent(bubble: index, outcome: outcome)) }
            }
            if let wait, outcomes.contains(where: { $0.status == .sent || $0.status == .delivered }) {
                live.status("Waiting for \(wait.rawValue) receipts…")
                outcomes = await sender.waitForReceipts(outcomes, until: wait == .read ? .read : .delivered, timeout: timeout)
            }

            if outcomes.contains(where: \.automationDenied) {
                throw TincanError(
                    code: "automation_denied",
                    message: "macOS blocked tincan from asking Messages to send: \(PermissionHost.current.subject) isn't allowed to control Messages.",
                    hint: PermissionAdvice.grant(.automation), exit: .permission)
            }

            // Every bubble Messages recorded is one tincan sent, bounced or not. Written after
            // the result, so a ledger that can't be written never hides what was sent.
            func record() {
                let entries = outcomes.compactMap { $0.message.map { SendLedger.Entry(at: $0.date, guid: $0.guid) } }
                try? SendLedger.append(entries, to: context.sources.sendLedgerPath)
            }

            let results = outcomes.map { outcome in
                BubbleResult(
                    text: outcome.text, status: outcome.status.rawValue, method: outcome.method?.rawValue,
                    messageId: outcome.message?.id, at: outcome.message?.date, deliveredAt: outcome.message?.deliveredAt,
                    readAt: outcome.message?.readAt, error: outcome.error, errorCode: outcome.bounce == nil ? nil : "carrier_bounce",
                    bounce: outcome.bounce.map { Bounce(ref: $0.reference, text: $0.text, at: $0.date) }, note: outcome.note
                )
            }
            let succeeded = outcomes.filter { [.sent, .delivered, .read].contains($0.status) }.count
            let ok = succeeded == outcomes.count
            let delivered = outcomes.allSatisfy { [.delivered, .read].contains($0.status) }
            let result = Result(
                plan, to: to, participants: participants, dryRun: nil, plan: nil, bubbles: results, files: files, delivered: delivered,
                bounceCheckSeconds: checksBounces ? bounceWait : nil, ok: ok)
            if !context.output.json { live.summary(outcomes) }
            guard !ok else {
                context.programStatus.done("Sent \(Formatting.plural(total, "message")) to \(recipient).")
                // A new conversation has a chat once Messages records the first bubble.
                let conversation =
                    route.chat?.reference
                    ?? outcomes.compactMap { $0.message?.chatID }.last.map { "chat:\($0)" }
                    ?? to.address ?? who
                context.output.result(result, next: Self.replyNext(after: results, in: conversation))
                record()
                return
            }
            // Some or all bubbles didn't go: an error, with every bubble's status kept in data.
            let failure = Self.failure(statuses: outcomes.map(\.status), bounced: outcomes.filter { $0.bounce != nil }.count)
            if context.output.json { context.output.failure(failure, data: result) }
            context.programStatus.failed(failure.message)
            record()
            throw ExitCode(failure.exit.rawValue)
        }
    }

    /// The error for a send whose bubbles didn't all go, from each bubble's status and how
    /// many the carrier bounced. An unconfirmed bubble may still go out, so it is never
    /// reported as not sent.
    static func failure(statuses: [BubbleOutcome.Status], bounced: Int) -> TincanError {
        let succeeded = statuses.filter { [.sent, .delivered, .read].contains($0) }.count
        let unconfirmed = statuses.filter { $0 == .unconfirmed }.count
        let notSent = statuses.count - succeeded - unconfirmed
        let maybeLater =
            "Messages may still send \(unconfirmed == 1 ? "1 bubble" : "\(unconfirmed) bubbles") it hasn't confirmed"
            + (notSent > 0 ? ", and the rest were not sent." : ".")
        let bounceHint =
            "Tell the person it wasn't delivered; the carrier's notice is in each bubble's bounce. If the recipient uses iMessage, ask whether to send it again with `tincan send <reference> … --service imessage`. Never resend automatically."
        if bounced > 0 && succeeded == 0 {
            return TincanError(
                code: "carrier_bounce", message: "The carrier sent back a notice that the message wasn't delivered.", hint: bounceHint)
        }
        if bounced > 0 {
            return TincanError(
                code: "send_partial",
                message:
                    "Sent \(succeeded) of \(statuses.count) bubbles; the carrier sent back a notice that \(Formatting.plural(bounced, "bubble")) \(bounced == 1 ? "wasn't" : "weren't") delivered.",
                hint: bounceHint, exit: .partial)
        }
        if succeeded == 0 && unconfirmed > 0 {
            return TincanError(
                code: "send_unconfirmed", message: "Nothing was confirmed sent. \(maybeLater)",
                hint: "Check the conversation with `tincan read` before sending anything again. Never resend automatically.")
        }
        if succeeded == 0 {
            return TincanError(
                code: "send_failed", message: "Nothing was sent.",
                hint: "Read each bubble's status and error, and check the conversation with `tincan read` before trying again.")
        }
        return TincanError(
            code: "send_partial",
            message: "Sent \(succeeded) of \(statuses.count) bubbles. \(unconfirmed > 0 ? maybeLater : "The rest were not sent.")",
            hint: "Read the conversation with `tincan read` before sending the rest. Never resend automatically.", exit: .partial)
    }

    // MARK: Input

    private func readBubbles() throws -> [String] {
        var result: [String] = []
        for text in texts {
            if text == "-" {
                let input = FileHandle.standardInput.readDataToEndOfFile()
                // Windows line endings are line endings, not a stray control character.
                let content = String(decoding: input, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
                result += content.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            } else {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { throw TincanError.usage("A bubble is empty.", hint: "Remove the empty argument, or put text in it.") }
                result.append(trimmed)
            }
        }
        return result
    }

    // MARK: Rendering

    /// Who the send reaches, as results show a person: the card, or the address when it is
    /// on several cards, with every card that has it.
    static func person(_ route: SendRoute, resolver: Resolver, region: String?) -> Payload.PersonRef {
        var person: Payload.PersonRef
        switch route.addressee {
        case .address(let address):
            person = Payload.person(address, resolver: resolver)
        case .group(let name):
            person = Payload.PersonRef(name: name, address: nil, contact: nil, ambiguous: nil)
        case .person(let recipient, let address):
            // Who else has the address comes from `route.shared`, below.
            let card = Payload.person(recipient, region: region)
            person = Payload.PersonRef(
                name: card.name, address: address, contact: card.contact, ambiguous: card.ambiguous,
                possibleContacts: card.possibleContacts, match: card.match
            )
        }
        if route.nationalMatch { person.match = "national" }
        if let shared = route.shared {
            person.possibleContacts = shared.cards.map(Payload.ContactRef.init)
            if let others = shared.others {
                person.sharedWith = others.map(Payload.ContactRef.init)
            } else {
                person.ambiguous = true
            }
        }
        return person
    }

    private func renderPlan(_ send: SendPlan, to: Payload.PersonRef, participants: [Payload.PersonRef], context: Context, dryRun: Bool) {
        let route = send.route
        let plan = send.typing
        let style = context.style
        let output = context.output
        let width = min(context.terminal.width, 100)
        output.line(Self.header(route, to: to, region: context.region, width: width, style: style))
        let serviceNoted = route.serviceSwitched || (route.recentService.map { $0 != route.service } ?? false)
        if route.chat == nil || route.reason.hasPrefix("the most recent") || serviceNoted {
            for line in TextWidth.wrap(TincanError.sentence(route.reason), width: width - 2) { output.line("  " + style.muted(line)) }
        }
        if !participants.isEmpty {
            // Everyone who will read it, by name and number. A number is never split across lines.
            let people = participants.map { person -> String in
                let address = person.address.map { Address($0, region: context.region).formatted }
                guard let address, address != person.name else { return person.name }
                return "\(person.name) \(address.replacingOccurrences(of: " ", with: String(TextWidth.glue)))"
            }
            for line in TextWidth.wrapGlued("With " + Formatting.list(people + ["you"]) + ".", width: width - 2) { output.line("  " + style.muted(line)) }
        }
        let timings = plan.bubbles.map { bubble -> String in
            var timing: [String] = []
            if bubble.pauseBefore > 0 { timing.append("waits \(String(format: "%.1f", bubble.pauseBefore))s") }
            if bubble.typingDuration > 0 { timing.append("types \(String(format: "%.1f", bubble.typingDuration))s") }
            return timing.joined(separator: " · ")
        }
        let numberWidth = String(plan.bubbles.count).count
        let timingWidth = timings.map(TextWidth.columns).max() ?? 0
        let textWidth = max(12, width - 2 - numberWidth - 2 - (timingWidth > 0 ? 2 + timingWidth : 0))
        let color: Style.Role = route.service == .iMessage ? .imessage : .sms
        for (index, bubble) in plan.bubbles.enumerated() {
            let lines = TextWidth.wrap(bubble.text, width: textWidth)
            for (offset, line) in lines.enumerated() {
                let number = offset == 0 ? TextWidth.padLeft("\(index + 1)", to: numberWidth) : String(repeating: " ", count: numberWidth)
                var row = "  " + style.muted(number) + "  " + style.color(line, color)
                if offset == 0, !timings[index].isEmpty {
                    row += String(repeating: " ", count: max(2, textWidth - TextWidth.columns(line) + 2)) + style.muted(timings[index])
                }
                output.line(row)
            }
        }
        for line in Self.fileLines(send.files, width: width, style: style) { output.line(line) }
        let total = plan.totalDuration
        for line in TextWidth.wrap("About \(String(format: "%.0f", max(1, total)))s · \(send.methodReason)", width: width - 2) {
            output.line("  " + style.muted(line))
        }
        if dryRun { output.line(style.muted("Dry run: nothing was sent.")) }
    }

    /// `To Maya Chen  ·  iMessage  ·  chat:42`: who, the service, and the conversation, or for
    /// a new one the formatted address, unless the title already is that address.
    private static func header(_ route: SendRoute, to: Payload.PersonRef, region: String?, width: Int, style: Style) -> String {
        let title = route.isSelf ? "yourself" : to.name
        var details = [route.service.displayName + (route.serviceGuessed ? "?" : "")]
        if let chat = route.chat {
            details.append(chat.reference)
        } else if let address = to.address.map({ Address($0, region: region).formatted }), address != title {
            details.append(address)
        }
        return Layout.header("To " + title, details: details, trailing: "", width: width, style: style)
    }

    static func round(_ value: Double) -> Double { (value * 10).rounded() / 10 }

    /// Each attachment with its full path and size, so the person sees exactly what goes.
    static func fileLines(_ attachments: [Attachments.File], width: Int, style: Style) -> [String] {
        attachments.flatMap { file in
            Layout.hanging(file.path + " · " + Formatting.bytes(file.bytes), first: "  📎 ", rest: "     ", width: width).map(style.muted)
        }
    }
}

extension MessageService: ExpressibleByArgument {
    /// Only the services tincan can send over; `text` is accepted as another name for SMS.
    public init?(argument: String) {
        switch argument.lowercased() {
        case "imessage": self = .iMessage
        case "sms", "text": self = .sms
        case "rcs": self = .rcs
        default: return nil
        }
    }

    public static var allValueStrings: [String] { ["imessage", "sms", "rcs"] }
}

extension Config.TypingMode: ExpressibleByArgument {}

/// Live, single-line progress while bubbles are typed and sent, and the terminal's status:
/// `status`, with how many of `total` bubbles and files Messages confirmed.
final class LiveProgress {
    private let context: Context
    private let plan: TypingPlan
    private let interactive: Bool
    private let statusMessage: String
    private let total: Int
    private var confirmed = 0

    init(context: Context, plan: TypingPlan, status: String, total: Int) {
        self.context = context
        self.plan = plan
        statusMessage = status
        self.total = total
        interactive = !context.output.json && context.terminal.isInteractive
    }

    func handle(_ event: SendEvent) {
        if case .sent(_, let outcome) = event, Send.confirmedStatuses.contains(outcome.status.rawValue), total > 0 {
            confirmed += 1
            context.programStatus.working(statusMessage, progress: confirmed * 100 / total)
        }
        guard !context.output.json else { return }
        let style = context.style
        switch event {
        case .waiting(let bubble, _):
            transient(style.muted("  \(bubble + 1)  …"))
        case .typing(let bubble, let seconds):
            transient(style.muted("  \(bubble + 1)  typing… ") + style.muted(String(format: "%.1fs", seconds)))
        case .sent(_, let outcome):
            let mark: String
            switch outcome.status {
            case .sent, .delivered, .read: mark = style.success("✓")
            case .skipped: mark = style.muted("–")
            default: mark = style.danger("✗")
            }
            let problem = outcome.status == .failed || outcome.status == .unconfirmed
            let detail = problem ? (outcome.error ?? outcome.status.rawValue) : outcome.status.rawValue
            let width = min(context.terminal.width, 100)
            let detailText = TextWidth.truncate(detail, to: max(10, width / 2))
            let text = TextWidth.truncate(outcome.text.replacingOccurrences(of: "\n", with: " "), to: max(8, width - 4 - 2 - TextWidth.columns(detailText)))
            permanent("  \(mark) " + text + "  " + (problem ? style.danger(detailText) : style.muted(detailText)))
        case .fallback(_, let reason):
            permanent(style.warning("  ! ") + style.muted(reason + "; pacing instead"))
        }
    }

    /// A wait after sending, such as for receipts, whose length is unknown.
    func status(_ text: String) {
        context.programStatus.working(text)
        guard !context.output.json else { return }
        transient(context.style.muted("  " + text))
    }

    func summary(_ outcomes: [BubbleOutcome]) {
        clear()
        let sent = outcomes.filter { [.sent, .delivered, .read].contains($0.status) }
        let style = context.style
        if sent.count == outcomes.count {
            let read = outcomes.filter { $0.status == .read }.count
            let delivered = outcomes.filter { $0.status == .delivered }.count
            var line = style.success("Sent \(Formatting.plural(sent.count, "message")).")
            if read > 0 {
                line += style.muted(" Read.")
            } else if delivered > 0 {
                line += style.muted(" Delivered.")
            } else {
                line += style.muted(" Not yet confirmed delivered.")
            }
            context.output.line(line)
        } else {
            let bounced = outcomes.filter { $0.bounce != nil }.count
            let unconfirmed = outcomes.filter { $0.status == .unconfirmed }.count
            let rest =
                bounced > 0
                ? " The carrier didn't deliver \(bounced == 1 ? "one" : "\(bounced)"); see above."
                : unconfirmed > 0
                    ? " Messages may still send \(unconfirmed == 1 ? "one" : "\(unconfirmed)") it hasn't confirmed; check before sending again."
                    : " The rest were not sent; see above."
            context.output.line(style.warning("Sent \(sent.count) of \(outcomes.count).") + style.muted(rest))
        }
    }

    private func transient(_ text: String) {
        guard interactive else { return }
        FileHandle.standardError.write(Data(("\r\u{1B}[2K" + TerminalText.sanitize(text, keepStyles: context.style.enabled)).utf8))
    }

    private func permanent(_ text: String) {
        clear()
        context.output.status(text)
    }

    private func clear() {
        guard interactive else { return }
        FileHandle.standardError.write(Data("\r\u{1B}[2K".utf8))
    }
}
