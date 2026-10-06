import Foundation
import Testing
import TincanKit

@testable import TincanCLI

/// Small things a person notices at a terminal: commands in hints that stay whole, counts
/// that agree with their nouns, and next steps written as commands rather than jargon.
@Suite("Terminal polish")
struct PolishTests {
    let world: World

    init() throws { world = try World() }

    @Test func hintsNeverSplitACommandAcrossLines() throws {
        for command in [["read", "Sam"], ["send", "Sam", "hi", "--dry-run"], ["contacts", "show", "Sam"]] {
            let result = try world.run(command, columns: 80)
            #expect(result.status == 3)
            let hint = result.stderr.split(separator: "\n").drop { !$0.contains("→") }.joined(separator: "\n")
            let expected = "`tincan \(command.prefix(command[0] == "contacts" ? 2 : 1).joined(separator: " ")) <reference>"
            #expect(hint.split(separator: "\n").contains { $0.contains(expected) }, "tincan \(command.joined(separator: " ")): \(hint)")
        }
        let example = try world.run(["contacts", "add", "--dry-run"], columns: 80).stderr
        #expect(example.contains("`tincan contacts add --name \"Maya Chen\" --phone +14155550142`."), "\(example)")
        #expect(try world.run(["send", "chat:3", "--dry-run"]).stderr.contains("`tincan send chat:3 \"hello\"`."))
        // A command too long for any line still wraps rather than overflowing.
        #expect(TextWidth.wrapKeepingCode("Run `tincan read Maya --before m:31 --limit 4` now", width: 20).allSatisfy { TextWidth.columns($0) <= 20 })
        #expect(TextWidth.wrapKeepingCode("then `tincan read <reference>`.", width: 28) == ["then", "`tincan read <reference>`."])
    }

    @Test func aGroupWithOneMessageSaysMessage() throws {
        let result = try world.run(["who", world.chat("trip")], columns: 80)
        #expect(result.stdout.contains("· 1 message\n"), "\(result.stdout)")
    }

    @Test func earlierCallsKeepThePageSize() throws {
        let result = try world.run(["calls", "--missed", "--limit", "2"], columns: 100)
        let earlier = result.stderr.split(separator: "\n").last.map(String.init) ?? ""
        #expect(earlier.hasPrefix("Earlier: tincan calls --missed --before "))
        #expect(earlier.hasSuffix(" --limit 2"))
        // The default page size isn't repeated.
        let calls = try world.run(["calls"], columns: 100)
        #expect(calls.stderr.hasPrefix("Earlier: tincan calls --before "))
        #expect(!calls.stderr.contains("--limit"))
    }

    @Test func inboxEndsWithTheCommandForWhatComesLater() throws {
        let unread = try world.run(["inbox"], columns: 80)
        #expect(!unread.stdout.contains("Cursor"))
        #expect(!unread.stdout.contains("Later:") && !unread.stdout.hasSuffix("\n\n"))
        #expect(unread.stderr.hasPrefix("\nLater: tincan inbox --after m:"), "\(unread.stderr)")
        let cursor = try world.json(["inbox"]).dataObject["cursor"] as? String ?? ""
        let nothing = try world.run(["inbox", "--after", cursor], columns: 80)
        #expect(nothing.stdout == "Nothing new.\n")
        #expect(nothing.stderr == "Later: tincan inbox --after \(cursor)\n")
        let more = try world.run(["inbox", "--since", "1w", "--limit", "2", "--mine"], columns: 80).stderr
        #expect(more.split(separator: "\n").last?.hasPrefix("More waiting: tincan inbox --after m:") == true, "\(more)")
        #expect(more.contains("--limit 2 --mine"))
    }

    @Test func homeDropsWholeCommandsWhenNarrow() throws {
        let result = try world.run([], columns: 50)
        let lines = result.stdout.split(separator: "\n").map(String.init)
        #expect(result.stderr == "\ntincan read <name> · tincan send <name> \"…\"\n")
        #expect(lines.contains("Missed calls"))
        #expect(lines.contains { $0.hasPrefix("  ● +1 (415) 555-0199  ") }, "\(lines)")
        #expect(lines.allSatisfy { TextWidth.columns($0) <= 50 })
    }

