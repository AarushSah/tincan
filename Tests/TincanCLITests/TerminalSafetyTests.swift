import Foundation
import Testing

@testable import TincanCLI

/// Text other people wrote (messages, names, group names, attachment names, call apps)
/// reaches the terminal without escape sequences or controls that act on it.
@Suite("Terminal safety")
struct TerminalSafetyTests {
    static let clearScreen = "\u{1B}[2J\u{1B}[H"
    static let clipboard = "\u{1B}]52;c;ZWNobyBwd25lZA==\u{07}"
    static let fakeLink = "\u{1B}]8;;https://evil.example/\u{07}click me\u{1B}]8;;\u{07}"
    static let overwrite = "\r\u{1B}[2Ktincan: all clear"
    static let reversed = "\u{202E}gnp.exe"
    static let hidden = "\u{1B}[8m"
    static let red = "\u{1B}[31m"
    /// Style markers someone wrote: the marker character alone, and with a nonce that is
    /// not this run's.
    static let forged = "\u{E01B}[8m" + "\u{E01B}" + String(repeating: "0", count: 16) + "[8m"
    static let hostile = "hi " + fakeLink + " " + clipboard + overwrite + " " + reversed + " \u{1B}c\u{9B}2J\u{1B}P1$r\u{1B}\\\u{1B}[31mred\u{1B}[0m\tend"

    // MARK: Sanitizing

    @Test func controlsAndEscapesAreRemoved() {
        let plain = TerminalText.sanitize(Self.hostile, keepStyles: false)
        #expect(plain == "hi click me tincan: all clear gnp.exe 2Jred    end")
        // Colors in the text are escape sequences like any other: they never reach the terminal.
        #expect(TerminalText.sanitize(Self.hostile, keepStyles: true) == plain)
        // Only newlines survive among controls.
        #expect(TerminalText.sanitize("a\u{1B}[8m\nb\u{0}\u{7F}\u{85}\u{2066}c\u{2069}", keepStyles: true) == "a\nbc")
        // A sequence that never ends only loses its ESC; nothing after it disappears.
        #expect(TerminalText.sanitize("before \u{1B}]52;c;abc after", keepStyles: true) == "before ]52;c;abc after")
        #expect(TerminalText.sanitize("\u{1B}[1 qcursor \u{1B}(Bset \u{1B}[?25lhidden", keepStyles: true) == "cursor set hidden")
        #expect(TerminalText.sanitize("Maya Chen 🌸 健二", keepStyles: true) == "Maya Chen 🌸 健二")
        // Line and paragraph separators can't break a line where the layout doesn't expect it.
        #expect(TerminalText.sanitize("one\u{2028}two\u{2029}three", keepStyles: true) == "one two three")
        #expect(TextWidth.wrap("one\u{2028}two\u{2029}three", width: 20) == ["one", "two", "three"])
        #expect(TextWidth.columns("a\u{2028}b") == TextWidth.columns(TerminalText.sanitize("a\u{2028}b", keepStyles: true)))
    }

    @Test func onlyTincansOwnStylesBecomeEscapes() {
        let style = Style(depth: .basic)
        // tincan's styles are markers until output turns them into SGR, and each styled line
        // ends with a reset.
        #expect(!style.danger("x").unicodeScalars.contains("\u{1B}"))
        #expect(TerminalText.sanitize(style.danger("x") + " " + style.bold("y"), keepStyles: true) == "\u{1B}[31mx\u{1B}[39m \u{1B}[1my\u{1B}[22m\u{1B}[0m")
        #expect(TerminalText.sanitize(style.danger("x"), keepStyles: false) == "x")
        #expect(Style(depth: .none).danger("x") == "x")
        // Markers someone else wrote are dropped, and so is a marker with any other nonce.
        let other = String(TerminalText.nonce.map { Character(String((Int(String($0))! + 1) % 10)) })
        let forged = Self.forged + "\u{E01B}\(other)[31mred" + "\u{E01B}" + TerminalText.nonce + "[8"
        #expect(TerminalText.sanitize(forged, keepStyles: true) == "[8m0000000000000000[8m\(other)[31mred" + TerminalText.nonce + "[8")
        // Their characters around tincan's own markers change nothing.
        let name = "\u{E01B}Eve" + Self.hidden + "\u{E01B}"
        #expect(TerminalText.sanitize(style.bold(name) + "\u{E01B}", keepStyles: true) == "\u{1B}[1mEve\u{1B}[22m\u{1B}[0m")
    }

