import ArgumentParser
import Foundation
import TincanKit

struct Calls: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Phone and FaceTime call history, with names from Contacts.",
        discussion: """
            Reads the call history your iPhone syncs to this Mac, newest first. Missed calls show whether you called or texted back afterwards. Outgoing calls without talk time were not answered, busy or cancelled; Apple does not record which. A hidden or unknown number shows as Unknown caller (`caller: "unknown"` and an empty `with` in JSON), and tincan can't tell whether you got back to it.

            Examples:
              tincan calls
              tincan calls --missed --since 7d
              tincan calls Maya
              tincan calls chat:42 --limit 10
              tincan calls --before 2026-09-01 --json
            """
    )

    @Argument(
        help: ArgumentHelp(
            "Only calls with this person, or with the people in chat:<id>: a name, phone number, email, address:<address>, contact:<id>, chat:<id>, or `me` for your own addresses.",
            valueName: "who"))
    var who: String?

    @Flag(help: "Only missed calls.")
    var missed = false

    @Option(help: "Only calls after this time: \(Help.times).")
    var since: String?

    @Option(help: "Only calls before this time, such as the `next.cursor` of a previous page: \(Help.times).")
    var before: String?

    static let defaultLimit = 25

    @Option(name: [.customShort("n"), .long], help: "Number of calls to show.")
    var limit: Int = Calls.defaultLimit

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await runCommand("calls", options: global) { context in
            try requireLimit(limit)
            let history = try context.calls()
            let sinceDate = try since.map { try parseTime($0, option: "--since") }
            let beforeDate = try before.map { try parseTime($0, option: "--before") }
            let resolver: Resolver
            do {
                resolver = try context.resolver()
            } catch {
                // Messages may be unavailable; names still come from Contacts.
                context.output.warn("messages_unavailable", "Messages can't be read (\(TincanError.wrap(error).message)), so texts back aren't checked.")
                resolver = Resolver(directory: try context.directory(), chats: [], handles: [])
            }
            var addresses: Set<String>?
            if let who {
                switch try context.resolve(who, command: "calls") {
                case .person(let person):
                    addresses = resolver.canonicalAddresses(of: person)
                    context.warnSharedAddress(person)
                case .chat(let chat) where chat.kind == .direct:
                    // The person behind a one-to-one conversation, with all their addresses,
                    // as if you had named them.
                    let other = resolver.person(forAddress: chat.participants.first ?? chat.identifier)
                    addresses = resolver.canonicalAddresses(of: other)
                    context.warnSharedAddress(other)
                case .chat(let chat):
                    addresses = Set((chat.participants.isEmpty ? [chat.identifier] : chat.participants).map { Address($0, region: context.region).value })
                }
            }
            var calls = try history.calls(since: sinceDate, before: beforeDate, missedOnly: missed, addresses: addresses, limit: limit + 1)
            let hasMore = calls.count > limit
            calls = Array(calls.prefix(limit))
            if hasMore { context.output.warnTruncated(calls.count, missed ? "missed call" : "call", limit: limit, pages: true) }
            let followUps = Self.followUps(for: calls, history: history, context: context, resolver: resolver)
            let payload = calls.map { Payload.call($0, resolver: resolver, returned: followUps[$0.id]) }
            var next: Output.Next?
            var earlier = "tincan calls"
            if hasMore, let oldest = calls.last {
                let cursor = Formatting.cursor(oldest.date)
                if let who { earlier += " \(shellQuote(who))" }
                if missed { earlier += " --missed" }
                if let since { earlier += " --since \(shellQuote(since))" }
                earlier += " --before \(cursor)"
                next = Output.Next(cursor: cursor, command: earlier + " --limit \(limit) --json")
            }
            context.output.result(payload, next: next, hasMore: next != nil)
            guard !context.output.json else { return }
            let style = context.style
            if payload.isEmpty {
                context.output.line(style.muted(missed ? "No missed calls." : "No calls."))
                return
            }
            let width = min(context.terminal.width, 100)
            for line in CallsRendering.lines(payload, style: style, width: width, showName: true) { context.output.line(line) }
            if hasMore {
                // The JSON command without --json, keeping a page size you chose.
                let command = earlier + (limit == Self.defaultLimit ? "" : " --limit \(limit)")
                for line in TextWidth.wrapCommand("Earlier: " + command, width: width) { context.output.hint(line) }
            }
        }
    }

    /// For each missed call, the first later outgoing call or text to the same person. Each
    /// person's addresses and conversations are worked out once, so long histories stay fast.
    static func followUps(for calls: [Call], history: CallHistoryDatabase, context: Context, resolver: Resolver) -> [Int64: Payload.FollowUp] {
        let missed = calls.filter(\.isMissed)
        guard let oldest = missed.map(\.date).min() else { return [:] }
        let region = context.region
        var canonicalCache: [String: String] = [:]
        func canonical(_ raw: String) -> String {
            if let cached = canonicalCache[raw] { return cached }
            let value = Address(raw, region: region).value
            canonicalCache[raw] = value
            return value
        }

        // Outgoing calls after the oldest missed one, by address, oldest first.
        var callsOut: [String: [Date]] = [:]
        for call in ((try? history.calls(since: oldest)) ?? []).reversed() where call.direction == .outgoing {
            for address in Set(call.addresses.map(canonical)) { callsOut[address, default: []].append(call.date) }
        }
        // One-to-one conversations by address.
        var chatsByAddress: [String: [Int64]] = [:]
        for chat in resolver.chats where chat.kind == .direct && !resolver.excludedChatIDs.contains(chat.id) {
            let others = chat.participants.isEmpty ? [chat.identifier] : chat.participants
            guard others.count == 1 else { continue }
            chatsByAddress[canonical(others[0]), default: []].append(chat.id)
        }
        // Every address of the person behind an address.
        var peopleCache: [String: Set<String>] = [:]
        func personAddresses(_ raw: String) -> Set<String> {
            let key = canonical(raw)
            if let cached = peopleCache[key] { return cached }
            var result: Set<String> = [key]
            if let contact = resolver.directory.uniqueContact(for: raw) {
                result.formUnion(resolver.person(for: contact).addresses.map(canonical))
            }
            peopleCache[key] = result
            return result
        }

        let messages = try? context.messages()
        var result: [Int64: Payload.FollowUp] = [:]
        for call in missed {
            let wanted = call.addresses.reduce(into: Set<String>()) { $0.formUnion(personAddresses($1)) }
            let callBack = wanted.compactMap { address in callsOut[address]?.first { $0 > call.date } }.min()
            var textBack: Date?
            if let messages {
                let chats = Set(wanted.flatMap { chatsByAddress[$0] ?? [] })
                for chat in chats {
                    if let reply = try? messages.firstOutgoingDate(inChat: chat, after: call.date) {
                        textBack = min(textBack ?? reply, reply)
                    }
                }
            }
            if let callBack, textBack.map({ callBack <= $0 }) ?? true {
                result[call.id] = Payload.FollowUp(via: "call", at: callBack)
            } else if let textBack {
                result[call.id] = Payload.FollowUp(via: "message", at: textBack)
            }
        }
        return result
    }
}

