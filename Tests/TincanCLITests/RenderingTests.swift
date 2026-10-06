import Foundation
import Testing
import TincanKit

@testable import TincanCLI

/// Human output at 60, 80 and 120 columns, with and without color: nothing wider than the
/// terminal, columns that line up with emoji and CJK names, and calm empty states.
@Suite("Human output")
struct RenderingTests {
    static let commands: [[String]] = [
        [], ["chats"], ["chats", "--all", "--limit", "50"], ["read", "Maya", "--limit", "60"], ["read", "Climbing crew", "--ids"],
        ["read", "chat:9"], ["read", "Ava"], ["read", "Maximilian"], ["who", "Maya"], ["who", "chat:4"], ["who", "+14155550177"],
        ["who", "Maximilian"], ["inbox"], ["inbox", "--since", "3d", "--mine"], ["search", "the"], ["search", "reservation"],
        ["calls"], ["calls", "--missed"], ["contacts"], ["contacts", "show", "Maya"], ["contacts", "show", "Maximilian"],
        ["config"], ["exclude", "list"], ["doctor"], ["who", "Sam"], ["read", "Zed Nobody"],
        ["send", "+14155550142", String(repeating: "a long first bubble that wraps ", count: 4), "second", "--dry-run", "--typing", "paced", "--seed", "3"],
        ["send", "Maya", "hi", "--dry-run"], ["send", "Maya", "hi", "--dry-run", "--service", "rcs"],
        ["contacts", "edit", "Maya", "--add-phone", "work:+14155550199", "--nickname", "Mayo", "--dry-run"],
    ]

    struct Case: CustomTestStringConvertible, Sendable {
        let columns: Int
        let color: String
        var testDescription: String { "\(columns) columns, color \(color)" }
    }

    static let cases = [60, 80, 120].flatMap { columns in ["never", "always"].map { Case(columns: columns, color: $0) } }