    @Test func widthsMatchWhatIsPrinted() {
        let style = Style(depth: .truecolor)
        let texts = [
            Self.hostile, Self.clearScreen + "Crew" + Self.reversed, "tab\there", "\u{1B}]8;;x", Self.forged,
            style.danger("Maya") + " " + style.muted(Self.forged + "Chen"), style.bold("a\u{E01B}b"),
        ]
        for text in texts {
            let printed = TerminalText.sanitize(text, keepStyles: true)
            #expect(TextWidth.columns(text) == TextWidth.columns(printed), "\(text.debugDescription)")
        }
        #expect(TextWidth.stripEscapes(style.danger("Maya") + " " + Self.forged) == "Maya [8m0000000000000000[8m")
        #expect(TextWidth.columns(style.accent("健二")) == 4)
        #expect(TextWidth.columns("\t") == TerminalText.tabWidth)
        #expect(TextWidth.columns("\u{202E}\u{2067}") == 0)
    }

    @Test func truncationNeverCutsAnEscapeSequence() {
        #expect(TextWidth.truncate("\u{1B}[31mabcdef\u{1B}[39m", to: 4) == "\u{1B}[31mabc…\u{1B}[39m")
        #expect(TextWidth.truncate("ab\u{1B}]8;;https://evil.example/\u{07}cdef", to: 4) == "ab\u{1B}]8;;https://evil.example/\u{07}c…")
        #expect(TextWidth.truncate("ab\u{1B}]52;c;ZWNobyBwd25lZA==\u{07}cdef", to: 3) == "ab\u{1B}]52;c;ZWNobyBwd25lZA==\u{07}…")
        let middle = TextWidth.truncateMiddle("\u{1B}[1m~/Library/Application Support/tincan/config.toml\u{1B}[22m", to: 30)
        #expect(TextWidth.columns(middle) <= 30)
        #expect(middle.hasPrefix("\u{1B}[1m~/"))
        #expect(middle.hasSuffix("config.toml\u{1B}[22m"))
        let wrapped = TextWidth.wrap("\u{1B}[31m" + String(repeating: "x", count: 30) + "\u{1B}[39m", width: 10)
        #expect(wrapped == ["\u{1B}[31mxxxxxxxxxx", "xxxxxxxxxx", "xxxxxxxxxx\u{1B}[39m"])
    }

    @Test func truncationAndWrappingKeepMarkersWhole() {
        let style = Style(depth: .truecolor)
        let on = TerminalText.style("38;2;255;69;58")
        let off = TerminalText.style("39")
        #expect(TextWidth.truncate(style.danger("abcdef"), to: 4) == on + "abc…" + off)
        #expect(TextWidth.fit(style.danger("ab"), to: 4) == on + "ab" + off + "  ")
        let middle = TextWidth.truncateMiddle(style.bold("~/Library/Application Support/tincan/config.toml"), to: 30)
        #expect(TextWidth.columns(middle) <= 30)
        #expect(middle.hasPrefix(TerminalText.style("1") + "~/"))
        #expect(middle.hasSuffix("config.toml" + TerminalText.style("22")))
        let wrapped = TextWidth.wrap(style.danger(String(repeating: "x", count: 30)), width: 10)
        #expect(wrapped == [on + "xxxxxxxxxx", "xxxxxxxxxx", "xxxxxxxxxx" + off])
        #expect(TextWidth.wrap(style.muted("one two") + " " + style.bold("three"), width: 8) == [style.muted("one two"), style.bold("three")])
    }

