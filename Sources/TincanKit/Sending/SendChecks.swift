import Foundation

/// What a bubble may hold: text, emoji, new lines and tabs, but nothing that makes the preview
/// differ from what the other person sees.
public enum BubbleText {
    /// People rarely send more in a row.
    public static let maximumBubbles = 12
    public static let maximumCharacters = 4_000

    /// A character a bubble can't hold, and the bubble it is in.
    public struct HiddenCharacter: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// A control character other than a new line or tab, which Messages sends as is.
            case control
            /// A character that reorders or breaks the text where the preview doesn't.
            case layout
            /// A character Messages doesn't show, which could hide text.
            case invisible
        }

        /// The bubble's position, from 0.
        public let index: Int
        /// The character as `U+001B (escape)`, with its name when people often paste it.
        public let description: String
        public let kind: Kind
    }

    /// Names of the control and formatting characters people most often paste by accident.
    static let controlNames: [UInt32: String] = [
        0x00: "null", 0x07: "bell", 0x08: "backspace", 0x0B: "vertical tab", 0x0C: "form feed",
        0x0D: "carriage return", 0x1B: "escape", 0x7F: "delete",
        0x202A: "left-to-right embedding", 0x202B: "right-to-left embedding", 0x202C: "pop directional formatting",
        0x202D: "left-to-right override", 0x202E: "right-to-left override",
        0x2066: "left-to-right isolate", 0x2067: "right-to-left isolate", 0x2068: "first strong isolate",
        0x2069: "pop directional isolate", 0x2028: "line separator", 0x2029: "paragraph separator",
    ]

    /// The first bubble with a character the preview can't show as Messages would, and that
    /// character as `U+001B (escape)`: a control character other than a new line or tab (C0,
    /// DEL or C1), which Messages sends as is, where it can hide text or garble the other
    /// person's screen; bidirectional embeddings, overrides and isolates, which reorder the
    /// text around them; and line and paragraph separators, which break it where the
    /// preview doesn't. Also characters Messages doesn't show that can spell hidden text
    /// (`HiddenText`): tag characters outside an emoji flag, and variation selectors
    /// carrying data.
    public static func firstHiddenCharacter(in bubbles: [String]) -> HiddenCharacter? {
        for (index, bubble) in bubbles.enumerated() {
            let kind: HiddenCharacter.Kind
            let scalar: Unicode.Scalar
            if let found = bubble.unicodeScalars.first(where: isHidden) {
                scalar = found
                kind = found.properties.generalCategory == .control ? .control : .layout
            } else if let found = HiddenText.firstSpelling(in: bubble) {
                scalar = found
                kind = .invisible
            } else {
                continue
            }
            let code = String(format: "U+%04X", scalar.value)
            let name =
                controlNames[scalar.value]
                ?? (HiddenText.isTag(scalar) ? "tag character" : HiddenText.isVariationSelector(scalar) ? "variation selector" : nil)
            return HiddenCharacter(index: index, description: name.map { "\(code) (\($0))" } ?? code, kind: kind)
        }
        return nil
    }

    private static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A, 0x09: return false
        case 0x202A...0x202E, 0x2066...0x2069, 0x2028, 0x2029: return true
        default: return scalar.properties.generalCategory == .control
        }
    }
}

extension SendPlanner {
    /// Checks what a send carries before any data is opened: at least one bubble or file, at
    /// most 12 bubbles of at most 4,000 characters, no bubble with a character the preview
    /// can't show as Messages would (`BubbleText`), files `Attachments` allows, and a typing
    /// speed from 5 to 250 words per minute. Returns each file where it really is.
    /// `reference` is who the send is for, which the hint for an empty send repeats.
    public static func check(_ bubbles: [String], files: [String], wordsPerMinute: Double?, to reference: String) throws -> [Attachments.File] {
        guard !bubbles.isEmpty || !files.isEmpty else {
            throw PlanRefusal.issue(.invalidInput("Nothing to send.", hint: "Pass the text as arguments: `tincan send \(shellQuote(reference)) \"hello\"`."))
        }
        guard bubbles.count <= BubbleText.maximumBubbles else {
            throw PlanRefusal.issue(
                .invalidInput(
                    "That's \(bubbles.count) bubbles; tincan sends at most 12 at a time.",
                    hint: "People rarely send more in a row. Split it up or combine lines into fewer bubbles."))
        }
        if let long = bubbles.first(where: { $0.count > BubbleText.maximumCharacters }) {
            throw PlanRefusal.issue(
                .invalidInput("A bubble has \(long.count.formatted()) characters; the limit is 4,000.", hint: "Split it into several bubbles."))
        }
        if let hidden = BubbleText.firstHiddenCharacter(in: bubbles) {
            let bubble = bubbles.count == 1 ? "The bubble" : "Bubble \(hidden.index + 1)"
            let reason: String
            switch hidden.kind {
            case .control: reason = "a control character, \(hidden.description), which Messages would send as is."
            case .layout: reason = "\(hidden.description), which changes how Messages shows the text, so the preview isn't what they would see."
            case .invisible: reason = "\(hidden.description), which Messages doesn't show, so it would hide text from them."
            }
            throw PlanRefusal.issue(
                .invalidInput(
                    "\(bubble) contains " + reason,
                    hint: "Remove it and send again. A bubble can hold text, emoji, new lines and tabs."
                ))
        }
        let attachments = try files.map(attachment)
        if let wordsPerMinute, !(5...250).contains(wordsPerMinute) {
            throw PlanRefusal.issue(.invalidInput("--wpm must be between 5 and 250.", hint: "Try --wpm 80, the default typing speed."))
        }
        return attachments
    }

