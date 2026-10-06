import Foundation
import Testing

@testable import TincanCLI

/// Sending is only ever previewed or refused here. Fixture runs can't send: tincan refuses
/// while TINCAN_MESSAGES_DB is set, after every check a real send would make, and never
/// reaches AppleScript.
@Suite("Send")
struct SendTests {
    let world: World

    init() throws { world = try World() }

    @Test func dryRunShowsThePlanAndWhereItGoes() throws {
        let arguments = ["send", "maya@example.com", "running 5 min late", "save me a seat 🙏", "--dry-run", "--typing", "paced", "--seed", "7"]
        let result = try world.json(arguments)
        #expect(result.status == 0)
        let data = try result.dataObject
        #expect(data["dry_run"] as? Bool == true)
        #expect(data["ok"] as? Bool == true)
        #expect(data["chat"] as? String == world.chat("mayaMail"))
        #expect(data["route_reason"] as? String == "the conversation with the address you gave")
        #expect(data["service"] as? String == "imessage")
        #expect(data["method"] as? String == "paced")
        #expect((data["to"] as? [String: Any])?["contact"] as? String == "contact:maya")
        let plan = data["plan"] as? [[String: Any]] ?? []
        #expect(plan.compactMap { $0["text"] as? String } == ["running 5 min late", "save me a seat 🙏"])
        #expect(plan.allSatisfy { ($0["typing_seconds"] as? Double ?? 0) > 0 })
        // The same seed plans the same pauses.
        #expect(try world.json(arguments).dataObject["plan"] as? NSArray == plan as NSArray)
        try JSONShape.expect(result.json, matches: "send-dry-run")

        let human = try world.run(arguments)
        #expect(human.stdout.contains("To Maya Chen"))
        #expect(human.stdout.contains("Dry run: nothing was sent."))
    }

    @Test func anAddressDecidesTheConversation() throws {
        // The number's own threads, most recent first; never Maya's email.
        let phone = try world.json(["send", "+14155550142", "hi", "--dry-run", "--typing", "paced"]).dataObject
        #expect(phone["chat"] as? String == world.chat("mayaText"))
        #expect(phone["route_reason"] as? String == "the most recent of 2 conversations with the address you gave")
        #expect((phone["to"] as? [String: Any])?["address"] as? String == "+14155550142")
        let iMessage = try world.json(["send", "(415) 555-0142", "hi", "--dry-run", "--typing", "paced", "--service", "imessage"]).dataObject
        #expect(iMessage["chat"] as? String == world.chat("maya"))
        // `address:<address>`, as `exclude list` shows it, is that address, never another
        // of the card's or the literal text.
        for (reference, chat, address) in [
            ("address:+14155550142", "mayaText", "+14155550142"), (" ADDRESS: maya@example.com", "mayaMail", "maya@example.com"),
        ] {
            let entry = try world.json(["send", reference, "hi", "--dry-run", "--typing", "paced"]).dataObject
            #expect(entry["chat"] as? String == world.chat(chat), "\(reference)")
            #expect((entry["to"] as? [String: Any])?["address"] as? String == address, "\(reference)")
        }
        // `me` with space around it is still you, never a conversation on another address of your card.
        let me = try world.json(["send", "me", "hi", "--dry-run", "--typing", "paced"]).dataObject
        for padded in [" me", "me ", "me\n"] {
            let result = try world.json(["send", padded, "hi", "--dry-run", "--typing", "paced"]).dataObject
            #expect(result["route_reason"] as? String == me["route_reason"] as? String, "\(padded)")
            #expect((result["to"] as? [String: Any])?["address"] as? String == (me["to"] as? [String: Any])?["address"] as? String)
        }
        // A name whose threads use several addresses needs you to pick one.
        let maya = try world.json(["send", "Maya", "hi", "--dry-run"])
        #expect(maya.status == 3)
        #expect(try maya.errorCode == "ambiguous_destination")
        let candidates = try maya.error?["candidates"] as? [[String: Any]] ?? []
        #expect(Set(candidates.compactMap { $0["reference"] as? String }) == Set(["maya", "mayaText", "mayaMail"].map(world.chat)))
        #expect(candidates.contains { $0["name"] as? String == "maya@example.com · iMessage" })
        // One address on several services continues the most recent thread.
        let sms = try world.json(["send", "Maya", "hi", "--dry-run", "--service", "sms"]).dataObject
        #expect(sms["chat"] as? String == world.chat("mayaText"))
        #expect(sms["route_reason"] as? String == "your conversation with Maya Chen")
        // A conversation named by reference keeps its own service.
        for (chat, service, kind) in [("maya", "sms", "an iMessage"), ("mayaText", "imessage", "an SMS")] {
            let other = try world.json(["send", world.chat(chat), "hi", "--dry-run", "--service", service])
            #expect(try other.errorCode == "invalid_input")
            #expect(try other.error?["message"] as? String == "\(world.chat(chat)) is \(kind) conversation.")
        }
    }

