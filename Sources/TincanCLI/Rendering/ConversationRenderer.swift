import Foundation
import TincanKit

/// Renders messages the way Messages lays them out: yours on the right in iMessage blue or
/// SMS green, everyone else on the left, with day headings and a timestamp after pauses.
/// Every line fits in `width` columns.
struct ConversationRenderer {
    let style: Style
    let width: Int
    let resolver: Resolver
    let isGroup: Bool
    var showIDs = false
    var now = Date()
    /// You sent a message after these, so none of yours here is your latest, the only one
    /// that shows whether it was delivered or read.
    var youSentLater = false

    /// Whether `message` can carry delivery status: one you sent, still there, not a group change.
    static func showsStatus(_ message: Message) -> Bool {
        message.isFromMe && !message.isUnsent && message.kind != .event
    }

    /// A pause longer than this starts a new run and shows the time.
    static let pause: TimeInterval = 15 * 60

    /// Messages must be oldest first. `quotes` resolves reply targets by GUID.
    func render(_ messages: [Message], quotes: [String: Message] = [:]) -> [String] {
        var addresses: [String] = []
        for message in messages {
            addresses += [message.sender, message.event?.subject].compactMap { $0 } + message.reactions.compactMap(\.from)
        }
        addresses += quotes.values.compactMap(\.sender)
        var renderer = self
        renderer.names = SenderNames(addresses, directory: resolver.directory)
        return renderer.lines(messages, quotes: quotes)
    }

    /// Labels for the people in this conversation, worked out by `render`.
    var names: SenderNames?

    private func lines(_ messages: [Message], quotes: [String: Message]) -> [String] {
        var lines: [String] = []
        let calendar = Calendar.current
        var previous: Message?
        let lastMine = youSentLater ? nil : messages.last(where: Self.showsStatus)
        // "via tincan" closes each run of your messages that tincan sent, not each bubble.
        let tincanRunEnds = Set(
            messages.indices.compactMap { index in
                messages[index].sentByTincan && !(index + 1 < messages.count && messages[index + 1].sentByTincan) ? messages[index].id : nil
            })
        let senders = messages.compactMap { $0.isFromMe ? nil : $0.sender.map(shortName) }
        let nameWidth = isGroup ? min(14, max(3, senders.map(TextWidth.columns).max() ?? 3)) : 0
        let gutter = isGroup ? nameWidth + 2 : 0
        let bubbleWidth = max(16, min(Int(Double(width) * 0.7), width - gutter))

        for message in messages {
            if previous == nil || !calendar.isDate(previous!.date, inSameDayAs: message.date) {
                if !lines.isEmpty { lines.append("") }
                lines += centered(Formatting.dayHeading(message.date, now: now), style: style.muted)
                lines.append("")
            } else if let previous, message.date.timeIntervalSince(previous.date) > Self.pause {
                lines.append("")
                lines += centered(Formatting.time(message.date), style: style.muted)
            } else if let previous, previous.isFromMe != message.isFromMe || previous.sender != message.sender || previous.event != nil || message.event != nil
            {
                // A little air between speakers, as in Messages.
                lines.append("")
            }

            if let event = message.event {
                lines += centered(describe(event, actor: message)) { style.italic(style.muted($0)) }
                previous = message
                continue
            }
            if message.isUnsent {
                let who = message.isFromMe ? "You" : shortName(message.sender ?? "")
                lines += centered("\(who) unsent a message") { style.italic(style.muted($0)) }
                previous = message
                continue
            }

            let startsRun =
                previous == nil || previous?.isFromMe != message.isFromMe || previous?.sender != message.sender
                || previous?.event != nil || message.date.timeIntervalSince(previous!.date) > Self.pause
            let body = bubble(message, quotes: quotes, width: bubbleWidth)

            if message.isFromMe {
                // Right-aligned as a block, so a wrapped message keeps a straight left edge.
                let blockWidth = body.map(TextWidth.columns).max() ?? 0
                let indent = String(repeating: " ", count: max(0, width - blockWidth))
                lines += body.map { indent + $0 }
                var meta: [String] = []
                if message.failed { meta.append(style.danger("Not delivered")) }
                if tincanRunEnds.contains(message.id) { meta.append(style.muted("via tincan")) }
                if message.id == lastMine?.id, !message.failed {
                    if let read = message.readAt {
                        meta.append(style.muted("Read " + Formatting.relative(read, now: now)))
                    } else if message.deliveredAt != nil {
                        meta.append(style.muted("Delivered"))
                    } else if message.service == .sms {
                        meta.append(style.muted("Sent as text message"))
                    }
                }
                if showIDs { meta.append(style.muted(message.reference)) }
                if !meta.isEmpty { lines.append(TextWidth.padLeft(meta.joined(separator: style.muted(" · ")), to: width)) }
            } else {
                let name = shortName(message.sender ?? "")
                for (index, line) in body.enumerated() {
                    var prefix = ""
                    if isGroup {
                        let label = index == 0 && startsRun ? TextWidth.truncate(name, to: nameWidth) : ""
                        prefix = style.muted(TextWidth.padRight(label, to: nameWidth)) + "  "
                    }
                    lines.append(prefix + line)
                }
                if showIDs {
                    lines.append(String(repeating: " ", count: gutter) + style.muted(message.reference))
                }
            }
            previous = message
        }
        return lines
    }