    @Test func aVeryLongWordWrapsQuickly() {
        let word = String(repeating: "a", count: 200_000)
        let started = Date()
        let lines = TextWidth.wrap(word, width: 80)
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 1, "wrapping took \(elapsed)s")
        #expect(lines.count == 2_500)
        #expect(lines.allSatisfy { $0.count == 80 })
        let mixed = String(repeating: "健二🌸e\u{301}", count: 50_000)
        let start = Date()
        #expect(TextWidth.wrap(mixed, width: 57).allSatisfy { TextWidth.columns($0) <= 57 })
        #expect(Date().timeIntervalSince(start) < 1)
    }

    // MARK: Commands

    /// Messages, contacts and calls where other people chose every name and text.
    final class HostileWorld {
        let world: World
        let environment: [String: String]
        let direct: Int64
        let group: Int64
        /// A conversation on an email address someone chose.
        let mail: Int64

        /// An address with styling in it.
        static let address = "eve" + TerminalSafetyTests.hidden + "@example.com"

        init() throws {
            let messages = try MessagesFixture()
            let eve = try messages.addHandle("+14155550150")
            let other = try messages.addHandle("+14155550151")
            let styled = try messages.addHandle(Self.address)
            direct = try messages.addChat("iMessage;-;+14155550150", participants: [eve])
            group = try messages.addChat(
                "iMessage;+;chat100000009",
                displayName: "Crew" + TerminalSafetyTests.clearScreen + TerminalSafetyTests.reversed + TerminalSafetyTests.hidden + TerminalSafetyTests.forged,
                participants: [eve, other]
            )
            mail = try messages.addChat("iMessage;-;\(Self.address)", participants: [styled])
            let first = try messages.addMessage(TerminalSafetyTests.hostile, in: direct, from: .handle(eve), at: World.ago(hours: 2))
            try messages.addReaction(.love, to: first, in: direct, from: .meTo(eve), at: World.ago(hours: 2).addingTimeInterval(60))
            let photo = try messages.addMessage("\u{FFFC}", in: direct, from: .handle(eve), at: World.ago(hours: 1))
            try messages.addAttachment(
                to: photo,
                name: "pic\u{1B}]8;;file:///etc/passwd\u{07}.jpeg" + TerminalSafetyTests.reversed + TerminalSafetyTests.red + TerminalSafetyTests.forged,
                mimeType: "image/jpeg", bytes: 2_000
            )
            try messages.addMessage(TerminalSafetyTests.overwrite + TerminalSafetyTests.clipboard, in: group, from: .handle(other), at: World.ago(minutes: 30))
            try messages.addMessage("\u{1B}[8mhidden from here on", in: group, from: .handle(eve), at: World.ago(minutes: 20)) { $0.isRead = false }
            try messages.addMessage(
                "styled " + TerminalSafetyTests.red + "red" + TerminalSafetyTests.forged + " clear", in: mail, from: .handle(styled), at: World.ago(minutes: 10)
            ) { $0.isRead = false }

            let calls = try CallHistoryFixture()
            try calls.addCall(address: "+14155550150", at: World.ago(hours: 3))
            try calls.addCall(
                address: "+14155550151", at: World.ago(hours: 1), answered: true, duration: 30,
                provider: "net.example.Chat" + TerminalSafetyTests.clearScreen + TerminalSafetyTests.clipboard + TerminalSafetyTests.hidden)
            try calls.addCall(address: Self.address, at: World.ago(minutes: 50), type: .faceTimeAudio)

            // Two cards share +14155550151, so warnings and candidates name both.
            let people: [[String: Any]] = [
                [
                    "id": "eve", "given_name": "Eve" + TerminalSafetyTests.clearScreen + TerminalSafetyTests.red,
                    "family_name": "Mallory" + TerminalSafetyTests.fakeLink + TerminalSafetyTests.reversed + TerminalSafetyTests.forged,
                    "phones": ["+14155550150", "+14155550151"],
                ],
                [
                    "id": "eve-too", "given_name": "Eve" + TerminalSafetyTests.hidden, "family_name": "Mallory" + TerminalSafetyTests.clipboard,
                    "organization": "Crew" + TerminalSafetyTests.red, "phones": ["+14155550151"], "emails": [Self.address],
                ],
            ]
            let contacts = String(decoding: try JSONSerialization.data(withJSONObject: people), as: UTF8.self)
            world = try World(contacts: contacts)
            environment = ["TINCAN_MESSAGES_DB": messages.path, "TINCAN_CALL_HISTORY_DB": calls.database.path]
        }

        /// Runs tincan here. With color, in truecolor, so tincan's own colors can't be
        /// mistaken for the basic colors in the text.
        func run(_ arguments: [String], columns: Int = 100) throws -> CLIResult {
            try world.run(arguments, columns: columns, environment: environment.merging(["COLORTERM": "truecolor"]) { $1 })
        }
    }

    /// The SGR parameters tincan itself writes in truecolor.
    static let ownStyles: Set<String> = {
        let roles: [Style.Role] = [.accent, .muted, .imessage, .sms, .facetime, .success, .warning, .danger, .highlight]
        return Set(["0", "1", "22", "2", "3", "23", "4", "24", "9", "29", "39"] + roles.map { "38;2;\($0.rgb.0);\($0.rgb.1);\($0.rgb.2)" })
    }()

    /// Fails unless every escape in `output` is one of tincan's own truecolor styles (none
    /// without color), and no other control, reordering or marker character is left. Lines
    /// stay within `columns`.
    func expectSafe(_ output: String, color: Bool, columns: Int, _ context: String) {
        #expect(color || !output.contains("\u{1B}"), "\(context): styled without color")
        let sgr = try! Regex("\u{1B}\\[([0-9;:]*)m", as: (Substring, Substring).self)
        let foreign = Set(output.matches(of: sgr).map { String($0.output.1) }).subtracting(Self.ownStyles)
        #expect(foreign.isEmpty, "\(context): styles tincan doesn't use: \(foreign.sorted())")
        let withoutStyles = output.replacing(sgr, with: "")
        #expect(!withoutStyles.unicodeScalars.contains("\u{1B}"), "\(context): \(output.debugDescription)")
        let forbidden = withoutStyles.unicodeScalars.filter { TerminalText.isRemoved($0) || $0 == "\t" || $0 == TerminalText.marker }
        #expect(forbidden.isEmpty, "\(context): \(forbidden.map { String(format: "U+%04X", $0.value) })")
        for line in output.split(separator: "\n") {
            #expect(TextWidth.columns(String(line)) <= columns, "\(context): \(line.debugDescription)")
        }
    }

    @Test(arguments: ["never", "always"])
    func hostileTextIsHarmlessInEveryCommand(color: String) throws {
        let hostile = try HostileWorld()
        let direct = "chat:\(hostile.direct)"
        let group = "chat:\(hostile.group)"
        let mail = "chat:\(hostile.mail)"
        let commands: [[String]] = [
            [], ["chats"], ["read", direct], ["read", group], ["read", mail], ["read", "contact:eve"], ["who", "contact:eve"], ["who", group],
            ["who", mail], ["who", "+14155550151"], ["calls"], ["calls", "--missed"], ["calls", mail], ["inbox"], ["search", "clear"],
            ["send", group, "hi", "--dry-run", "--typing", "paced"], ["contacts", "show", "contact:eve"], ["contacts", "show", "contact:eve-too"],
            ["contacts", "find", "Eve"], ["contacts", "duplicates"],
        ]
        for command in commands {
            let result = try hostile.run(command + ["--color", color], columns: 80)
            #expect(result.status == 0, "tincan \(command.joined(separator: " ")): \(result.stderr)")
            expectSafe(result.stdout + result.stderr, color: color == "always", columns: 80, "tincan \(command.joined(separator: " ")) --color \(color)")
        }
        // Errors name candidates other people named.
        let ambiguous = try hostile.run(["read", "Eve", "--color", color], columns: 80)
        #expect(ambiguous.status == 3)
        #expect(ambiguous.stderr.contains("contact:eve-too"))
        expectSafe(ambiguous.stdout + ambiguous.stderr, color: color == "always", columns: 80, "tincan read Eve --color \(color)")

        let read = try hostile.run(["read", direct, "--color", color]).stdout
        #expect(read.contains("click me"))
        #expect(read.contains("tincan: all clear"))
        #expect(read.contains("gnp.exe"))
        #expect(read.contains("📎 pic"))
        let styled = try hostile.run(["read", mail, "--color", color]).stdout
        #expect(styled.contains("[8m0000000000000000[8m clear"))
        // tincan's own styles still show, in color only.
        #expect(styled.contains("\u{1B}[38;2;") == (color == "always"))
    }

    @Test func questionsNamingPeopleAreSafe() throws {
        let hostile = try HostileWorld()
        let environment = hostile.world.environment.merging(["COLUMNS": "100", "COLORTERM": "truecolor"]) { $1 }
        let result = try CLI.runInTerminal(["contacts", "edit", "contact:eve", "--nickname", "E", "--color", "always"], environment: environment, answer: "n")
        let printed = result.stdout.replacingOccurrences(of: "\r\n", with: "\n")
        #expect(printed.contains("[y/N]"))
        #expect(printed.contains("Nothing was changed."))
        expectSafe(printed, color: true, columns: 100, "tincan contacts edit")
    }

    @Test(arguments: ["never", "always"])
    func watchPrintsHostileTextHarmlessly(color: String) throws {
        let hostile = try HostileWorld()
        let environment = hostile.world.environment.merging(hostile.environment) { $1 }.merging(["COLUMNS": "80", "COLORTERM": "truecolor"]) { $1 }
        let running = try CLI.start(["watch", "--after", "0", "--interval", "0.2", "--color", color], environment: environment)
        var last = ""
        var stableSince = Date()
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            usleep(100_000)
            let output = running.output
            if output != last {
                last = output
                stableSince = Date()
            } else if !output.isEmpty, Date().timeIntervalSince(stableSince) > 1.0 {
                break
            }
        }
        let result = running.stop()
        #expect(result.stdout.contains("click me"))
        #expect(result.stdout.contains("styled red"))
        expectSafe(result.stdout + result.stderr, color: color == "always", columns: 80, "tincan watch --color \(color)")
    }

    @Test func jsonKeepsTheExactText() throws {
        let hostile = try HostileWorld()
        let messages = try hostile.world.run(["read", "chat:\(hostile.direct)", "--json"], environment: hostile.environment).json["data"] as? [String: Any]
        let texts = ((messages?["messages"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }
        #expect(texts.contains(Self.hostile))
        let chats = try hostile.world.run(["chats", "--json"], environment: hostile.environment).json["data"] as? [[String: Any]] ?? []
        #expect(chats.contains { $0["name"] as? String == "Crew" + Self.clearScreen + Self.reversed + Self.hidden + Self.forged })
    }
}