    @Test func dryRunExplainsTheMethod() throws {
        let off = try world.json(["send", "maya@example.com", "hi", "--dry-run", "--typing", "off"]).dataObject
        #expect(off["method"] as? String == "immediate")
        #expect(off["method_reason"] as? String == "pacing is off")
        let group = try world.json(["send", world.chat("crew"), "hi all", "--dry-run", "--typing", "auto"]).dataObject
        #expect(group["method"] as? String == "paced")
        #expect(group["method_reason"] as? String == "groups are paced without the typing indicator")
        let keyboard = try world.json(["send", world.chat("crew"), "hi all", "--dry-run", "--typing", "keyboard"])
        #expect(keyboard.status == 64)
        #expect(try keyboard.errorCode == "invalid_input")
        // No RCS thread yet: a new conversation at her only number.
        let rcs = try world.json(["send", "Maya", "hi", "--dry-run", "--service", "rcs", "--typing", "paced"]).dataObject
        #expect(rcs["chat"] == nil)
        #expect((rcs["to"] as? [String: Any])?["address"] as? String == "+14155550142")
        #expect(rcs["route_reason"] as? String == "a new conversation at +1 (415) 555-0142")
        let me = try world.json(["send", "me", "note to self", "--dry-run", "--typing", "paced"]).dataObject
        #expect((me["to"] as? [String: Any])?["address"] as? String == World.ownAddress)
    }

    @Test func dryRunReadsBubblesFromStandardInput() throws {
        let result = try world.run(["send", "maya@example.com", "-", "--dry-run", "--typing", "off", "--json"], stdin: "on my way\n\nsave me a seat\n")
        #expect(try result.dataObject["plan"].map { ($0 as? [[String: Any]])?.count } == 2)
    }

    @Test func withoutATerminalSendingNeedsYesBeforeAnythingElse() throws {
        let noYes = try world.json(["send", "+14155550142", "hi", "--typing", "paced"])
        #expect(noYes.status == 3)
        #expect(try noYes.errorCode == "confirmation_required")
        let human = try world.run(["send", "+14155550142", "hi", "--typing", "paced"])
        #expect(human.status == 3)
        #expect(human.stdout.isEmpty)
        #expect(human.stderr.contains("needs --yes"))

        let stranger = try world.json(["send", "+14155550133", "hi", "--yes", "--typing", "paced"])
        #expect(stranger.status == 3)
        #expect(try stranger.errorCode == "new_conversation")

        // Past every check, fixture runs stop before Messages is asked to do anything.
        for arguments in [["send", "+14155550142", "hi", "--yes"], ["send", "+14155550133", "hi", "--yes", "--new-conversation"]] {
            let refused = try world.json(arguments + ["--typing", "paced"])
            #expect(refused.status == 1)
            #expect(try refused.errorCode == "sending_unavailable")
        }
    }

    @Test func ambiguityNeedsAnswersAndBadInputIsAUsageError() throws {
        let sam = try world.json(["send", "Sam", "hi", "--dry-run"])
        #expect(sam.status == 3)
        #expect(try sam.errorCode == "ambiguous")
        #expect(try (sam.error?["candidates"] as? [Any])?.count == 2)
        // The facts that tell them apart, not just a line of text.
        let rivera = try (sam.error?["candidates"] as? [[String: Any]])?.first { $0["reference"] as? String == "contact:sam-rivera" }
        #expect(rivera?["organization"] as? String == "Northwind")
        #expect(rivera?["addresses"] as? [String] == ["+16285550131"])
        #expect(rivera?["conversations"] as? Int == 1)
        try JSONShape.expect(sam.json, matches: "error-ambiguous")

        let tooMany = try world.json(["send", "maya@example.com"] + (1...13).map { "bubble \($0)" } + ["--dry-run"])
        #expect(tooMany.status == 64)
        #expect(try tooMany.errorCode == "invalid_input")
        let empty = try world.json(["send", "maya@example.com", "  ", "--dry-run"])
        #expect(try empty.errorCode == "invalid_input")
        let service = try world.json(["send", "maya@example.com", "hi", "--service", "satellite_sms", "--dry-run"])
        #expect(service.status == 64)
        #expect(try service.errorCode == "invalid_arguments")
        let help = try world.run(["send", "--help"])
        #expect(help.stdout.contains("imessage, sms, rcs"))
        #expect(!help.stdout.contains("satellite"))
    }

    @Test func aNumberWithoutItsCountryCodeListsTheNumbersItCouldBe() throws {
        // Kenji's Japanese mobile, typed the way it is dialled in Japan, on a Mac set to the US.
        let result = try world.json(["send", "09012345678", "hi", "--dry-run"])
        #expect(result.status == 3)
        #expect(try result.errorCode == "incomplete_number")
        let candidates = try result.error?["candidates"] as? [[String: Any]] ?? []
        #expect(candidates.compactMap { $0["reference"] as? String } == ["+819012345678"])
        #expect(candidates.first?["detail"] as? String == "健二 佐藤")
        let human = try world.run(["send", "09012345678", "hi", "--dry-run"])
        #expect(human.stderr.contains("+81 90 1234 5678"))
        #expect(human.stdout.isEmpty)
        // Digits nobody has are refused too, with nothing to choose from.
        let unknown = try world.json(["send", "555-0109", "hi", "--dry-run"])
        #expect(try unknown.errorCode == "incomplete_number")
        #expect(try unknown.error?["candidates"] == nil)
        // The full number works.
        #expect(try world.json(["send", "+81 90-1234-5678", "hi", "--dry-run", "--typing", "paced"]).status == 0)
        // Every command lists the numbers it could be rather than choosing one.
        let who = try world.json(["who", "09012345678"])
        #expect(try who.errorCode == "incomplete_number")
        #expect((try who.error?["candidates"] as? [[String: Any]] ?? []).compactMap { $0["reference"] as? String } == ["+819012345678"])
    }

