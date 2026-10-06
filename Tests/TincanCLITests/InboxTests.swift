import Foundation
import Testing

@Suite("What's new: inbox and watch")
struct InboxTests {
    let world: World

    init() throws { world = try World() }

    /// The row a cursor such as `m:184022` points at.
    func row(_ cursor: Any?) -> Int? {
        guard let text = cursor as? String, text.hasPrefix("m:") else { return nil }
        return Int(text.dropFirst(2))
    }

    /// Every message id other people sent, oldest first, as `inbox --after 0` sees them.
    func incomingIDs() throws -> [Int] {
        let data = try world.json(["inbox", "--after", "0", "--limit", "1000"]).dataObject
        let groups = data["conversations"] as? [[String: Any]] ?? []
        return groups.flatMap { ($0["messages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? Int } }.sorted()
    }

    // MARK: inbox

    @Test func unreadModeListsUnreadMessagesAndTheCursor() throws {
        let result = try world.json(["inbox"])
        #expect(result.status == 0)
        let data = try result.dataObject
        #expect(data["mode"] as? String == "unread")
        let groups = data["conversations"] as? [[String: Any]] ?? []
        #expect(Set(groups.compactMap { $0["chat"] as? String }) == Set(["crew", "stranger", "rivera", "mayaMail"].map(world.chat)))
        let messages = groups.flatMap { $0["messages"] as? [[String: Any]] ?? [] }
        #expect(messages.allSatisfy { $0["unread"] as? Bool == true })
        let cursor = data["cursor"] as? String ?? ""
        // The cursor is the newest row now, so nothing already here is read again.
        #expect((row(cursor) ?? 0) >= (try incomingIDs().last ?? .max))
        #expect(try result.next?["cursor"] as? String == cursor)
        #expect(try result.next?["command"] as? String == "tincan inbox --after \(cursor) --limit 200 --json")
        #expect(messages.allSatisfy { $0["ref"] as? String == "m:\($0["id"] as? Int ?? -1)" })
        try JSONShape.expect(result.json, matches: "inbox-unread")
    }

    @Test func unreadModeKeepsToTheLimit() throws {
        let result = try world.json(["inbox", "--limit", "2"])
        let data = try result.dataObject
        let messages = (data["conversations"] as? [[String: Any]] ?? []).flatMap { $0["messages"] as? [[String: Any]] ?? [] }
        #expect(messages.count == 2)
        #expect(data["truncated"] as? Bool == true)
        #expect(try result.warningCodes == ["truncated"])
        // The cursor reads what comes later, so the footer points at the unread ones left out.
        let human = try world.run(["inbox", "--limit", "2"]).stderr.replacingOccurrences(of: "\n", with: " ")
        #expect(human.contains("More unread than shown: tincan inbox --limit 4, or tincan chats --unread"))
        #expect(!human.contains("More waiting"))
    }

    @Test func afterCursorsReadEverythingOnceInOrder() throws {
        let all = try incomingIDs()
        #expect(all.count > 20)
        var cursor = "0"
        var pages: [[Int]] = []
        for _ in 0..<50 {
            let result = try world.json(["inbox", "--after", cursor, "--limit", "6"])
            #expect(result.status == 0)
            let data = try result.dataObject
            #expect(data["mode"] as? String == "since")
            let page = (data["conversations"] as? [[String: Any]] ?? []).flatMap { ($0["messages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? Int } }
                .sorted()
            pages.append(page)
            let next = try result.next
            #expect(next?["cursor"] as? String == data["cursor"] as? String)
            #expect(next?["command"] as? String == "tincan inbox --after \(next?["cursor"] as? String ?? "?") --limit 6 --json")
            cursor = next?["cursor"] as? String ?? cursor
            if data["truncated"] as? Bool != true { break }
            #expect(page.count == 6)
            #expect(row(cursor) == page.last)
        }
        let seen = pages.flatMap { $0 }
        #expect(seen == all)
        for (earlier, later) in zip(pages, pages.dropFirst()) where !earlier.isEmpty && !later.isEmpty {
            #expect(earlier.last! < later.first!)
        }
        // Nothing new after the last cursor.
        let empty = try world.json(["inbox", "--after", cursor]).dataObject
        #expect((empty["conversations"] as? [Any])?.isEmpty == true)
    }

    @Test func cursorsWithAndWithoutThePrefixReadTheSame() throws {
        let prefixed = try world.json(["inbox", "--after", "m:20", "--limit", "5"])
        let bare = try world.json(["inbox", "--after", "20", "--limit", "5"])
        #expect(prefixed.status == 0 && bare.status == 0)
        #expect((try prefixed.dataObject["cursor"] as? String)?.hasPrefix("m:") == true)
        #expect(prefixed.stdout == bare.stdout)
    }

    @Test func nextCommandKeepsTheFlagsThatShapeTheResult() throws {
        let first = try world.json(["inbox", "--since", "3d", "--mine", "--limit", "4"])
        let command = try #require(try first.next?["command"] as? String)
        #expect(command.hasSuffix("--limit 4 --mine --json"))
        let second = try world.run(Array(Shell.split(command).dropFirst()))
        #expect(second.status == 0)
        let messages = try (second.dataObject["conversations"] as? [[String: Any]] ?? []).flatMap { $0["messages"] as? [[String: Any]] ?? [] }
        #expect(messages.count == 4)
        // --mine carried over: your own messages are still there.
        #expect(messages.contains { $0["from"] as? String == "me" })
    }

    @Test func aCursorPastTheEndWarnsInsteadOfResettingSilently() throws {
        let latest = try world.json(["inbox"]).dataObject["cursor"] as? String
        let result = try world.json(["inbox", "--after", "m:999999"])
        #expect(result.status == 0)
        #expect(try result.warningCodes == ["cursor_ahead"])
        let warning = try (result.json["warnings"] as? [[String: Any]])?.first?["message"] as? String ?? ""
        #expect(warning.contains("newer than any message; Messages' database may have been reset"))
        let data = try result.dataObject
        #expect(data["cursor"] as? String == latest)
        #expect(try result.next?["cursor"] as? String == latest)
        #expect((data["conversations"] as? [Any])?.isEmpty == true)
        let human = try world.run(["inbox", "--after", "999999"])
        #expect(human.stderr.contains("newer than any message"))
    }

    @Test func inboxIncludesReactionsAndYourOwnOnlyWithMine() throws {
        let theirs = try world.json(["inbox", "--since", "3d"])
        let reactions = try theirs.dataObject["reactions"] as? [[String: Any]] ?? []
        #expect(
            reactions.contains {
                $0["reaction"] as? String == "laugh" && $0["from"] as? String == "Sam Park" && $0["target"] as? String == world.rows.groupReactionTarget.guid
            })
        // The target by the reference read --around takes, next to its GUID.
        let laugh = reactions.first { $0["target"] as? String == world.rows.groupReactionTarget.guid }
        #expect(laugh?["target_ref"] as? String == "m:\(world.rows.groupReactionTarget.rowID)")
        #expect(reactions.allSatisfy { $0["target_ref"] is String })
        #expect(!reactions.contains { $0["from"] as? String == "me" })
        let mine = try world.json(["inbox", "--since", "3d", "--mine"]).dataObject["reactions"] as? [[String: Any]] ?? []
        #expect(mine.contains { $0["from"] as? String == "me" && $0["reaction"] as? String == "like" })
        try JSONShape.expect(theirs.json, matches: "inbox-since")
        let human = try world.run(["inbox", "--since", "3d"])
        #expect(human.stdout.contains("Reactions"))
        #expect(human.stdout.contains("“行きます！”"))
    }

    /// Each conversation `inbox` returned, by reference.
    func groups(_ result: CLIResult) throws -> [String: [String: Any]] {
        let groups = try result.dataObject["conversations"] as? [[String: Any]] ?? []
        return Dictionary(groups.map { ($0["chat"] as? String ?? "", $0) }, uniquingKeysWith: { first, _ in first })
    }

    @Test func junkAndUnknownSendersStayOutUnlessAskedFor() throws {
        let junk = world.chat("junk")
        for mode in [[], ["--since", "3d"], ["--after", "0", "--limit", "1000"]] {
            let hidden = try groups(world.json(["inbox"] + mode))
            #expect(hidden[junk] == nil, "inbox \(mode.joined(separator: " "))")
            #expect(hidden.values.allSatisfy { $0["filtered"] == nil })
            let shown = try world.json(["inbox", "--all"] + mode)
            let group = try groups(shown)[junk]
            #expect(group?["filtered"] as? Bool == true, "inbox --all \(mode.joined(separator: " "))")
            #expect((group?["messages"] as? [[String: Any]])?.first?["text"] as? String == "You have won a prize")
            #expect((try shown.next?["command"] as? String)?.hasSuffix(" --all --json") == true)
        }
        #expect(!(try world.run(["inbox"]).stdout.contains("prize")))
        #expect(try world.run(["inbox", "--all"]).stdout.contains("1 unread message  ·  filtered"))

        #expect(try world.json(["search", "prize"]).dataArray.isEmpty)
        let all = try world.json(["search", "prize", "--all"]).dataArray
        #expect(all.count == 1)
        #expect(all.first?["filtered"] as? Bool == true)
        // Naming the conversation or its sender asks for it.
        #expect(try world.json(["search", "prize", "--in", junk]).dataArray.count == 1)
        // Named with --in, it says where Messages filed it, as `read` does.
        for scope in [junk, "+14155550123"] {
            #expect(try world.json(["search", "prize", "--in", scope]).warningCodes == ["filtered_conversation"], "search --in \(scope)")
        }
        #expect(try world.json(["search", "dinner", "--in", "Maya"]).warningCodes.isEmpty)
        #expect(try world.json(["search", "prize", "--from", "+14155550123"]).dataArray.count == 1)

        let watched = try watch(["--after", "0"])
        #expect(!watched.contains { $0["chat"] as? String == junk })
        let watchedAll = try watch(["--after", "0", "--all"]).filter { $0["chat"] as? String == junk }
        #expect(watchedAll.count == 1)
        #expect(watchedAll.first?["filtered"] as? Bool == true)
        let watchedJunk = try watch(["--after", "0", "--in", junk])
        #expect(watchedJunk.contains { $0["chat"] as? String == junk })
        let readyWarnings = (watchedJunk.first?["warnings"] as? [[String: Any]] ?? []).compactMap { $0["code"] as? String }
        #expect(readyWarnings == ["filtered_conversation"])
        #expect(try watch(["--in", "Maya"]).first?["warnings"] == nil)
        // Formatted, they are marked where they appear.
        #expect(try watchOutput(["--after", "0", "--all"]).stdout.contains("You have won a prize  junk  \(junk)"))
        let chats = try world.run(["chats", "--all"], columns: 120).stdout.split(separator: "\n")
        #expect(chats.first { $0.hasSuffix(junk) }?.contains("junk") == true)
        #expect(chats.filter { $0.contains("junk") }.count == 1)
    }

    @Test func inboxRejectsConflictingOrBadOptions() throws {
        let both = try world.json(["inbox", "--after", "3", "--since", "2h"])
        #expect(both.status == 64)
        #expect(try both.errorCode == "invalid_input")
        let bad = try world.json(["inbox", "--after", "yesterday"])
        #expect(bad.status == 64)
        #expect(try bad.errorCode == "invalid_input")
        let limit = try world.json(["inbox", "--limit", "0"])
        #expect(limit.status == 64)
    }

    // MARK: watch

    /// Runs `watch` until its output stops growing, then stops it.
    func watch(_ arguments: [String]) throws -> [[String: Any]] {
        try watchOutput(["--json"] + arguments).jsonLines
    }

    /// What `watch` printed until its output settled.
    func watchOutput(_ arguments: [String]) throws -> CLIResult {
        let running = try CLI.start(["watch", "--interval", "0.2"] + arguments, environment: world.environment)
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
        return running.stop()
    }

    @Test func watchStreamsMessagesAndReactionsInOrder() throws {
        let lines = try watch(["--after", "0"])
        #expect(lines.first?["type"] as? String == "ready")
        #expect(lines.first?["cursor"] as? String == "m:0")
        let cursors = lines.compactMap { row($0["cursor"]) }
        #expect(cursors.count == lines.count)
        #expect(cursors == cursors.sorted())
        let messages = lines.filter { $0["type"] as? String == "message" }
        for line in messages {
            let message = line["message"] as? [String: Any]
            #expect(line["cursor"] as? String == "m:\(message?["id"] as? Int ?? -1)")
            #expect(message?["ref"] as? String == line["cursor"] as? String)
        }
        #expect(messages.compactMap { ($0["message"] as? [String: Any])?["id"] as? Int } == (try incomingIDs()))
        #expect(lines.contains { $0["type"] as? String == "reaction" && $0["reaction"] as? String == "laugh" })
    }

    @Test("Batches keep cursors safe to resume", arguments: ["0.3", "90"])
    func watchBatchesKeepCursorsSafeToResume(seconds: String) throws {
        let lines = try watch(["--after", "m:0", "--batch", seconds])
        let all = try incomingIDs()
        var emitted = Set<Int>()
        var previous = 0
        for line in lines.dropFirst() {
            if let messages = line["messages"] as? [[String: Any]] {
                #expect(line["type"] as? String == "batch")
                emitted.formUnion(messages.compactMap { $0["id"] as? Int })
            }
            let cursor = row(line["cursor"]) ?? -1
            #expect(cursor >= previous)
            previous = cursor
            // Resuming from this cursor must not skip anything: every message at or below
            // it has already been printed.
            #expect(all.filter { $0 <= cursor }.allSatisfy(emitted.contains))
        }
        #expect(emitted == Set(all))
    }

    @Test func watchBatchesByWhenMessagesWereSentAndKeepsRowOrder() throws {
        // Catching up: the fixture's messages were sent a minute or more apart, long ago.
        let lines = try watch(["--after", "m:0", "--batch", "90", "--mine"])
        let batches = lines.filter { $0["type"] as? String == "batch" }
        #expect(batches.contains { ($0["messages"] as? [Any])?.count ?? 0 > 5 })
        let iso = ISO8601DateFormatter()
        func date(_ message: [String: Any]) -> Date { iso.date(from: message["at"] as? String ?? "") ?? .distantPast }
        var lastInChat: [String: [String: Any]] = [:]
        for batch in batches {
            let messages = batch["messages"] as? [[String: Any]] ?? []
            // Within a batch, each message was sent within 90 seconds of the one before.
            for (earlier, later) in zip(messages, messages.dropFirst()) {
                #expect(abs(date(later).timeIntervalSince(date(earlier))) <= 90)
            }
            // A conversation's next batch starts with a message sent more than 90 seconds later.
            let chat = batch["chat"] as? String ?? ""
            if let previous = lastInChat[chat], let first = messages.first {
                #expect(date(first).timeIntervalSince(date(previous)) > 90)
            }
            lastInChat[chat] = messages.last
        }
        // Events print in the order of their first row, and a reaction never comes before
        // the message it reacts to.
        var printed = Set<String>()
        var firstRows: [Int] = []
        for line in lines.dropFirst() {
            let messages = (line["messages"] as? [[String: Any]]) ?? (line["message"] as? [String: Any]).map { [$0] } ?? []
            if let first = messages.first?["id"] as? Int { firstRows.append(first) }
            printed.formUnion(messages.compactMap { $0["guid"] as? String })
            if line["type"] as? String == "reaction" {
                #expect(printed.contains(line["target"] as? String ?? ""), "reaction printed before its message")
            }
        }
        #expect(firstRows == firstRows.sorted())
        let reactions = lines.filter { $0["type"] as? String == "reaction" }.compactMap { $0["target"] as? String }
        #expect(reactions.contains(world.rows.mayaYes.guid))
        #expect(reactions.contains(world.rows.groupReactionTarget.guid))
        let love = lines.first { $0["type"] as? String == "reaction" && $0["target"] as? String == world.rows.mayaYes.guid }
        #expect(love?["target_ref"] as? String == "m:\(world.rows.mayaYes.rowID)")
    }

    @Test func watchWarnsAboutACursorPastTheEnd() throws {
        let latest = try world.json(["inbox"]).dataObject["cursor"] as? String
        let lines = try watch(["--after", "m:999999"])
        let ready = try #require(lines.first)
        #expect(ready["type"] as? String == "ready")
        #expect(ready["cursor"] as? String == latest)
        let warnings = ready["warnings"] as? [[String: Any]] ?? []
        #expect(warnings.compactMap { $0["code"] as? String } == ["cursor_ahead"])
    }

    @Test func watchRejectsABadCursor() throws {
        let result = try world.json(["watch", "--after", "m:yesterday"])
        #expect(result.status == 64)
        #expect(try result.errorCode == "invalid_input")
        #expect(try (result.error?["hint"] as? String)?.contains("m:184022") == true)
    }

    @Test func watchFromFiltersMessagesAndReactions() throws {
        let lines = try watch(["--after", "0", "--from", "Sam Park"])
        let messages = lines.filter { $0["type"] as? String == "message" }
        #expect(!messages.isEmpty)
        #expect(messages.allSatisfy { ($0["message"] as? [String: Any])?["from_address"] as? String == "+14155550188" })
        let reactions = lines.filter { $0["type"] as? String == "reaction" }
        #expect(!reactions.isEmpty)
        #expect(reactions.allSatisfy { $0["from"] as? String == "Sam Park" })
    }

    @Test func watchRejectsATooShortInterval() throws {
        let result = try world.json(["watch", "--interval", "0.05"])
        #expect(result.status == 64)
        #expect(try result.errorCode == "invalid_input")
    }
}

@Suite("Watching as messages arrive")
struct WatchArrivalTests {
    /// Waits until `running` has printed at least `count` lines.
    static func waitFor(_ running: CLI.Running, lines count: Int, seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, running.output.split(separator: "\n").count < count { usleep(50_000) }
    }

    /// The text of every message a `watch --json` stream printed, in order.
    static func texts(_ lines: [[String: Any]]) -> [String] {
        lines.flatMap { line in
            ((line["messages"] as? [[String: Any]]) ?? (line["message"] as? [String: Any]).map { [$0] } ?? []).compactMap { $0["text"] as? String }
        }
    }

    @Test func arrivingBatchesGroupBySendTimeAndNothingJumpsAhead() throws {
        let messages = try MessagesFixture()
        let maya = try messages.addHandle("+14155550142")
        let sam = try messages.addHandle("+14155550188")
        let withMaya = try messages.addChat("iMessage;-;+14155550142", participants: [maya])
        let withSam = try messages.addChat("iMessage;-;+14155550188", participants: [sam])
        let start = try messages.addMessage("earlier today", in: withMaya, from: .handle(maya), at: Date().addingTimeInterval(-3600))
        let environment = try World.environment(messages)
        let running = try CLI.start(["watch", "--json", "--interval", "0.2", "--batch", "2"], environment: environment)
        func waitFor(lines count: Int, seconds: TimeInterval) { Self.waitFor(running, lines: count, seconds: seconds) }
        waitFor(lines: 1, seconds: 10)

        let now = Date()
        let first = try messages.addMessage("are you around?", in: withMaya, from: .handle(maya), at: now)
        let reaction = try messages.addReaction(.love, to: first, in: withMaya, from: .handle(maya), at: now.addingTimeInterval(0.5))
        let hello = try messages.addMessage("hello?", in: withSam, from: .handle(sam), at: now.addingTimeInterval(0.6))
        let second = try messages.addMessage("need a ride", in: withMaya, from: .handle(maya), at: now.addingTimeInterval(1))
        // Sent a minute later by her phone's clock: a new batch, though it arrives at once.
        let later = try messages.addMessage("never mind", in: withMaya, from: .handle(maya), at: now.addingTimeInterval(60))
        waitFor(lines: 5, seconds: 15)
        let lines = try running.stop().jsonLines

        #expect(lines.compactMap { $0["type"] as? String } == ["ready", "batch", "reaction", "batch", "batch"])
        guard lines.count == 5 else { return }
        let texts = lines.map { ($0["messages"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String } }
        #expect(texts[1] == ["are you around?", "need a ride"])
        #expect(lines[2]["target"] as? String == first.guid)
        #expect(texts[3] == ["hello?"])
        #expect(texts[4] == ["never mind"])
        // While Sam's batch waits, the cursor stays below it; each is safe to resume from.
        let cursors = lines.compactMap { $0["cursor"] as? String }
        #expect(cursors == [start, first, reaction, second, later].map { "m:\($0.rowID)" })
        #expect(hello.rowID < second.rowID)
    }

    @Test func aPersonsNewConversationsJoinTheStream() throws {
        let messages = try MessagesFixture()
        let maya = try messages.addHandle("+14155550142")
        let withMaya = try messages.addChat("iMessage;-;+14155550142", participants: [maya])
        try messages.addMessage("earlier today", in: withMaya, from: .handle(maya), at: Date().addingTimeInterval(-3600))
        let stranger = try messages.addHandle("+14155550199")
        let withStranger = try messages.addChat("iMessage;-;+14155550199", participants: [stranger])
        // Sam has a card, and no conversation yet.
        let environment = try World.environment(
            messages,
            contacts: """
                [{"id": "maya", "given_name": "Maya", "family_name": "Chen", "phones": ["+14155550142"], "emails": ["maya@example.com"]},
                 {"id": "sam", "given_name": "Sam", "family_name": "Park", "phones": ["+14155550188"]}]
                """)
        let watchingMaya = try CLI.start(["watch", "--in", "Maya", "--json", "--interval", "0.2"], environment: environment)
        let watchingSam = try CLI.start(["watch", "--in", "Sam Park", "--json", "--interval", "0.2"], environment: environment)
        Self.waitFor(watchingMaya, lines: 1, seconds: 10)
        Self.waitFor(watchingSam, lines: 1, seconds: 10)

        // Conversations that start while watching: Maya's first SMS thread and her email,
        // Sam's first message, a new group with both, and someone else entirely.
        let now = Date()
        let mayaSMS = try messages.addHandle("+14155550142", service: "SMS")
        let text = try messages.addChat("SMS;-;+14155550142", service: "SMS", participants: [mayaSMS])
        try messages.addMessage("texting from the airport", in: text, from: .handle(mayaSMS), at: now) { $0.service = "SMS" }
        let mayaEmail = try messages.addHandle("maya@example.com")
        let mail = try messages.addChat("iMessage;-;maya@example.com", participants: [mayaEmail])
        try messages.addMessage("sent from my laptop", in: mail, from: .handle(mayaEmail), at: now.addingTimeInterval(1))
        let sam = try messages.addHandle("+14155550188")
        let withSam = try messages.addChat("iMessage;-;+14155550188", participants: [sam])
        try messages.addMessage("hi, it's Sam", in: withSam, from: .handle(sam), at: now.addingTimeInterval(2))
        try messages.addMessage("not for either of them", in: withStranger, from: .handle(stranger), at: now.addingTimeInterval(3))
        let dinner = try messages.addChat("iMessage;+;chat100000009", displayName: "Dinner", participants: [maya, sam])
        try messages.addMessage("table for three?", in: dinner, from: .handle(maya), at: now.addingTimeInterval(4))
        Self.waitFor(watchingMaya, lines: 4, seconds: 15)
        Self.waitFor(watchingSam, lines: 3, seconds: 15)
        let mayaLines = try watchingMaya.stop().jsonLines
        let samLines = try watchingSam.stop().jsonLines

        #expect(Self.texts(mayaLines) == ["texting from the airport", "sent from my laptop", "table for three?"])
        #expect(Self.texts(samLines) == ["hi, it's Sam", "table for three?"])
        #expect(samLines.first?["type"] as? String == "ready")
    }

    @Test func formattedWatchWarnsOnceAboutANumberOnSeveralCards() throws {
        let messages = try MessagesFixture()
        let lee = try messages.addHandle("+14155550177")
        let chat = try messages.addChat("iMessage;-;+14155550177", participants: [lee])
        let start = try messages.addMessage("earlier", in: chat, from: .handle(lee), at: Date().addingTimeInterval(-600))
        try messages.addMessage("Hi, it's the Lee house", in: chat, from: .handle(lee), at: Date().addingTimeInterval(-300))
        try messages.addMessage("call us back", in: chat, from: .handle(lee), at: Date().addingTimeInterval(-240))
        let environment = try World.environment(
            messages,
            contacts: """
                [{"id": "jordan-lee", "given_name": "Jordan", "family_name": "Lee", "phones": ["+14155550177"]},
                 {"id": "riley-lee", "given_name": "Riley", "family_name": "Lee", "phones": ["+14155550177"]}]
                """)
        let running = try CLI.start(["watch", "--interval", "0.2", "--after", "m:\(start.rowID)"], environment: environment)
        Self.waitFor(running, lines: 2, seconds: 10)
        let result = running.stop()
        #expect(result.stdout.contains("+1 (415) 555-0177 › Hi, it's the Lee house"), "\(result.stdout)")
        #expect(result.stdout.contains("+1 (415) 555-0177 › call us back"), "\(result.stdout)")
        // As the JSON event's `warnings` say, but once for the number rather than on every event.
        let warning = "! +1 (415) 555-0177 is on 2 contact cards: Jordan Lee (contact:jordan-lee) and"
        #expect(result.stderr.components(separatedBy: warning).count == 2, "\(result.stderr)")
    }
}