    /// The file `path` leads to, once `Attachments` allows it.
    static func attachment(_ path: String) throws -> Attachments.File {
        do {
            return try Attachments.check(path)
        } catch let refusal as Attachments.Refusal {
            throw PlanRefusal.issue(issue(for: refusal, given: path))
        }
    }

    /// Why `Attachments` refused the file given as `given`, and what to do instead.
    static func issue(for refusal: Attachments.Refusal, given: String) -> PlanIssue {
        func shown(_ path: String) -> String {
            let home = NSHomeDirectory()
            return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        }
        let ask = "If the person wants to send it, ask them to save a copy somewhere else, such as Documents, and attach that."
        switch refusal {
        case .unreadable:
            return .invalidInput("Can't read \(given).", hint: "Check the path; --file takes a file on this Mac.")
        case .protectedLocation(let path, let folder):
            return PlanIssue(
                code: "file_not_allowed",
                message: path == folder
                    ? "tincan doesn't attach \(shown(path)), which holds private data."
                    : "tincan doesn't attach files from \(shown(folder)): \(shown(path)).",
                hint: "~/Library holds Messages, call history, Mail, keychains and other apps' private data, and tincan's settings hold your exclusions. "
                    + ask,
                kind: .needsInput
            )
        case .hiddenLocation(let path, let item):
            return PlanIssue(
                code: "file_not_allowed",
                message: path == item
                    ? "tincan doesn't attach hidden files: \(shown(path))."
                    : "tincan doesn't attach files from hidden folders: \(shown(path)) is in \(shown(item)).",
                hint: "Hidden files and folders in your home folder hold keys, passwords, shell history and settings. " + ask,
                kind: .needsInput
            )
        case .systemLocation(let path):
            return PlanIssue(
                code: "file_not_allowed",
                message: "tincan doesn't attach files from outside your home folder: \(shown(path)).",
                hint: "tincan attaches files from your home folder (not ~/Library or hidden folders), /Volumes and temporary folders. " + ask,
                kind: .needsInput
            )
        case .device(let path):
            return PlanIssue(
                code: "file_not_allowed",
                message: "\(shown(path)) is a device, not a file.",
                hint: "--file attaches an ordinary file, such as a photo or a PDF. Check the path.",
                kind: .needsInput
            )
        case .notAFile(let path, let isFolder):
            return PlanIssue(
                code: "file_not_allowed",
                message: isFolder ? "\(shown(path)) is a folder; --file attaches one file." : "\(shown(path)) isn't an ordinary file.",
                hint: "Attach each file with its own --file.",
                kind: .needsInput
            )
        case .symbolicLink(let path):
            return PlanIssue(
                code: "file_not_allowed",
                message: "\(shown(path)) changed into a symbolic link while tincan checked it.",
                hint: "Check the file, then try again with the path of the file itself.",
                kind: .needsInput
            )
        case .hardLinked(let path):
            return PlanIssue(
                code: "file_not_allowed",
                message: "\(shown(path)) has other names on this Mac, so tincan can't tell where it really is.",
                hint: ask,
                kind: .needsInput
            )
        case .tooLarge(let path, let bytes):
            let size = Wording.bytes(bytes)
            let limit = Wording.bytes(Attachments.maximumBytes)
            return PlanIssue(
                code: "file_too_large",
                message: size == limit
                    ? "\(shown(path)) is larger than the \(limit) Messages sends."
                    : "\(shown(path)) is \(size), larger than the \(limit) Messages sends.",
                hint: "Send a smaller version, or share a link to it instead.",
                kind: .needsInput
            )
        }
    }
}