    @Test func aLocalNumberListsTheCardNumbersEndingWithIt() throws {
        // Maya's number typed without its area code: hers is a candidate, never the choice.
        let result = try world.json(["send", "555-0142", "hi", "--dry-run"])
        #expect(result.status == 3)
        #expect(try result.errorCode == "incomplete_number")
        let candidates = try result.error?["candidates"] as? [[String: Any]] ?? []
        #expect(candidates.compactMap { $0["reference"] as? String } == ["+14155550142"])
        #expect(candidates.first?["detail"] as? String == "Maya Chen")
        #expect(try (result.error?["hint"] as? String)?.contains("Ask the person which number they mean") == true)
        // The Lee home number is on two cards; both are named.
        let lee = try world.json(["send", "5550177", "hi", "--dry-run"])
        #expect((try lee.error?["candidates"] as? [[String: Any]])?.first?["detail"] as? String == "Jordan Lee, Riley Lee")
    }

    @Test func fewerThanFiveDigitsAreNotANumberToStartAConversationWith() throws {
        for digits in ["0142", "+1 234", "555"] {
            let result = try world.json(["send", digits, "hi", "--dry-run", "--typing", "paced"])
            #expect(result.status == 3, "send \(digits)")
            #expect(try result.errorCode == "incomplete_number", "send \(digits)")
            #expect((try result.error?["message"] as? String)?.contains("too short for a phone number or a short code") == true)
        }
        // Short codes are five or six digits.
        #expect(try world.json(["send", "262966", "hi", "--dry-run", "--typing", "paced"]).status == 0)
    }

    @Test func somethingThatIsNoNumberOrEmailIsNeverAnAddress() throws {
        for recipient in ["@", "maya@", "@example.com", "+14155550142 or +14155550188", "address:@"] {
            for extra in [[], ["--new-conversation"]] {
                let result = try world.json(["send", recipient, "hi", "--dry-run", "--typing", "paced"] + extra)
                #expect(result.status == 64, "send \(recipient)")
                #expect(try result.errorCode == "invalid_input", "send \(recipient)")
                let hint = try result.error?["hint"] as? String ?? ""
                #expect(hint.contains("`tincan send <reference> …`"), "\(hint)")
            }
        }
        // Real numbers and emails, typed any way, still start a conversation.
        for recipient in ["sam@example.com", "+1 (415) 555-0166", "address:+14155550166"] {
            #expect(try world.json(["send", recipient, "hi", "--dry-run", "--typing", "paced"]).status == 0, "send \(recipient)")
        }
    }

    @Test func aShortCodeMessagesAlreadyHasStillWorks() throws {
        let messages = try MessagesFixture()
        let carrier = try messages.addHandle("7726", service: "SMS")
        let chat = try messages.addChat("SMS;-;7726", service: "SMS", participants: [carrier])
        try messages.addMessage("Reply STOP to opt out", in: chat, from: .handle(carrier), at: World.ago(hours: 1)) { $0.service = "SMS" }
        let result = try CLI.run(["send", "7726", "STOP", "--dry-run", "--typing", "paced", "--json"], environment: try World.environment(messages))
        #expect(result.status == 0)
        #expect(try result.dataObject["chat"] as? String == "chat:\(chat)")
    }

    @Test func bubblesWithControlCharactersAreRefused() throws {
        let cases: [(bubbles: [String], message: String)] = [
            (["fine", "look \u{1B}[2Jhere"], "Bubble 2 contains a control character, U+001B (escape)"),
            (["ding\u{07}"], "The bubble contains a control character, U+0007 (bell)"),
            (["line\rover"], "U+000D (carriage return)"),
            (["c1 \u{9B}31m"], "U+009B"),
            // What reorders or breaks the text isn't shown in the preview as Messages shows it.
            (["fine", "invoice \u{202E}fdp.exe"], "Bubble 2 contains U+202E (right-to-left override)"),
            (["a \u{2067}b\u{2069}"], "U+2067 (right-to-left isolate)"),
            (["one\u{2028}two"], "The bubble contains U+2028 (line separator)"),
            (["one\u{2029}two"], "U+2029 (paragraph separator)"),
            // Tag characters outside a flag spell text Messages doesn't show.
            (["fine", "lunch?\u{E0049}\u{E0067}"], "Bubble 2 contains U+E0049 (tag character)"),
            (["\u{1F3F4}\u{E0049}\u{E0067}\u{E007F}"], "U+E0049 (tag character)"),
        ]
        for (bubbles, message) in cases {
            let result = try world.json(["send", "maya@example.com"] + bubbles + ["--dry-run"])
            #expect(result.status == 64)
            #expect(try result.errorCode == "invalid_input")
            #expect((try result.error?["message"] as? String)?.contains(message) == true, "\(bubbles)")
        }
        // Arguments can't hold a null character, but stdin can.
        let null = try world.run(["send", "maya@example.com", "-", "--dry-run", "--json"], stdin: "fine\n\na\u{0}b\n")
        #expect(try null.errorCode == "invalid_input")
        #expect((try null.error?["message"] as? String)?.contains("Bubble 2 contains a control character, U+0000 (null)") == true)
        // Emoji that join, select presentation or carry tags are text.
        let emoji = "🏴\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F} 👨\u{200D}👩\u{200D}👧 1\u{FE0F}\u{20E3} می\u{200C}خواهم"
        #expect(try world.json(["send", "maya@example.com", emoji, "--dry-run", "--typing", "off"]).status == 0)
        // Variation selectors that carry bytes after an emoji spell hidden text.
        let smuggled = try world.json(["send", "maya@example.com", "😀\u{FE0F}\u{E0158}\u{E0159}", "--dry-run", "--typing", "off"])
        #expect(smuggled.status == 64)
        #expect((try smuggled.error?["message"] as? String)?.contains("U+FE0F (variation selector)") == true)
        // So do tags that Apple shows as a plain black flag.
        let california = "\u{1F3F4}\u{E0075}\u{E0073}\u{E0063}\u{E0061}\u{E007F}"
        #expect(try world.json(["send", "maya@example.com", california, "--dry-run", "--typing", "off"]).status == 64)
        // A zero-width space, common in pasted text, spells nothing on its own.
        #expect(try world.json(["send", "maya@example.com", "pass\u{200B}word", "--dry-run", "--typing", "off"]).status == 0)
        // New lines and tabs are text; so are Windows line endings from stdin.
        #expect(try world.json(["send", "maya@example.com", "two\nlines\tand a tab", "--dry-run", "--typing", "off"]).status == 0)
        let piped = try world.run(["send", "maya@example.com", "-", "--dry-run", "--typing", "off", "--json"], stdin: "on my way\r\n\r\nsave me\r\na seat\r\n")
        #expect(piped.status == 0)
        let plan = try piped.dataObject["plan"] as? [[String: Any]] ?? []
        #expect(plan.compactMap { $0["text"] as? String } == ["on my way", "save me\na seat"])
    }