    @Test func doctorShortensLongPathsInsteadOfSplittingThem() throws {
        let result = try world.run(["doctor"], columns: 80)
        let lines = result.stdout.split(separator: "\n").map(String.init)
        for variable in ["TINCAN_MESSAGES_DB=", "TINCAN_CALL_HISTORY_DB=", "TINCAN_CONTACTS_FILE="] {
            let line = lines.first { $0.contains(variable) }
            #expect(line != nil, "\(variable) in \(result.stdout)")
        }
        #expect(lines.contains { $0.contains("CallHistory.storedata") })
        #expect(lines.first?.hasSuffix("tincan") == true, "\(lines.first ?? "")")
        // The verdict is the result; what to run next goes to stderr.
        #expect(lines.last == "Ready." || lines.last == "Needs attention.", "\(lines.last ?? "")")
        #expect(result.stderr == (lines.last == "Ready." ? "Try `tincan chats`.\n" : "Run `tincan doctor --fix`.\n"))
    }

    @Test func anUnknownCommandSuggestsTheOneMeant() throws {
        let typo = try world.run(["contact", "show", "Maya"], columns: 80)
        #expect(typo.status == 64)
        #expect(
            typo.stderr
                == "? \"contact\" isn't a tincan command. Did you mean contacts?\n  → Run `tincan contacts show Maya`, or `tincan --help` for every command.\n")
        #expect(try world.run(["sned", "Maya", "hi"]).stderr.contains("Did you mean send?"))
        #expect(try world.run(["con"]).stderr.contains("Did you mean contacts or config?"))
        // A name on its own is probably someone to read.
        let name = try world.run(["Maya"], columns: 100)
        #expect(name.stderr.contains("run `tincan read Maya`"))
        #expect(!name.stderr.contains("Usage:"))
        // JSON keeps its error.
        let json = try world.run(["chat", "--json"])
        #expect(try (json.json["error"] as? [String: Any])?["code"] as? String == "invalid_arguments")
        // Mistakes after a command still get ArgumentParser's own message.
        #expect(try world.run(["read", "Maya", "--limt", "3"]).stderr.contains("Did you mean '--limit'?"))
    }

    @Test func aConversationTitledByItsNumberDoesNotRepeatIt() throws {
        let header = try world.run(["read", world.chat("lee")], columns: 80).stdout.split(separator: "\n").first.map(String.init) ?? ""
        #expect(header.components(separatedBy: "+1 (415) 555-0177").count == 2, "\(header)")
        #expect(header.contains("shared by Jordan Lee and Riley Lee"), "\(header)")
    }

    @Test func duplicateCardsSitNextToTheirReferences() throws {
        let lines = try world.run(["contacts", "duplicates"], columns: 80).stdout.split(separator: "\n").map(String.init)
        // Names are padded to the longest, not to a fixed column.
        #expect(lines.contains { $0.hasPrefix("    Jordan Lee  ") && $0.hasSuffix("  contact:jordan-lee") }, "\(lines)")
        #expect(lines.contains { $0.hasPrefix("    Riley Lee   ") && $0.hasSuffix("  contact:riley-lee") }, "\(lines)")
    }

    @Test func emptyResultsSayWhatToTryNext() throws {
        let empty = try world.run(["read", "Maya", "--since", "1m"])
        #expect(empty.stdout.hasSuffix("No messages in this range.\n"))
        #expect(empty.stderr.hasPrefix("Earlier: tincan read Maya --before "))
        #expect(try world.run(["read", "Maya", "--before", "m:1"]).stdout.hasSuffix("No messages in this range.\n"))
        let zed = try world.run(["contacts", "find", "Zed"])
        #expect(zed.stdout == "No contacts match “Zed”.\n")
        #expect(zed.stderr == "Try part of a name, a number or an email. `tincan contacts` lists everyone.\n")
        let search = try world.run(["search", "zzzz"])
        #expect(search.stdout == "No messages contain “zzzz”.\n")
        #expect(search.stderr == "Try fewer words, or --all to include Unknown Senders and Junk.\n")
        #expect(try world.run(["search", "zzzz", "--in", "Maya", "--since", "1w"]).stderr.hasSuffix("Try fewer words, or search without --in or --since.\n"))
    }

    @Test func aGroupPreviewKeepsEachNumberOnOneLine() throws {
        let preview = try world.run(["send", world.chat("crew"), "I'm in", "--dry-run"], columns: 80).stdout
        #expect(preview.contains("+81 90 1234 5678"), "\(preview)")
        #expect(!preview.contains("\u{00A0}"))
    }

    @Test func aWrappedCommandKeepsEachOptionWithItsValue() throws {
        let read = try world.run(["read", world.chat("crew"), "--limit", "6"], columns: 50).stderr
        #expect(read.split(separator: "\n").contains { $0.hasPrefix("Earlier: tincan read chat:") && !$0.hasSuffix("--limit") })
        #expect(read.split(separator: "\n").contains { $0.contains("--limit 6") }, "\(read)")
        let calls = try world.run(["calls", "--limit", "2"], columns: 50).stderr
        #expect(calls.split(separator: "\n").contains { $0.hasPrefix("--before 20") && $0.hasSuffix("--limit 2") }, "\(calls)")
    }

    @Test func liftingAnExclusionNamesTheConversation() throws {
        try world.run(["exclude", "add", "Ava"])
        let lifted = try world.run(["exclude", "remove", "Ava", "--yes"], columns: 80)
        #expect(lifted.status == 0)
        #expect(lifted.stdout.hasPrefix("✓ No longer excluded: Ava 🌸 Lin (chat:"), "\(lifted.stdout)")
        #expect(lifted.stdout.replacingOccurrences(of: "\n  ", with: " ").contains("one-to-one conversations at +1 (415) 555-0166."), "\(lifted.stdout)")
        #expect(lifted.stdout.contains("+1 (415) 555-0166"))
        #expect(lifted.stdout.split(separator: "\n").allSatisfy { TextWidth.columns(String($0)) <= 80 })
        // Adding and listing wrap too, with each number whole.
        let added = try world.run(["exclude", "add", "Maya"], columns: 60).stdout + (try world.run(["exclude", "list"], columns: 60).stdout)
        #expect(added.split(separator: "\n").allSatisfy { TextWidth.columns(String($0)) <= 60 }, "\(added)")
        #expect(added.contains("+1 (415) 555-0142") && !added.contains("\u{00A0}"))
    }

    @Test func watchWrapsItsWarnings() throws {
        let running = try CLI.start(["watch", "--after", "m:999999", "--interval", "0.2"], environment: world.environment.merging(["COLUMNS": "60"]) { $1 })
        usleep(1_500_000)
        let result = running.stop()
        let lines = result.stderr.split(separator: "\n").map(String.init)
        #expect(lines.first?.hasPrefix("! m:999999 is newer than any message") == true, "\(result.stderr)")
        #expect(lines.allSatisfy { TextWidth.columns($0) <= 60 }, "\(result.stderr)")
    }

    @Test func catchingUpInWatchShowsEachDay() throws {
        let running = try CLI.start(["watch", "--after", "0", "--interval", "0.2"], environment: world.environment.merging(["COLUMNS": "50"]) { $1 })
        usleep(1_500_000)
        let lines = running.stop().stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.contains("Yesterday"), "\(lines)")
        #expect(lines.contains("Today"), "\(lines)")
        #expect(lines.allSatisfy { TextWidth.columns($0) <= 50 && !$0.hasSuffix(" ") }, "\(lines)")
        // A group event is filed under the group, not repeated after its actor.
        #expect(lines.contains { $0.contains("  Climbing crew 🧗 › 健二 added Ava") }, "\(lines)")
        #expect(!lines.contains { $0.contains("健二 in Climbing crew 🧗 › 健二 added") })
        // A long name leaves the text a line of its own rather than a sliver.
        #expect(lines.contains { $0.hasSuffix("in Climbing crew 🧗 ›") }, "\(lines)")
    }

    @Test func wideTerminalsShowMoreOfLongNames() throws {
        let wide = try world.run(["chats"], columns: 140).stdout
        #expect(wide.contains("Maximilian Alexander von Hohenzoll"), "\(wide)")
        #expect(wide.split(separator: "\n").allSatisfy { TextWidth.columns(String($0)) <= 120 })
        #expect(try world.run(["chats"], columns: 60).stdout.contains("+1 (415) 555-0199"))
        let narrow = try world.run(["chats"], columns: 80).stdout
        #expect(narrow.contains("Maximilian Alexander …"), "\(narrow)")
    }

    @Test func closingPunctuationNeverStartsALine() throws {
        let lines = TextWidth.wrap("駐車場は混むので早めに来てください。", width: 34)
        #expect(lines == ["駐車場は混むので早めに来てくださ", "い。"])
        #expect(lines.allSatisfy { TextWidth.columns($0) <= 34 })
        let read = try world.run(["read", world.chat("crew")], columns: 50).stdout
        #expect(!read.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("。") }, "\(read)")
    }

    @Test func whoKeepsNumbersWholeWhenNarrow() throws {
        let who = try world.run(["who", "Maya"], columns: 50).stdout
        #expect(who.contains("+1 (415) 555-0142  SMS"), "\(who)")
        #expect(who.split(separator: "\n").allSatisfy { TextWidth.columns(String($0)) <= 50 })
    }

    @Test func veryNarrowTerminalsStillFit() throws {
        for (command, columns) in [([String](), 40), (["calls"], 40), (["chats"], 40), (["chats"], 30), (["who", "Maya"], 44), (["inbox"], 44)] {
            let result = try world.run(command, columns: columns)
            for line in (result.stdout + result.stderr).split(separator: "\n") {
                #expect(TextWidth.columns(String(line)) <= columns, "tincan \(command.joined(separator: " ")) at \(columns): \(line)")
            }
        }
    }

    @Test func narrowChatsDropTheTimeBeforeCuttingNamesShort() throws {
        let lines = try world.run(["chats"], columns: 40).stdout.split(separator: "\n").map(String.init)
        #expect(lines.allSatisfy { TextWidth.columns($0) <= 40 }, "\(lines)")
        // Names, snippets and references stay; the list is newest first without the times.
        #expect(lines.contains { $0.hasPrefix("● Sam Rivera       secret") && $0.hasSuffix("  chat:5") }, "\(lines)")
        #expect(!lines.contains { $0.contains("yesterday") }, "\(lines)")
        #expect(try world.run(["chats"], columns: 44).stdout.contains("yesterday"))
    }

    @Test func deliveryStatusShowsOnlyUnderYourLatestMessage() throws {
        // A page of Maya's older messages ends with one of yours, but you sent more after it.
        let older = try world.run(["read", world.chat("maya"), "--after", "m:\(world.rows.mayaFirst.rowID)", "--limit", "1"], columns: 60).stdout
        #expect(older.contains("yes! 7:30 at the usual place"), "\(older)")
        #expect(!older.contains("Delivered"), "\(older)")
        let around = try world.run(["read", world.chat("maya"), "--around", "m:\(world.rows.mayaYes.rowID)", "--limit", "3"], columns: 60).stdout
        #expect(!around.contains("Delivered"), "\(around)")
        // Your latest message keeps it on a page with later messages from them.
        let newest = try world.json(["read", "Maya", "--limit", "1"]).dataObject["messages"] as? [[String: Any]]
        let photos = try #require(newest?.first?["ref"] as? String)
        let latest = try world.run(["read", "Maya", "--before", photos, "--limit", "2"], columns: 60).stdout
        let lines = latest.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(lines.firstIndex(of: "Delivered") == lines.firstIndex(of: "no worries").map { $0 + 1 }, "\(latest)")
    }

    @Test func aSubjectAndItsTextAreOneBubble() throws {
        let messages = try MessagesFixture()
        let maya = try messages.addHandle("+14155550142")
        let chat = try messages.addChat("iMessage;-;+14155550142", participants: [maya])
        try messages.addMessage("Menu for tonight, and the wine list", in: chat, from: .handle(maya), at: Date().addingTimeInterval(-120)) {
            $0.subject = "Dinner plans"
        }
        try messages.addMessage("Looks great", in: chat, from: .meTo(maya), at: Date().addingTimeInterval(-60)) { $0.subject = "Re: dinner" }
        let environment = try World.environment(messages).merging(["COLUMNS": "40"]) { $1 }
        let lines = try CLI.run(["read", "chat:\(chat)"], environment: environment).stdout.split(separator: "\n").map(String.init)
        // Theirs: the subject leads the first line and the text wraps under it, on the left.
        let theirs = try #require(lines.firstIndex { $0.hasPrefix("Dinner plans · Menu for") }, "\(lines)")
        #expect(lines[theirs + 1].hasPrefix("tonight, and"), "\(lines)")
        // Yours: one line on the right edge.
        #expect(lines.contains { $0.hasSuffix("Re: dinner · Looks great") && TextWidth.columns($0) == 40 }, "\(lines)")
        #expect(!lines.contains { $0.trimmingCharacters(in: .whitespaces) == "Dinner plans" })
    }

    /// The send ledger tells the messages tincan sent from the ones you typed.
    @Test func messagesTincanSentAreMarked() throws {
        let messages = try MessagesFixture()
        let maya = try messages.addHandle("+14155550142")
        let chat = try messages.addChat("iMessage;-;+14155550142", participants: [maya])
        let first = try messages.addMessage("on my way", in: chat, from: .meTo(maya), at: Date().addingTimeInterval(-300))
        let second = try messages.addMessage("ten minutes", in: chat, from: .meTo(maya), at: Date().addingTimeInterval(-290))
        let typed = try messages.addMessage("typed this one myself", in: chat, from: .meTo(maya), at: Date().addingTimeInterval(-200))
        let third = try messages.addMessage("here", in: chat, from: .meTo(maya), at: Date().addingTimeInterval(-100))
        let ledger = messages.database.directory.appendingPathComponent("tincan-sent.jsonl")
        let lines = [first, second, third].map { #"{"at":"2026-01-01T00:00:00Z","guid":"\#($0.guid)"}"# }
        try (lines.joined(separator: "\n") + "\n").write(to: ledger, atomically: true, encoding: .utf8)
        let environment = try World.environment(messages).merging(["COLUMNS": "60"]) { $1 }

        let json = try CLI.run(["read", "chat:\(chat)", "--json"], environment: environment)
        let rows = try (json.dataObject["messages"] as? [[String: Any]]) ?? []
        let marked = rows.filter { $0["sent_by_tincan"] as? Bool == true }.compactMap { $0["ref"] as? String }
        #expect(marked == [first, second, third].map { "m:\($0.rowID)" })
        #expect(rows.first { $0["ref"] as? String == "m:\(typed.rowID)" }?["sent_by_tincan"] == nil)
        // One marker for each run of messages tincan sent.
        let shown = try CLI.run(["read", "chat:\(chat)"], environment: environment).stdout
        #expect(shown.components(separatedBy: "via tincan").count - 1 == 2, "\(shown)")
    }

    /// Anyone can send a subject, so characters that merge where the subject meets the text,
    /// such as a subject ending in a prepended mark before a combining accent, must not crash.
    @Test func charactersThatMergeAcrossASubjectStillRender() throws {
        let messages = try MessagesFixture()
        let maya = try messages.addHandle("+14155550142")
        let chat = try messages.addChat("iMessage;-;+14155550142", participants: [maya])
        try messages.addMessage("\u{0301}", in: chat, from: .handle(maya), at: Date().addingTimeInterval(-120)) { $0.subject = "x\u{0600}" }
        try messages.addMessage("\u{0301}and more", in: chat, from: .meTo(maya), at: Date().addingTimeInterval(-60)) { $0.subject = "\u{0600}" }
        let environment = try World.environment(messages).merging(["COLUMNS": "40"]) { $1 }
        let result = try CLI.run(["read", "chat:\(chat)"], environment: environment)
        #expect(result.status == 0, "\(result.stderr)")
        #expect(result.stdout.contains("and more"), "\(result.stdout)")
    }

    @Test func headersShowANumberOnceAndFormatted() throws {
        let yourself = try world.run(["send", "me", "hi", "--dry-run"], columns: 80).stdout.split(separator: "\n").first.map(String.init) ?? ""
        #expect(yourself == "To yourself  ·  iMessage?  ·  +1 (415) 555-0101", "\(yourself)")
        let stranger = try world.run(["send", "+14155550111", "hi", "--dry-run"], columns: 80).stdout.split(separator: "\n").first.map(String.init) ?? ""
        #expect(stranger == "To +1 (415) 555-0111  ·  iMessage?", "\(stranger)")
        for number in ["+14155550199", "+14155550177"] {
            let header = try world.run(["who", number], columns: 80).stdout.split(separator: "\n").first.map(String.init) ?? ""
            #expect(header == Address(number, region: "US").formatted, "\(header)")
        }
        // A card keeps its reference beside the name.
        #expect(try world.run(["who", "Maya"], columns: 80).stdout.split(separator: "\n").first?.hasSuffix("contact:maya") == true)
    }

    @Test func aSettingsMistakeNamesItsLineOnce() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tincan-polish-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: file) }
        try "region = \"US\"\n[send\n".write(to: file, atomically: true, encoding: .utf8)
        let result = try world.run(["chats"], environment: ["TINCAN_CONFIG": file.path])
        #expect(result.stderr.hasPrefix("✗ The settings file has a mistake on line 2: "), "\(result.stderr)")
        #expect(!result.stderr.contains("config line"))
    }

    @Test func ambiguityNamesWhatTheCandidatesAre() throws {
        #expect(try world.run(["read", "Sam"]).stderr.hasPrefix("? \"Sam\" could mean 2 people. Say which one:"))
    }

    @Test func aNameOfSeveralWordsWithoutQuotesIsExplained() throws {
        let result = try world.run(["read", "Sam", "Park", "--limit", "5"], columns: 100)
        #expect(result.status == 64)
        #expect(result.stderr == "? \"Sam Park\" needs quotes to be one argument.\n  → Run `tincan read 'Sam Park' --limit 5`.\n")
        #expect(try world.run(["contacts", "show", "Sam", "Park"]).stderr.contains("`tincan contacts show 'Sam Park'`"))
        // Options first, or JSON: ArgumentParser's own message.
        #expect(try world.run(["read", "--limit", "5", "Sam", "Park"]).stderr.contains("Unexpected argument 'Park'"))
        #expect(try world.run(["who", "Sam", "Park", "--json"]).errorCode == "invalid_arguments")
    }

    @Test func headersDropDetailsWholeRatherThanCutThem() throws {
        let header = try world.run(["read", "Maximilian"], columns: 80).stdout.split(separator: "\n").first.map(String.init) ?? ""
        #expect(!header.contains("…  chat:"), "\(header)")
        #expect(header.contains("·  Current: iMessage"), "\(header)")
    }

    @Test func aMessageReferenceInPlaceOfAPersonSaysHowToReadIt() throws {
        let result = try world.run(["read", "m:5"], columns: 100)
        #expect(result.status == 3)
        #expect(result.stderr.contains("m:5 is a message. Read it in its conversation with `tincan read <chat> --around m:5`."), "\(result.stderr)")
    }

    @Test func contactRowsCountOtherAddressesInWords() throws {
        let wide = try world.run(["contacts"], columns: 140).stdout
        #expect(wide.contains("+1 (415) 555-0142 · Northwind · 1 more"), "\(wide)")
        let narrow = try world.run(["contacts"], columns: 80).stdout
        #expect(!narrow.contains("·…") && !narrow.contains("· …"), "\(narrow)")
    }
}
