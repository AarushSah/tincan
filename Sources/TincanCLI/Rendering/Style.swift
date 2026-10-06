import Foundation

/// Semantic colors for human output. Each role degrades from truecolor to 256 colors to the
/// basic 16, and to plain text when styling is off.
struct Style {
    enum Role {
        /// tincan's own accent, used sparingly for headings and prompts.
        case accent
        /// Secondary information: timestamps, ids, hints.
        case muted
        /// iMessage blue, also used for "you".
        case imessage
        /// SMS and RCS green.
        case sms
        /// FaceTime and calls.
        case facetime
        case success
        case warning
        case danger
        /// Reactions and mentions.
        case highlight

        var rgb: (Int, Int, Int) {
            switch self {
            case .accent: return (255, 159, 10)
            case .muted: return (142, 142, 147)
            case .imessage: return (10, 132, 255)
            case .sms: return (48, 209, 88)
            case .facetime: return (100, 210, 255)
            case .success: return (48, 209, 88)
            case .warning: return (255, 214, 10)
            case .danger: return (255, 69, 58)
            case .highlight: return (191, 90, 242)
            }
        }

        var extended: Int {
            switch self {
            case .accent: return 214
            case .muted: return 245
            case .imessage: return 33
            case .sms: return 41
            case .facetime: return 81
            case .success: return 41
            case .warning: return 220
            case .danger: return 203
            case .highlight: return 135
            }
        }

        var basic: Int {
            switch self {
            case .accent: return 33
            case .muted: return 90
            case .imessage: return 34
            case .sms: return 32
            case .facetime: return 36
            case .success: return 32
            case .warning: return 33
            case .danger: return 31
            case .highlight: return 35
            }
        }
    }

    let depth: Terminal.ColorDepth

    var enabled: Bool { depth != .none }

    /// Styles are style markers, not escape sequences: output turns only these into SGR
    /// sequences, after removing every escape sequence from the text. See `TerminalText`.
    func color(_ text: String, _ role: Role) -> String {
        switch depth {
        case .none: return text
        case .basic: return styled(text, "\(role.basic)", "39")
        case .extended: return styled(text, "38;5;\(role.extended)", "39")
        case .truecolor:
            let (r, g, b) = role.rgb
            return styled(text, "38;2;\(r);\(g);\(b)", "39")
        }
    }

    func bold(_ text: String) -> String { styled(text, "1", "22") }
    func dim(_ text: String) -> String { styled(text, "2", "22") }
    func italic(_ text: String) -> String { styled(text, "3", "23") }
    func underline(_ text: String) -> String { styled(text, "4", "24") }
    func strike(_ text: String) -> String { styled(text, "9", "29") }

    private func styled(_ text: String, _ on: String, _ off: String) -> String {
        enabled ? TerminalText.style(on) + text + TerminalText.style(off) : text
    }

    func muted(_ text: String) -> String { color(text, .muted) }
    func accent(_ text: String) -> String { color(text, .accent) }
    func success(_ text: String) -> String { color(text, .success) }
    func warning(_ text: String) -> String { color(text, .warning) }
    func danger(_ text: String) -> String { color(text, .danger) }
}