    @Test func previewsSayWhatTheSendWillNeed() throws {
        let new = try world.json(["send", "+14155550133", "hi", "--dry-run", "--typing", "paced"])
        #expect(new.status == 0)
        #expect(try new.dataObject["new_conversation"] as? Bool == true)
        #expect(try new.warningCodes == ["service_unknown", "new_conversation"])
        let existing = try world.json(["send", "maya@example.com", "hi", "--dry-run", "--typing", "paced"])
        #expect(try existing.dataObject["new_conversation"] == nil)
        #expect(try existing.warningCodes.isEmpty)
        // A group preview names everyone who will read it.
        let group = try world.json(["send", world.chat("crew"), "hi all", "--dry-run", "--typing", "paced"])
        let people = try group.dataObject["participants"] as? [[String: Any]] ?? []
        #expect(people.compactMap { $0["name"] as? String } == ["Maya Chen", "Sam Park", "健二 佐藤"])
        #expect(people.compactMap { $0["address"] as? String } == ["+14155550142", "+14155550188", "+819012345678"])
        let human = try world.run(["send", world.chat("crew"), "hi all", "--dry-run", "--typing", "paced"], columns: 140)
        #expect(human.stdout.contains("With Maya Chen +1 (415) 555-0142, Sam Park +1 (415) 555-0188, 健二 佐藤 +81 90 1234 5678 and you."))
    }

    @Test func hintsLeaveSafetyDecisionsToThePerson() throws {
        let new = try world.json(["send", "+14155550133", "hi", "--yes", "--typing", "paced"])
        #expect(try new.error?["hint"] as? String == "Only add --new-conversation after the person confirms this exact number or email.")
        let refused = try world.json(["send", "+14155550142", "hi", "--yes", "--typing", "paced"])
        let hint = try refused.error?["hint"] as? String ?? ""
        #expect(!hint.contains("Unset"))
        #expect(hint.contains("Sending is off while tincan reads other data"))
        let maya = try world.json(["send", "Maya", "hi", "--dry-run"])
        #expect(try (maya.error?["hint"] as? String)?.contains("`tincan send <reference> …`") == true)

        let excluded = try World()
        try excluded.run(["exclude", "add", excluded.chat("rivera")])
        for reference in [excluded.chat("rivera"), "Sam Rivera"] {
            let result = try excluded.json(["send", reference, "hi", "--dry-run"])
            #expect(try result.errorCode == "excluded")
            let hint = try result.error?["hint"] as? String ?? ""
            #expect(!hint.contains("exclude remove"), "\(reference): \(hint)")
            #expect(hint.contains("only they can change that"))
        }
    }

    @Test func toYourselfWithoutAConversationSaysSendingStartsOne() throws {
        let preview = try world.json(["send", "me", "note to self", "--dry-run", "--typing", "paced"])
        #expect(try preview.dataObject["route_reason"] as? String == "a new conversation with yourself at +1 (415) 555-0101")
        #expect(try preview.warningCodes == ["service_unknown", "new_conversation"])
        let refused = try world.json(["send", "me", "note to self", "--yes", "--typing", "paced"])
        #expect(refused.status == 3)
        #expect(try refused.errorCode == "new_conversation")
        let message = try refused.error?["message"] as? String ?? ""
        #expect(message == "You have no conversation with yourself yet. Sending to yourself at +1 (415) 555-0101 starts one, which needs --new-conversation.")
    }

    @Test func toYourselfContinuesYourConversationWithYourself() throws {
        // Your notes to yourself, on your email rather than your most-used number.
        let messages = try MessagesFixture()
        let number = try messages.addHandle("+14155550142")
        let chat = try messages.addChat("iMessage;-;+14155550142", participants: [number])
        try messages.addMessage("hello", in: chat, from: .meTo(number), at: World.ago(hours: 2)) { $0.destinationCallerID = World.ownAddress }
        try messages.addMessage("hi", in: chat, from: .meTo(number), at: World.ago(hours: 1)) { $0.destinationCallerID = World.ownAddress }
        let me = try messages.addHandle("me@example.com")
        let notes = try messages.addChat("iMessage;-;me@example.com", participants: [me])
        try messages.addMessage("note to self", in: notes, from: .meTo(me), at: World.ago(minutes: 30)) { $0.destinationCallerID = "me@example.com" }
        let result = try world.json(["send", "me", "another note", "--dry-run", "--typing", "paced"], environment: ["TINCAN_MESSAGES_DB": messages.path])
        #expect(result.status == 0)
        let data = try result.dataObject
        #expect(data["chat"] as? String == "chat:\(notes)")
        #expect(data["new_conversation"] == nil)
        #expect(data["route_reason"] as? String == "your conversation with yourself")
        #expect(try result.warningCodes.isEmpty)
    }