    // MARK: Bubbles

    /// The lines of one message: reply quote, text, attachments and reactions, each at most
    /// `width` columns.
    private func bubble(_ message: Message, quotes: [String: Message], width: Int) -> [String] {
        var lines: [String] = []
        if let replyGUID = message.replyToGUID {
            let quoted = quotes[replyGUID]
            let who = quoted.map { $0.isFromMe ? "You" : shortName($0.sender ?? "") }
            let snippet = quoted.map { Self.snippet($0) } ?? "an earlier message"
            let text = who.map { "\($0): \(snippet)" } ?? snippet
            lines.append(style.muted(TextWidth.truncate("↪ " + text, to: width)))
        }
        lines += content(message, width: width)
        for attachment in message.attachments {
            lines.append(style.muted(TextWidth.truncate("📎 " + describe(attachment), to: width)))
        }
        if !message.reactions.isEmpty {
            let names = message.reactions.map { reaction in
                reaction.symbol + " " + (reaction.from.map(shortName) ?? "You")
            }
            lines += TextWidth.wrap(names.joined(separator: "  "), width: width).map(style.muted)
        }
        return lines
    }

    /// Text lines, colored for your own messages, with "(edited)" and effects after the text.
    private func content(_ message: Message, width: Int) -> [String] {
        var text = Self.revealed(message.text, style: style)
        switch message.kind {
        case .audio where text.isEmpty: text = "🎤 Audio message"
        case .app: text = "▦ " + (message.appName ?? "App") + (text.isEmpty ? "" : ": " + text)
        default: break
        }
        var lines: [String] = []
        if let subject = message.subject, !subject.isEmpty {
            lines = withSubject(subject, text, message, width: width)
        } else if !text.isEmpty {
            lines = TextWidth.wrap(text, width: width).map { paint($0, message) }
        }
        var notes: [String] = []
        if message.isEdited { notes.append("edited") }
        if let effect = message.expressiveEffect { notes.append("✨ " + effect.replacingOccurrences(of: "_", with: " ")) }
        if !notes.isEmpty {
            let note = "(" + notes.joined(separator: ", ") + ")"
            if let last = lines.last, TextWidth.columns(last) + 1 + TextWidth.columns(note) <= width {
                lines[lines.count - 1] = last + " " + style.muted(note)
            } else {
                lines.append(style.muted(TextWidth.truncate(note, to: width)))
            }
        }
        return lines
    }

    /// A subject and text as one bubble: the subject leads the first line in bold, and the
    /// text follows it after a dot, wrapped with it. On lines of their own, a subject reads
    /// as a message of its own.
    private func withSubject(_ subject: String, _ text: String, _ message: Message, width: Int) -> [String] {
        // The dot stays on the subject's line, never starting the next.
        let separator = text.isEmpty ? "" : "\u{00A0}· "
        let combined = subject + separator + text
        // Count in Unicode scalars: characters can merge where the parts meet, as when a
        // subject ends in a prepended mark, so counting characters can run past the end.
        let scalars = combined.unicodeScalars
        let subjectEnd = scalars.index(scalars.startIndex, offsetBy: subject.unicodeScalars.count)
        let textStart = scalars.index(subjectEnd, offsetBy: separator.unicodeScalars.count)
        var cursor = combined.startIndex
        return TextWidth.wrap(combined, width: width).map { line in
            // Each line is a run of `combined`, less the space or line break before it.
            guard !line.isEmpty, let range = combined.range(of: line, range: cursor..<combined.endIndex) else { return line }
            cursor = range.upperBound
            func part(_ from: String.Index, _ to: String.Index) -> String {
                from < to ? String(scalars[from..<to]) : ""
            }
            let lead = part(range.lowerBound, min(range.upperBound, subjectEnd))
            let dot = part(max(range.lowerBound, subjectEnd), min(range.upperBound, textStart))
            let rest = part(max(range.lowerBound, textStart), range.upperBound)
            return (lead.isEmpty ? "" : style.bold(paint(lead, message)))
                + (dot.isEmpty ? "" : style.muted(dot.replacingOccurrences(of: "\u{00A0}", with: " ")))
                + (rest.isEmpty ? "" : paint(rest, message))
        }
    }