    @Test(arguments: RenderingTests.cases)
    func nothingIsWiderThanTheTerminal(_ setting: Case) throws {
        let world = try World()
        try world.run(["exclude", "add", world.chat("lee")])
        for command in Self.commands {
            let result = try world.run(command + ["--color", setting.color], columns: setting.columns)
            #expect(result.status != 1, "tincan \(command.joined(separator: " ")) failed: \(result.stderr)")
            for line in (result.stdout + result.stderr).split(separator: "\n", omittingEmptySubsequences: false) {
                let width = TextWidth.columns(String(line))
                #expect(
                    width <= setting.columns,
                    "tincan \(command.joined(separator: " ")) at \(setting.columns): \(width) columns: \(TextWidth.stripEscapes(String(line)))")
            }
            let styled = result.stdout.contains("\u{1B}[")
            #expect(
                styled == (setting.color == "always" && !result.stdout.isEmpty) || result.stdout.isEmpty,
                "tincan \(command.joined(separator: " ")) color \(setting.color)")
        }
    }

    @Test func colorFollowsNoColorAndForceColor() throws {
        let world = try World()
        #expect(try !world.run(["chats"]).stdout.contains("\u{1B}["))
        #expect(try world.run(["chats"], environment: ["FORCE_COLOR": "1"]).stdout.contains("\u{1B}["))
        #expect(try !world.run(["chats"], environment: ["FORCE_COLOR": "1", "NO_COLOR": "1"]).stdout.contains("\u{1B}["))
        #expect(try world.run(["chats", "--color", "always"], environment: ["NO_COLOR": "1"]).stdout.contains("\u{1B}["))
        // JSON is never styled.
        #expect(try !world.run(["chats", "--json", "--color", "always"]).stdout.contains("\u{1B}["))
    }

    /// The column where `marker` starts on each line that has it.
    func column(of marker: String, in output: String) -> [Int] {
        output.split(separator: "\n").compactMap { line in
            guard let range = line.range(of: marker) else { return nil }
            return TextWidth.columns(String(line[..<range.lowerBound]))
        }
    }

    @Test(arguments: [60, 80, 120])
    func columnsLineUpWithEmojiAndCJKNames(_ columns: Int) throws {
        let world = try World()
        let chats = try world.run(["chats", "--limit", "50"], columns: columns).stdout
        #expect(chats.contains("Ava 🌸 Lin"))
        #expect(chats.contains("健二"))
        #expect(Set(column(of: "chat:", in: chats)).count == 1, "\(chats)")

        let calls = try world.run(["calls"], columns: columns).stdout.split(separator: "\n").filter { $0.hasPrefix("↙") || $0.hasPrefix("↗") }
        #expect(Set(calls.map { TextWidth.columns(String($0)) }).count == 1, "\(calls.joined(separator: "\n"))")

        let people = try world.run(["who", "chat:4"], columns: columns).stdout
        #expect(Set(column(of: "+", in: people)).count == 1, "\(people)")
    }

    @Test func conversationsLookLikeMessages() throws {
        let world = try World()
        let output = try world.run(["read", "Maya", "--limit", "60"], columns: 80).stdout
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Yours on the right edge, theirs on the left.
        let edited = try #require(lines.first { $0.contains("see you at 7:45") })
        #expect(TextWidth.columns(edited) == 80)
        #expect(edited.hasSuffix("(edited)"))
        let theirs = try #require(lines.first { $0.contains("are we still on for dinner?") })
        #expect(theirs.hasPrefix("are we still on"))
        // A long message wraps within the bubble, never past 70% of the width.
        let wrapped = lines.filter { $0.hasPrefix("So here's") || $0.hasPrefix("hold") || $0.hasPrefix("were late") }
        #expect(!wrapped.isEmpty)
        #expect(wrapped.allSatisfy { TextWidth.columns($0) <= 56 })
        // A subject leads its text in one bubble, on the right edge.
        let subject = try #require(lines.first { $0.contains("Dinner plans") })
        #expect(subject.hasSuffix("Dinner plans · Menu for tonight") && TextWidth.columns(subject) == 80, "\(subject)")
        for expected in [
            "↪ Maya: are we still on for dinner?", "You unsent a message", "📎 IMG_0042.jpeg · 2.1 MB", "📎 climb.mov · 48 MB · not downloaded",
            "▦ GamePigeon: 8 Ball", "🎤 Audio message", "(✨ balloons)", "Not delivered", "❤️ Maya", "https://example.com/menu",
        ] {
            #expect(output.contains(expected), "missing \(expected)")
        }
        let group = try world.run(["read", "Climbing crew"], columns: 60).stdout
        #expect(group.contains("You named the conversation “Climbing crew 🧗”"))
        #expect(group.contains("健二 added Ava"))
        #expect(group.contains("😂 Sam"))
        #expect(group.contains("健二  行きます！"))
    }

    @Test func emptyStatesAreCalm() throws {
        let world = try World()
        let cases: [([String], String)] = [
            (["read", "Maya", "--since", "1m"], "No messages in this range."),
            (["search", "zzzz"], "No messages contain “zzzz”."),
            (["calls", "--missed", "--since", "1m"], "No missed calls."),
            (["exclude", "list"], "No conversations are excluded."),
            (["contacts", "find", "zzzz"], "No contacts match “zzzz”."),
            (["inbox", "--since", "1m"], "Nothing new."),
        ]
        for (arguments, expected) in cases {
            let result = try world.run(arguments)
            #expect(result.status == 0)
            #expect(result.stdout.contains(expected), "tincan \(arguments.joined(separator: " ")): \(result.stdout)")
            // What to try next goes to stderr; nothing warns or fails.
            #expect(!result.stderr.contains("! ") && !result.stderr.contains("✗"), "\(result.stderr)")
        }
    }

    @Test func longNamesAreTruncatedNotWrapped() throws {
        let world = try World()
        let chats = try world.run(["chats", "--limit", "50"], columns: 60).stdout
        #expect(chats.contains("Maximilian"))
        #expect(!chats.contains("Sigmaringen"))
    }
}