    @Test func attachmentsShowTheirFullPathAndSize() throws {
        let folder = world.directory.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let itinerary = folder.appendingPathComponent("itinerary.pdf")
        try Data(repeating: 0x25, count: 2_048).write(to: itinerary)
        let real = try #require(realpath(itinerary.path, nil))
        let path = String(cString: real)
        free(real)
        // A link is followed, and the file it leads to is what is shown and sent.
        let alias = folder.appendingPathComponent("plan.pdf")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: itinerary)

        let arguments = ["send", "maya@example.com", "the plan", "--file", alias.path, "--dry-run", "--typing", "paced"]
        let result = try world.json(arguments)
        #expect(result.status == 0)
        let files = try result.dataObject["files"] as? [[String: Any]] ?? []
        #expect(files.count == 1)
        #expect(files.first?["path"] as? String == path)
        #expect(files.first?["bytes"] as? Int == 2_048)
        try JSONShape.expect(result.json, matches: "send-dry-run-file")

        // The whole path, wrapped rather than cut short when it is long.
        for columns in [40, 100] {
            let human = try world.run(arguments, columns: columns).stdout
            #expect(human.filter { !$0.isWhitespace }.contains("📎\(path)·2KB"), "\(human)")
        }
    }

    @Test func attachmentsFromPrivatePlacesFoldersAndLargeFilesAreRefused() throws {
        let folder = world.directory.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let settingsLink = folder.appendingPathComponent("settings.txt")
        try FileManager.default.createSymbolicLink(at: settingsLink, withDestinationURL: URL(fileURLWithPath: world.config))
        let libraryLink = folder.appendingPathComponent("library")
        try FileManager.default.createSymbolicLink(at: libraryLink, withDestinationURL: URL(fileURLWithPath: NSHomeDirectory() + "/Library"))
        let original = folder.appendingPathComponent("original.txt")
        try Data("hello".utf8).write(to: original)
        let second = folder.appendingPathComponent("second.txt")
        try FileManager.default.linkItem(at: original, to: second)
        // Sparse, so the test writes almost nothing.
        let movie = folder.appendingPathComponent("movie.mov")
        FileManager.default.createFile(atPath: movie.path, contents: nil)
        let handle = try FileHandle(forWritingTo: movie)
        try handle.truncate(atOffset: 100_000_001)
        try handle.close()

        let cases: [(String, String)] = [
            ("~/Library", "file_not_allowed"), (libraryLink.path, "file_not_allowed"), (world.config, "file_not_allowed"),
            (settingsLink.path, "file_not_allowed"), (folder.path, "file_not_allowed"), (second.path, "file_not_allowed"),
            (movie.path, "file_too_large"), (folder.appendingPathComponent("missing.pdf").path, "invalid_input"),
            ("/dev/zero", "file_not_allowed"), ("/etc/hosts", "file_not_allowed"),
        ]
        for (path, code) in cases {
            let result = try world.json(["send", "maya@example.com", "hi", "--file", path, "--dry-run"])
            // A mistyped path is a usage error; a file tincan won't send is for the person to replace.
            #expect(result.status == (code == "invalid_input" ? 64 : 3), "\(path)")
            #expect(try result.errorCode == code, "\(path)")
        }
        func words(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let human = try world.run(["send", "maya@example.com", "hi", "--file", "~/Library", "--dry-run"])
        #expect(human.stdout.isEmpty)
        #expect(words(human.stderr).contains("tincan doesn't attach ~/Library, which holds private data."))
        #expect(words(human.stderr).contains("ask them to save a copy somewhere else"))
        let link = try world.run(["send", "maya@example.com", "hi", "--file", settingsLink.path, "--dry-run"])
        #expect(words(link.stderr).contains("tincan doesn't attach files from"))
        let large = try world.run(["send", "maya@example.com", "hi", "--file", movie.path, "--dry-run"])
        #expect(words(large.stderr).contains("movie.mov is larger than the 100 MB Messages sends."))
        // A device says so, rather than pointing at folders.
        let device = try world.json(["send", "maya@example.com", "hi", "--file", "/dev/zero", "--dry-run"])
        #expect(try device.error?["message"] as? String == "/dev/zero is a device, not a file.")
        #expect(try !(device.error?["hint"] as? String ?? "").contains("folder"))
        let system = try world.json(["send", "maya@example.com", "hi", "--file", "/etc/hosts", "--dry-run"])
        #expect(try (system.error?["hint"] as? String)?.contains("your home folder (not ~/Library or hidden folders), /Volumes and temporary folders") == true)
        // The environment can't turn the whole system into a home or temporary folder.
        for extra in [["TMPDIR": "/"], ["TMPDIR": "/private/var/"], ["CFFIXED_USER_HOME": "/"]] {
            let widened = try world.json(["send", "maya@example.com", "hi", "--file", "/etc/hosts", "--dry-run"], environment: extra)
            #expect(widened.status == 3, "\(extra)")
            #expect(try widened.errorCode == "file_not_allowed", "\(extra)")
        }
    }

    @Test func excludedPeopleAreNeverMessaged() throws {
        let world = try World()
        try world.run(["exclude", "add", "Maya"])
        for reference in ["Maya", "+14155550142", "maya@example.com", world.chat("maya")] {
            let result = try world.json(["send", reference, "hi", "--dry-run"])
            #expect(result.status == 3, "send \(reference)")
            #expect(try result.errorCode == "excluded")
        }
        // Excluding one of her threads is enough to refuse the others too.
        let partial = try World()
        try partial.run(["exclude", "add", partial.chat("mayaText")])
        let refused = try partial.json(["send", "maya@example.com", "hi", "--dry-run"])
        #expect(try refused.errorCode == "excluded")
        // Groups she is in are still yours to message.
        #expect(try partial.json(["send", partial.chat("crew"), "hi", "--dry-run"]).status == 0)
    }
}