enum CallsRendering {
    /// Aligned call lines, newest first:
    ///
    ///     ↙ Maya Chen          Missed · called back in 5m   9:41 PM
    ///     ↗ +1 (415) 555-0199  4m 05s · FaceTime video      yesterday
    static func lines(_ calls: [Payload.Call], style: Style, width: Int, showName: Bool, indent: Int = 0) -> [String] {
        let names = calls.map { call -> String in
            // A hidden or unknown number has no address, so no name and no follow-up.
            call.caller == "unknown" || call.with.isEmpty ? "Unknown caller" : call.with.map(\.name).joined(separator: ", ")
        }
        let times = calls.map { Formatting.relative($0.at) }
        let timeWidth = times.map(TextWidth.columns).max() ?? 0
        let room = width - indent - 2 - 2 - timeWidth
        // Room for a whole formatted number (17 columns) before details get more.
        // A whole phone number (17 columns) while details keep their 10.
        let nameWidth = showName ? min(24, max(min(17, room - 12), room / 3), names.map(TextWidth.columns).max() ?? 0) : 0
        // Sized to the longest details, so times sit near them rather than at the far edge.
        let widestDetail =
            calls.map { TextWidth.columns(Layout.parts(details($0, style: Style(depth: .none)), width: .max, style: Style(depth: .none))) }.max() ?? 0
        let detailWidth = max(10, min(widestDetail, room - (showName ? nameWidth + 2 : 0)))
        return zip(calls, zip(names, times)).map { call, labels in
            let incoming = call.direction == "incoming"
            var line = String(repeating: " ", count: indent) + style.color(incoming ? "↙" : "↗", incoming ? .imessage : .success) + " "
            if showName { line += TextWidth.fit(labels.0, to: nameWidth) + "  " }
            line += TextWidth.padRight(Layout.parts(details(call, style: style), width: detailWidth, style: style), to: detailWidth)
            return line + "  " + style.muted(TextWidth.padLeft(labels.1, to: timeWidth))
        }
    }

    /// The parts after the name, each with its color: status, kind, follow-up, junk.
    private static func details(_ call: Payload.Call, style: Style) -> [Layout.Part] {
        let plain: (String) -> String = { $0 }
        let kind: String
        switch call.kind {
        case "facetime_video": kind = "FaceTime video"
        case "facetime_audio": kind = "FaceTime audio"
        case "app": kind = call.provider.map { $0.split(separator: ".").last.map(String.init) ?? $0 } ?? "App"
        default: kind = "Phone"
        }
        var parts: [Layout.Part] = []
        switch call.outcome {
        case "missed": parts.append(("Missed", style.danger))
        case "not_connected": parts.append(("No answer", style.muted))
        default: parts.append((Formatting.duration(TimeInterval(call.durationSeconds)), plain))
        }
        // What happened next matters more than the kind of call, which is usually a phone call.
        if let returned = call.returned {
            let gap = Formatting.gap(returned.at.timeIntervalSince(call.at))
            parts.append((returned.via == "call" ? "called back in \(gap)" : "texted back in \(gap)", style.success))
        } else if call.outcome == "missed", call.junk != true, call.caller != "unknown" {
            // Only a known number can be called back; for hidden callers tincan can't tell.
            parts.append(("not returned", style.warning))
        }
        if call.kind != "phone" { parts.append((kind, plain)) }
        if call.junk == true { parts.append(("junk", style.muted)) }
        return parts
    }
}