@Suite("Sender names")
struct SenderNamesTests {
    @Test func sameFirstNamesGetFullNames() {
        let directory = Directory(
            contacts: [
                Contact(id: "sam-park", givenName: "Sam", familyName: "Park", phones: [.init(label: nil, value: "+14155550188", normalized: nil)]),
                Contact(id: "sam-rivera", givenName: "Sam", familyName: "Rivera", phones: [.init(label: nil, value: "+16285550131", normalized: nil)]),
                Contact(
                    id: "maya", givenName: "Maya", familyName: "Chen", phones: [.init(label: nil, value: "+14155550142", normalized: nil)],
                    emails: [.init(label: nil, value: "maya@example.com")]),
            ], region: "US")
        let names = SenderNames(["+14155550188", "+16285550131", "+14155550142", "maya@example.com", "+14155550199"], directory: directory)
        #expect(names.label("+14155550188") == "Sam Park")
        #expect(names.label("+16285550131") == "Sam Rivera")
        // Two addresses of one person are still one Maya.
        #expect(names.label("+14155550142") == "Maya")
        #expect(names.label("maya@example.com") == "Maya")
        #expect(names.label("+14155550199") == "+1 (415) 555-0199")
        #expect(names.label(nil) == "You")
    }
}

@Suite("Text width")
struct TextWidthTests {
    @Test func countsTerminalColumns() {
        #expect(TextWidth.columns("Maya") == 4)
        #expect(TextWidth.columns("健二 佐藤") == 9)
        #expect(TextWidth.columns("🌸") == 2)
        #expect(TextWidth.columns("❤️") == 2)
        #expect(TextWidth.columns("👍🏽") == 2)
        #expect(TextWidth.columns("🇯🇵") == 2)
        #expect(TextWidth.columns("👩‍👩‍👧") == 2)
        #expect(TextWidth.columns("José") == 4)
        #expect(TextWidth.columns("Jose\u{301}") == 4)
        #expect(TextWidth.columns("\u{1B}[31mred\u{1B}[39m") == 3)
        #expect(TextWidth.columns("\u{1B}]8;;https://example.com\u{1B}\\link\u{1B}]8;;\u{1B}\\") == 4)
    }

    @Test func truncatesWrapsAndPadsByColumns() {
        #expect(TextWidth.truncate("健二佐藤", to: 5) == "健二…")
        #expect(TextWidth.truncate("Maya Chen", to: 20) == "Maya Chen")
        #expect(TextWidth.fit("🌸 Ava", to: 8) == "🌸 Ava  ")
        #expect(TextWidth.wrap("one two three", width: 7) == ["one two", "three"])
        #expect(TextWidth.wrap("土曜日の朝9時にジム", width: 8) == ["土曜日の", "朝9時に", "ジム"])
        #expect(TextWidth.wrap("line\n\nbreaks", width: 20) == ["line", "", "breaks"])
        let path = TextWidth.truncateMiddle("~/Library/Application Support/tincan/config.toml", to: 30)
        #expect(TextWidth.columns(path) <= 30)
        #expect(path.hasSuffix("config.toml"))
        #expect(path.hasPrefix("~/"))
    }

    @Test func layoutKeepsHeadersInsideTheWidth() {
        let style = Style(depth: .none)
        let header = Layout.header(
            "Maximilian Alexander von Hohenzollern-Sigmaringen", details: ["iMessage", "+1 (415) 555-0155"], trailing: "chat:11", width: 40, style: style)
        #expect(TextWidth.columns(header) == 40)
        #expect(header.hasSuffix("chat:11"))
        let parts = Layout.parts([("Missed", style.muted), ("Phone", style.muted), ("not returned", style.muted)], width: 16, style: style)
        #expect(parts == "Missed · Phone")
    }
}