@Suite("Send to someone new")
struct NewConversationTests {
    @Test func oneNumberSavedTwiceIsStillOneAddress() throws {
        let contacts = World.contactsJSON.replacingOccurrences(
            of: "\n]",
            with: """
                ,
                  {"id": "riya", "given_name": "Riya", "family_name": "Shah", "phones": ["+14155550133", "(415) 555-0133"]},
                  {"id": "noor", "given_name": "Noor", "family_name": "Haddad", "phones": ["+14155550134"], "emails": ["noor@example.com"]},
                  {"id": "lena", "given_name": "Lena", "family_name": "Berg", "phones": ["+14155550135", "+14155550136"]}
                ]
                """)
        let world = try World(contacts: contacts)
        let riya = try world.json(["send", "Riya", "hi", "--dry-run", "--typing", "paced"])
        #expect(riya.status == 0)
        #expect(try (riya.dataObject["to"] as? [String: Any])?["address"] as? String == "+14155550133")
        // A phone number wins over an email for a first message.
        let noor = try world.json(["send", "Noor", "hi", "--dry-run", "--typing", "paced"])
        #expect(try (noor.dataObject["to"] as? [String: Any])?["address"] as? String == "+14155550134")
        let lena = try world.json(["send", "Lena", "hi", "--dry-run"])
        #expect(lena.status == 3)
        #expect(try lena.errorCode == "ambiguous_address")
        #expect(try (lena.error?["candidates"] as? [Any])?.count == 2)
    }

    @Test func aCardSavedWithoutACountryCodeIsMarkedAndNeverSentToAsDigits() throws {
        // Kenji's number saved the Japanese way, and Olivia's London number the British way,
        // on a Mac set to the US.
        let contacts = World.contactsJSON
            .replacingOccurrences(of: #""value": "+81 90-1234-5678""#, with: #""value": "090-1234-5678""#)
            .replacingOccurrences(
                of: "\n]",
                with: """
                    ,
                      {"id": "olivia", "given_name": "Olivia", "family_name": "Hart", "phones": ["020 7946 0000"]}
                    ]
                    """)
        let world = try World(contacts: contacts)
        for reference in ["+819012345678", "contact:kenji"] {
            let result = try world.json(["send", reference, "hi", "--dry-run", "--typing", "paced"])
            #expect(result.status == 0, "\(reference)")
            let to = try result.dataObject["to"] as? [String: Any]
            #expect(to?["contact"] as? String == "contact:kenji", "\(reference)")
            #expect(to?["address"] as? String == "+819012345678", "\(reference)")
            #expect(to?["match"] as? String == "national", "\(reference)")
        }
        let olivia = try world.json(["send", "Olivia", "hi", "--dry-run"])
        #expect(olivia.status == 3)
        #expect(try olivia.errorCode == "incomplete_number")
        #expect(try (olivia.error?["message"] as? String)?.hasPrefix("Olivia Hart's card has 02079460000") == true)
    }
}

/// The people in a group choose its name, so a name alone never sends to a group, and a
/// group named like someone never receives what tincan types for that person.
@Suite("Send and group names")
struct GroupNameSendTests {
    /// Conversations with Maya and Sam Park, a group someone called "Sam P", and two groups
    /// in Unknown Senders named "Mom" and "Maya Chen".
    let fixture: MessagesFixture
    let maya: Int64
    let samP: Int64
    let junkMom: Int64

    init() throws {
        let fixture = try MessagesFixture()
        self.fixture = fixture
        let mayaPhone = try fixture.addHandle("+14155550142")
        let park = try fixture.addHandle("+14155550188")
        let strangers = try (1...4).map { try fixture.addHandle("+1415555017\($0)") }
        maya = try fixture.addChat("iMessage;-;+14155550142", participants: [mayaPhone])
        let parkChat = try fixture.addChat("iMessage;-;+14155550188", participants: [park])
        samP = try fixture.addChat("iMessage;+;chat200000001", displayName: "Sam P", participants: [strangers[0], strangers[1]])
        junkMom = try fixture.addChat("iMessage;+;chat200000002", displayName: "Mom", participants: [strangers[2]], isFiltered: true)
        let junkMaya = try fixture.addChat("iMessage;+;chat200000003", displayName: "Maya Chen", participants: [strangers[3]], isFiltered: true)
        try fixture.addMessage("dinner?", in: maya, from: .handle(mayaPhone), at: World.ago(hours: 3))
        try fixture.addMessage("climbing?", in: parkChat, from: .handle(park), at: World.ago(hours: 3))
        try fixture.addMessage("hi from the group", in: samP, from: .handle(strangers[0]), at: World.ago(hours: 2))
        try fixture.addMessage("it's mom, new number", in: junkMom, from: .handle(strangers[2]), at: World.ago(hours: 1))
        try fixture.addMessage("hello", in: junkMaya, from: .handle(strangers[3]), at: World.ago(hours: 1))
    }