    private func paint(_ line: String, _ message: Message) -> String {
        guard message.isFromMe else { return line }
        return style.color(line, message.service == .iMessage ? .imessage : .sms)
    }

    private func shortName(_ address: String) -> String {
        names?.label(address) ?? resolver.directory.shortName(for: address)
    }

    private func describe(_ attachment: Attachment) -> String {
        let name = attachment.summary ?? attachment.name ?? attachment.category
        var parts = [name]
        if attachment.bytes > 0, !attachment.isEmojiImage { parts.append(Formatting.bytes(attachment.bytes)) }
        if attachment.path == nil, !attachment.isEmojiImage { parts.append("not downloaded") }
        return parts.joined(separator: " · ")
    }

    private func describe(_ event: ConversationEvent, actor message: Message) -> String {
        Self.describe(event, actor: message, name: shortName)
    }

    /// A group change as a sentence: "Maya added Sam", "You named the conversation “Crew”".
    static func describe(_ event: ConversationEvent, actor message: Message, directory: Directory) -> String {
        describe(event, actor: message) { directory.shortName(for: $0) }
    }

    private static func describe(_ event: ConversationEvent, actor message: Message, name: (String) -> String) -> String {
        let actor = message.isFromMe ? "You" : name(message.sender ?? "")
        let subject = event.subject.map(name) ?? "someone"
        switch event.kind {
        case .added: return "\(actor) added \(subject)"
        case .removed: return "\(actor) removed \(subject)"
        case .joined: return "\(actor) joined"
        case .left: return "\(actor) left the conversation"
        case .renamed: return event.title.map { "\(actor) named the conversation “\($0)”" } ?? "\(actor) removed the conversation name"
        case .photoChanged: return "\(actor) changed the group photo"
        case .other: return "\(actor) updated the conversation"
        }
    }

    /// `text` wrapped to the width and centered, each line styled.
    private func centered(_ text: String, style apply: (String) -> String) -> [String] {
        TextWidth.wrap(text, width: width).map { line in
            String(repeating: " ", count: max(0, (width - TextWidth.columns(line)) / 2)) + apply(line)
        }
    }

    /// One-line summary of a message for lists, with group changes spelled out.
    static func summary(_ message: Message, directory: Directory) -> String {
        if let event = message.event { return describe(event, actor: message, directory: directory) }
        return snippet(message)
    }

    /// `text` with hidden text (`HiddenText`) made visible, dimmed when `style` has colors:
    /// `⟨hidden: …⟩` with the text that tag characters and variation selectors spell. Runs that spell nothing, such
    /// as zero-width spaces from pasted text, are dropped. The marker replaces them before
    /// wrapping, so it takes its place in the layout like any other text.
    static func revealed(_ text: String, style: Style? = nil) -> String {
        HiddenText.replacingRuns(in: text) { run in
            guard !run.decoded.isEmpty else { return "" }
            let marker = "⟨hidden: \(run.decoded)⟩"
            return style?.dim(marker) ?? marker
        }
    }

    /// One-line summary of a message for lists and quotes.
    static func snippet(_ message: Message) -> String {
        if message.isUnsent { return "Unsent message" }
        if let event = message.event { return "(\(event.kind.rawValue.replacingOccurrences(of: "_", with: " ")))" }
        let text = revealed(message.text).replacingOccurrences(of: "\n", with: " ")
        if !text.isEmpty {
            if message.kind == .app { return (message.appName ?? "App") + ": " + text }
            return text
        }
        if message.kind == .audio { return "Audio message" }
        if message.kind == .app { return message.appName ?? "App message" }
        if let attachment = message.attachments.first {
            switch attachment.category {
            case "image": return "Photo"
            case "video": return "Video"
            case "audio": return "Audio"
            case "sticker": return "Sticker"
            case "genmoji": return attachment.summary ?? "Genmoji"
            case "contact": return "Contact card"
            default: return attachment.name ?? "Attachment"
            }
        }
        return "Message"
    }
}
