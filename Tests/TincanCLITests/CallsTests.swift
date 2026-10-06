import Foundation
import Testing

@Suite("Calls")
struct CallsTests {
    let world: World

    init() throws { world = try World() }

    func name(_ call: [String: Any]) -> String {
        ((call["with"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }.joined(separator: ", ")
    }

    @Test func missedCallsSayHowTheyWereReturned() throws {
        let result = try world.json(["calls", "--missed"])
        #expect(result.status == 0)
        let calls = try result.dataArray
        #expect(calls.allSatisfy { $0["outcome"] as? String == "missed" })
        let byName = Dictionary(calls.map { (name($0), $0) }, uniquingKeysWith: { first, _ in first })
        #expect((byName["Maya Chen"]?["returned"] as? [String: Any])?["via"] as? String == "call")
        #expect((byName["Sam Park"]?["returned"] as? [String: Any])?["via"] as? String == "message")
        #expect(byName["+1 (415) 555-0122"]?["returned"] == nil)
        #expect(byName["Northwind Dental"]?["returned"] == nil)
        #expect(calls.contains { $0["junk"] as? Bool == true })
        // A hidden or unknown number says so, instead of an empty list alone.
        let unknown = calls.filter { ($0["with"] as? [Any])?.isEmpty == true }
        #expect(unknown.count == 1)
        #expect(unknown.allSatisfy { $0["caller"] as? String == "unknown" && $0["returned"] == nil })
        #expect(calls.filter { $0["caller"] != nil }.count == unknown.count)
        try JSONShape.expect(result.json, matches: "calls")

        let human = try world.run(["calls", "--missed"])
        #expect(human.stdout.contains("called back in 5m"))
        #expect(human.stdout.contains("texted back in 1h 4m"))
        #expect(human.stdout.contains("not returned"))
        #expect(human.stdout.contains("Unknown caller"))
    }

    @Test func callsPageWithTimeCursors() throws {
        let everything = try world.json(["calls", "--limit", "500"]).dataArray.compactMap { $0["id"] as? Int }
        let first = try world.json(["calls"])
        #expect(try first.dataArray.count == 25)
        let next = try #require(try first.next)
        let command = next["command"] as? String ?? ""
        #expect(command.contains("--before \(next["cursor"] as? String ?? "?")"))
        let second = try world.json(Array(Shell.split(command).dropFirst().filter { $0 != "--json" }))
        #expect(second.status == 0)
        #expect(try second.next == nil)
        let ids = try first.dataArray.compactMap { $0["id"] as? Int } + second.dataArray.compactMap { $0["id"] as? Int }
        #expect(ids == everything)
    }

    /// `who` shows five calls; the rest are one command away, without building a cursor.
    @Test func whoSaysHowToReadTheRestOfTheCalls() throws {
        let summary = try #require(try world.json(["who", "+14155550177"]).dataObject["calls"] as? [String: Any])
        #expect(summary["total"] as? Int == 24)
        let recent = (summary["recent"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? Int }
        let earlier = try #require(summary["earlier"] as? [String: Any])
        let command = earlier["command"] as? String ?? ""
        #expect(command.hasPrefix("tincan calls +14155550177 --before "))
        let rest = try world.json(Array(Shell.split(command).dropFirst().filter { $0 != "--json" }) + ["--limit", "50"])
        #expect(rest.status == 0)
        let ids = recent + (try rest.dataArray.compactMap { $0["id"] as? Int })
        #expect(ids.count == 24)
        #expect(Set(ids).count == 24)
        // Nothing more, nothing to follow.
        let few = try #require(try world.json(["who", "Maya"]).dataObject["calls"] as? [String: Any])
        #expect(few["earlier"] == nil)
    }

    @Test func callsWithAPersonOrTheirGroup() throws {
        let maya = try world.json(["calls", "Maya"]).dataArray
        #expect(maya.count == 3)
        #expect(maya.allSatisfy { name($0).contains("Maya Chen") })
        let crew = try world.json(["calls", world.chat("crew")]).dataArray
        #expect(Set(crew.map(name)) == ["Maya Chen", "Maya Chen, Sam Park", "Sam Park", "健二 佐藤"])
    }

    @Test func aOneToOneChatMeansThePersonBehindIt() throws {
        func ids(_ arguments: [String]) throws -> [Int] {
            try world.json(["calls", "--limit", "500"] + arguments).dataArray.compactMap { $0["id"] as? Int }
        }
        // Maya's email thread finds the calls on her number, as her email does.
        let mail = try ids([world.chat("mayaMail")])
        #expect(mail.count == 3)
        #expect(try mail == ids(["maya@example.com"]))
        #expect(try mail == ids(["Maya"]))
        // A number on two cards names nobody: the conversation's own address, with a warning.
        let lee = try world.json(["calls", world.chat("lee"), "--limit", "500"])
        #expect(try lee.dataArray.count == 24)
        #expect(try lee.dataArray.compactMap { $0["id"] as? Int } == ids(["+14155550177"]))
        #expect(try lee.warningCodes.contains("shared_address"))
    }

    @Test func aLimitedListSaysMoreExist() throws {
        let limited = try world.json(["calls", "--limit", "2"])
        #expect(try limited.warningCodes == ["truncated"])
        #expect(try limited.next != nil)
        let missed = try world.json(["calls", "--missed", "--limit", "1"])
        let warning = try ((missed.json["warnings"] as? [[String: Any]]) ?? []).first
        #expect(warning?["message"] as? String == "Showing 1 missed call; more exist. `next.command` continues, or narrow the query.")
        #expect(try world.json(["calls", "--limit", "500"]).warningCodes.isEmpty)
        // Human output says so with the command for earlier calls instead.
        let human = try world.run(["calls", "--limit", "2"], columns: 200)
        #expect(human.stderr.contains("Earlier: tincan calls --before"))
        #expect(!human.stdout.contains("Earlier:"))
        // The same command as JSON's, which keeps the page size, without --json.
        let command = try #require(try world.json(["calls", "--limit", "2"]).next?["command"] as? String)
        #expect(human.stderr.contains("Earlier: " + command.replacingOccurrences(of: " --json", with: "") + "\n"))
        #expect(!human.stderr.contains("more exist"))
    }

    @Test func homeListsUnreturnedMissedCallsWithoutJunk() throws {
        let result = try world.json([])
        #expect(result.status == 0)
        let data = try result.dataObject
        #expect(data["setup_needed"] as? Bool == false)
        let missed = data["missed_calls"] as? [[String: Any]] ?? []
        #expect(Set(missed.map(name)) == ["", "+1 (415) 555-0122", "Northwind Dental"])
        #expect(missed.contains { $0["caller"] as? String == "unknown" })
        #expect(missed.allSatisfy { $0["returned"] == nil && $0["junk"] == nil })
        let unread = (data["unread"] as? [[String: Any]] ?? []).compactMap { $0["ref"] as? String }
        #expect(Set(unread) == Set(["crew", "stranger", "rivera", "mayaMail"].map(world.chat)))
        #expect(data["unread_conversations"] as? Int == 4)
        #expect(data["unread_messages"] as? Int == 4)
        #expect(try result.warningCodes.isEmpty)
        try JSONShape.expect(result.json, matches: "home")
    }

    @Test func homeCountsEveryUnreadConversationNotOnlyTheFiveListed() throws {
        let messages = try MessagesFixture()
        // Seven conversations with unread messages: one, two, … seven of them.
        for index in 1...7 {
            let handle = try messages.addHandle("+1415555016\(index)")
            let chat = try messages.addChat("iMessage;-;+1415555016\(index)", participants: [handle])
            for count in 1...index {
                try messages.addMessage("message \(count)", in: chat, from: .handle(handle), at: World.ago(hours: Double(8 - index), minutes: Double(count))) {
                    $0.isRead = false
                }
            }
        }
        let environment = try World.environment(messages)
        let result = try CLI.run(["--json"], environment: environment)
        #expect(result.status == 0)
        let data = try result.dataObject
        #expect((data["unread"] as? [Any])?.count == 5)
        #expect(data["unread_conversations"] as? Int == 7)
        #expect(data["unread_messages"] as? Int == 28)
        let warning = try #require(((try result.json["warnings"] as? [[String: Any]]) ?? []).first { $0["code"] as? String == "truncated" })
        #expect((warning["message"] as? String)?.contains("5 of 7 unread conversations") == true)
        let human = try CLI.run([], environment: environment.merging(["COLUMNS": "100"]) { $1 })
        #expect(human.stdout.contains("28 messages in 7 conversations"))
        #expect(human.stdout.contains("… and 2 more: tincan chats --unread"))
        #expect(!human.stderr.contains("Showing"))
    }
}

@Suite("Calls on a long history")
struct LongCallHistoryTests {
    /// 1,800 calls with 600 missed from 150 people, 400 conversations and 150 contacts.
    @Test func followUpsStayFast() throws {
        let messages = try MessagesFixture()
        let calls = try CallHistoryFixture()
        var contacts: [String] = []
        for person in 0..<400 {
            let number = String(format: "+1415555%04d", 1000 + person)
            let handle = try messages.addHandle(number)
            let chat = try messages.addChat("iMessage;-;\(number)", participants: [handle])
            try messages.addMessage("hello \(person)", in: chat, from: .handle(handle), at: .minute(person))
            if person % 3 == 0 {
                try messages.addMessage("sorry I missed you", in: chat, from: .meTo(handle), at: .minute(10_000 + person))
            }
            if person < 150 {
                contacts.append(#"{"id": "p\#(person)", "given_name": "Person", "family_name": "\#(person)", "phones": ["\#(number)"]}"#)
            }
        }
        for index in 0..<1_800 {
            let number = String(format: "+1415555%04d", 1000 + index % 150)
            try calls.addCall(address: number, at: .minute(index * 5), outgoing: index % 3 == 1, answered: index % 3 == 2, duration: index % 3 == 0 ? 0 : 60)
        }
        let directory = messages.database.directory
        let contactsFile = directory.appendingPathComponent("contacts.json")
        try ("[" + contacts.joined(separator: ",\n") + "]").write(to: contactsFile, atomically: true, encoding: .utf8)
        let config = directory.appendingPathComponent("config.toml")
        try "region = \"US\"\n".write(to: config, atomically: true, encoding: .utf8)
        let environment = [
            "TINCAN_MESSAGES_DB": messages.path, "TINCAN_CALL_HISTORY_DB": calls.database.path,
            "TINCAN_CONTACTS_FILE": contactsFile.path, "TINCAN_CONFIG": config.path,
        ]
        let started = Date()
        let result = try CLI.run(["calls", "--limit", "2000", "--json"], environment: environment)
        let elapsed = Date().timeIntervalSince(started)
        #expect(result.status == 0)
        let returned = try result.dataArray.filter { $0["returned"] != nil }
        #expect(returned.count > 100)
        #expect(elapsed < 3, "calls took \(elapsed)s")
    }

    @Test func unreadableSettingsStopCallsAndContacts() throws {
        let world = try World(settings: "[send]\nwpm = 400\n")
        // Without a person too: never a fallback to the Mac's region with a misleading warning.
        for arguments in [["calls", "--limit", "1"], ["calls", "Maya"], ["contacts", "Maya"], ["contacts", "show", "Maya"]] {
            let result = try world.json(arguments)
            #expect(result.status == 1, "tincan \(arguments.joined(separator: " "))")
            #expect(try result.errorCode == "invalid_config", "tincan \(arguments.joined(separator: " "))")
            #expect(try (result.json["warnings"] as? [Any])?.isEmpty ?? true, "tincan \(arguments.joined(separator: " "))")
        }
    }
}