    private var environment: [String: String] { ["TINCAN_MESSAGES_DB": fixture.path] }

    @Test func aGroupIsSentToOnlyByItsReference() throws {
        let world = try World()
        let result = try world.json(["send", "Climbing crew", "hi all", "--dry-run", "--typing", "paced"])
        #expect(result.status == 3)
        #expect(try result.errorCode == "ambiguous")
        let candidates = try result.error?["candidates"] as? [[String: Any]] ?? []
        #expect(candidates.compactMap { $0["reference"] as? String } == [world.chat("crew")])
        #expect(candidates.first?["detail"] as? String == "group with Maya Chen, Sam Park, 健二 佐藤 and you")
        #expect(candidates.first?["addresses"] as? [String] == ["+14155550142", "+14155550188", "+819012345678"])
        #expect(try (result.error?["hint"] as? String)?.contains("`tincan send <reference> …`") == true)
        // Its reference sends; reading by name still works.
        #expect(try world.json(["send", world.chat("crew"), "hi all", "--dry-run", "--typing", "paced"]).status == 0)
        #expect(try world.json(["read", "Climbing crew"]).status == 0)
    }

    @Test func aGroupNameNeverOutranksAContact() throws {
        // "Sam P" is only the start of Sam Park's name, but that group's exact name.
        let world = try World()
        for command in [["send", "Sam P", "hi", "--dry-run"], ["read", "Sam P"]] {
            let result = try world.json(command, environment: environment)
            #expect(result.status == 3, "tincan \(command.joined(separator: " "))")
            #expect(try result.errorCode == "ambiguous")
            let references = try (result.error?["candidates"] as? [[String: Any]] ?? []).compactMap { $0["reference"] as? String }
            #expect(references == ["contact:sam-park", "chat:\(samP)"], "tincan \(command.joined(separator: " "))")
        }
    }

    @Test func junkGroupsAreNeverFoundByName() throws {
        // Without a contact called Mom, the junk group named Mom is no one.
        let world = try World()
        let unknown = try world.json(["send", "Mom", "hi", "--dry-run"], environment: environment)
        #expect(unknown.status == 3)
        #expect(try unknown.errorCode == "not_found")
        // With one, the name is hers alone.
        let contacts = World.contactsJSON.replacingOccurrences(
            of: "\n]",
            with: """
                ,
                  {"id": "mom", "given_name": "Ana", "family_name": "Chen", "nickname": "Mom", "phones": ["+14155550152"]}
                ]
                """)
        let family = try World(contacts: contacts)
        let result = try family.json(["send", "Mom", "hi", "--dry-run", "--typing", "paced"], environment: environment)
        #expect(result.status == 0)
        #expect(try (result.dataObject["to"] as? [String: Any])?["contact"] as? String == "contact:mom")
        #expect(try result.dataObject["chat"] as? String != "chat:\(junkMom)")
    }

    @Test func aGroupNamedLikeThePersonKeepsTincanFromTypingIntoMessages() throws {
        // Keyboard mode finds Maya's conversation by its title, which the junk group shares.
        let world = try World()
        for reference in ["Maya Chen", "+14155550142"] {
            for mode in ["keyboard", "auto"] {
                let result = try world.json(["send", reference, "hi", "--dry-run", "--typing", mode], environment: environment)
                #expect(result.status == 0, "send \(reference) --typing \(mode)")
                let data = try result.dataObject
                #expect(data["chat"] as? String == "chat:\(maya)")
                #expect(data["method"] as? String == "paced")
                #expect(data["method_reason"] as? String == "a group is also called “Maya Chen”, so tincan won't type into Messages")
            }
        }
        // Sam Park has no such group, so nothing changes for him.
        let park = try world.json(["send", "Sam Park", "hi", "--dry-run", "--typing", "auto"], environment: environment).dataObject
        #expect(!((park["method_reason"] as? String)?.contains("group") ?? true))
    }
}

@Suite("Send results")
struct SendResultTests {
    let world: World

    init() throws { world = try World() }

    @Test func aNewNumbersServiceIsAGuessThatMessagesDecides() throws {
        // Nothing shows whether this number uses iMessage: the preview says so.
        let new = try world.json(["send", "+14155550133", "hi", "--dry-run", "--typing", "paced"])
        let data = try new.dataObject
        #expect(data["service"] as? String == "imessage")
        #expect(data["service_guessed"] as? Bool == true)
        try JSONShape.expect(new.json, matches: "send-dry-run-new")
        let warning = try #require(((try new.json["warnings"] as? [[String: Any]]) ?? []).first { $0["code"] as? String == "service_unknown" })
        #expect((warning["message"] as? String)?.contains("Messages decides") == true)
        #expect((warning["message"] as? String)?.contains("--service sms") == true)
        let human = try world.run(["send", "+14155550133", "hi", "--dry-run", "--typing", "paced"])
        #expect(human.stdout.contains("iMessage?"))
        #expect(human.stderr.contains("can't tell whether +1 (415) 555-0133 uses iMessage"))
        // An email can't go as a text message, so there is no --service sms to suggest.
        let email = try world.json(["send", "new@example.com", "hi", "--dry-run", "--typing", "paced"])
        let emailWarning = try #require(((try email.json["warnings"] as? [[String: Any]]) ?? []).first { $0["code"] as? String == "service_unknown" })
        #expect((emailWarning["message"] as? String)?.contains("--service") == false)
        // A service asked for, or an existing conversation's, is not a guess.
        for arguments in [["send", "+14155550133", "hi", "--service", "sms"], ["send", "maya@example.com", "hi"]] {
            let known = try world.json(arguments + ["--dry-run", "--typing", "paced"])
            #expect(try known.dataObject["service_guessed"] == nil)
            #expect(try !known.warningCodes.contains("service_unknown"))
            let human = try world.run(arguments + ["--dry-run", "--typing", "paced"]).stdout
            #expect(!human.contains("iMessage?") && !human.contains("SMS?"))
        }
    }

    @Test func aDryRunHasNoMessageReferenceOrReplyCommand() throws {
        let result = try world.json(["send", "maya@example.com", "hi", "--dry-run", "--typing", "paced"])
        #expect(try result.dataObject["bubbles"] == nil)
        #expect(try result.json["next"] == nil)
    }

    /// A bubble Messages hasn't confirmed may still go out, so it is never reported as not sent.
    @Test func unconfirmedBubblesAreNeverReportedAsNotSent() {
        let unconfirmed = Send.failure(statuses: [.unconfirmed, .skipped], bounced: 0)
        #expect(unconfirmed.code == "send_unconfirmed")
        #expect(unconfirmed.message == "Nothing was confirmed sent. Messages may still send 1 bubble it hasn't confirmed, and the rest were not sent.")
        #expect(unconfirmed.exit == .failure)
        #expect(
            Send.failure(statuses: [.unconfirmed], bounced: 0).message == "Nothing was confirmed sent. Messages may still send 1 bubble it hasn't confirmed.")
        let partly = Send.failure(statuses: [.sent, .unconfirmed, .skipped], bounced: 0)
        #expect(partly.code == "send_partial")
        #expect(partly.message == "Sent 1 of 3 bubbles. Messages may still send 1 bubble it hasn't confirmed, and the rest were not sent.")
        #expect(partly.exit == .partial)
        #expect(Send.failure(statuses: [.failed, .skipped], bounced: 0).message == "Nothing was sent.")
        #expect(Send.failure(statuses: [.sent, .failed], bounced: 0).message == "Sent 1 of 2 bubbles. The rest were not sent.")
        #expect(Send.failure(statuses: [.failed], bounced: 1).code == "carrier_bounce")
    }

    /// The real send can't run here, so this checks the payload it prints.
    @Test func sentBubblesCarryTheirReferenceAndTheCommandThatWaitsForAReply() throws {
        func bubble(_ status: String, _ id: Int64?) -> Send.BubbleResult {
            Send.BubbleResult(text: "hi", status: status, method: "paced", messageId: id, at: nil, deliveredAt: nil, readAt: nil, error: nil, note: nil)
        }
        let sent = [bubble("sent", 70), bubble("delivered", 71), bubble("read", 72)]
        #expect(sent.map(\.ref) == ["m:70", "m:71", "m:72"])
        // Only a bubble Messages confirmed is a message to point at.
        #expect(bubble("failed", 73).ref == nil)
        #expect(bubble("unconfirmed", 74).ref == nil)
        #expect(bubble("sent", nil).ref == nil)

        let next = try #require(Send.replyNext(after: sent, in: "chat:42"))
        #expect(next.cursor == "m:72")
        #expect(next.command == "tincan watch --in chat:42 --after m:72 --json")
        #expect(Send.replyNext(after: sent + [bubble("unconfirmed", 73)], in: "chat:42")?.cursor == "m:72")
        #expect(Send.replyNext(after: [bubble("failed", 73)], in: "chat:42") == nil)
        // A conversation named by address is quoted for the shell.
        #expect(Send.replyNext(after: sent, in: "maya chen@example.com")?.command == "tincan watch --in 'maya chen@example.com' --after m:72 --json")

        let encoded = try JSONSerialization.jsonObject(with: Output.encoder.encode(sent[0])) as? [String: Any] ?? [:]
        #expect(encoded["ref"] as? String == "m:70")
        #expect(encoded["message_id"] as? Int == 70)
    }

    /// The real send can't run here, so this checks the payload a carrier bounce prints.
    @Test func aBouncedBubbleCarriesItsCodeAndTheCarriersNotice() throws {
        let bounced = Send.BubbleResult(
            text: "running late", status: "failed", method: "paced", messageId: 80, at: nil, deliveredAt: nil, readAt: nil,
            error: "the carrier sent back a notice that it wasn't delivered", errorCode: "carrier_bounce",
            bounce: Send.Bounce(ref: "m:81", text: "Free Msg: Unable to send message", at: Date(timeIntervalSinceReferenceDate: 800_000_000)), note: nil)
        #expect(bounced.ref == nil)
        let encoded = try JSONSerialization.jsonObject(with: Output.encoder.encode(bounced)) as? [String: Any] ?? [:]
        #expect(encoded["error_code"] as? String == "carrier_bounce")
        #expect((encoded["bounce"] as? [String: Any])?["ref"] as? String == "m:81")
    }

    @Test func theBounceWaitIsBounded() throws {
        for value in ["-1", "61"] {
            let result = try world.json(["send", "+14155550142", "hi", "--yes", "--bounce-wait=\(value)", "--typing", "paced"])
            #expect(result.status == 64)
            #expect(try result.errorCode == "invalid_input")
        }
        let help = try world.run(["send", "--help"])
        #expect(help.stdout.contains("--bounce-wait"))
    }

    @Test func theReplyCommandIsOneWatchReallyAccepts() throws {
        // What `next.command` names must parse: watch takes --in and --after.
        _ = try Watch.parse(["--in", "chat:42", "--after", "m:72", "--json"])
    }
}
