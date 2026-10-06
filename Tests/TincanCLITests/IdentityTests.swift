import Foundation
import Testing

/// Excluding a person covers conversations on their addresses that start later.
@Suite("Excluding a person by address")
struct ExcludedAddressTests {
    @Test func aNewConversationOnAnExcludedAddressIsHiddenEverywhere() throws {
        let messages = try MessagesFixture()
        let maya = try messages.addHandle("+14155550142")
        let old = try messages.addChat("iMessage;-;+14155550142", participants: [maya])
        try messages.addMessage("earlier today", in: old, from: .handle(maya), at: World.ago(hours: 5))
        let sam = try messages.addHandle("+14155550188")
        let withSam = try messages.addChat("iMessage;-;+14155550188", participants: [sam])
        try messages.addMessage("hi from Sam", in: withSam, from: .handle(sam), at: World.ago(hours: 4))
        let group = try messages.addChat("iMessage;+;chat100000009", displayName: "Dinner", participants: [maya, sam])
        try messages.addMessage("group plans", in: group, from: .handle(maya), at: World.ago(hours: 3))
        let environment = try World.environment(
            messages,
            contacts: """
                [{"id": "maya", "given_name": "Maya", "family_name": "Chen", "phones": ["(415) 555-0142"]},
                 {"id": "sam", "given_name": "Sam", "family_name": "Park", "phones": ["+14155550188"]}]
                """)
        func run(_ arguments: [String]) throws -> CLIResult { try CLI.run(arguments, environment: environment) }
        #expect(try run(["exclude", "add", "Maya", "--json"]).status == 0)
        let config = try String(contentsOfFile: environment["TINCAN_CONFIG"]!, encoding: .utf8)
        #expect(config.contains("\"address:+14155550142\""))

        let watching = try CLI.start(["watch", "--json", "--mine", "--interval", "0.2"], environment: environment)
        let deadline = Date().addingTimeInterval(10)
        while !watching.output.contains("\n"), Date() < deadline { usleep(20_000) }
        // Later, Maya starts a new conversation on the same number, then Sam writes.
        let mayaSMS = try messages.addHandle("+14155550142", service: "SMS")
        let new = try messages.addChat("any;-;+14155550142", service: "SMS", participants: [mayaSMS])
        try messages.addMessage("pineapple from a new thread", in: new, from: .handle(mayaSMS), at: Date()) {
            $0.isRead = false
            $0.service = "SMS"
        }
        try messages.addMessage("still here", in: withSam, from: .handle(sam), at: Date().addingTimeInterval(1))
        let seen = Date().addingTimeInterval(15)
        while !watching.output.contains("still here"), Date() < seen { usleep(20_000) }
        let watched = watching.stop()
        #expect(watched.stdout.contains("still here"))
        #expect(!watched.stdout.contains("pineapple"))

        let commands: [[String]] = [
            [], ["chats"], ["chats", "--all"], ["read", "chat:\(new)"], ["search", "new thread"], ["search", "e", "--limit", "500"],
            ["inbox"], ["inbox", "--after", "0", "--limit", "500"], ["inbox", "--since", "1d", "--mine"], ["who", "Maya"], ["who", "+14155550142"],
        ]
        for command in commands {
            for json in [false, true] {
                let result = try run(command + (json ? ["--json"] : []))
                #expect(!result.stdout.contains("pineapple"), "tincan \(command.joined(separator: " "))")
                #expect(!result.stderr.contains("pineapple"))
            }
        }
        #expect(try run(["read", "chat:\(new)", "--json"]).errorCode == "excluded")
        #expect(try run(["read", "Maya", "--json"]).errorCode == "excluded")
        let listed = try run(["chats", "--json"]).dataArray.first { $0["ref"] as? String == "chat:\(new)" }
        #expect(listed?["excluded"] as? Bool == true)
        let who = try run(["who", "Maya", "--json"]).dataObject
        #expect((who["conversations"] as? [[String: Any]] ?? []).compactMap { $0["ref"] as? String } == ["chat:\(group)"])
        for reference in ["Maya", "+14155550142", "chat:\(new)"] {
            #expect(try run(["send", reference, "hi", "--dry-run", "--json"]).errorCode == "excluded", "send \(reference)")
        }
        // Groups with her stay readable.
        #expect(try run(["read", "chat:\(group)"]).stdout.contains("group plans"))

        let list = try run(["exclude", "list", "--json"]).dataArray
        let entry = list.first { $0["ref"] as? String == "address:+14155550142" }
        #expect(entry?["name"] as? String == "Maya Chen")
        #expect(entry?["address"] as? String == "+14155550142")
        #expect(try run(["exclude", "list"]).stdout.contains("every one-to-one conversation at +1 (415) 555-0142"))
        #expect(try run(["exclude", "remove", "Maya", "--json"]).errorCode == "confirmation_required")
        #expect(try run(["exclude", "remove", "Maya", "--yes", "--json"]).dataArray.isEmpty)
        #expect(try run(["read", "chat:\(new)"]).stdout.contains("pineapple"))
    }

    /// "Exclude them from everything" must not read as done when their groups stay readable.
    @Test func excludingAPersonNamesTheGroupsThatStayReadable() throws {
        let world = try World()
        let result = try world.json(["exclude", "add", "Sam Park"])
        #expect(result.status == 0)
        let warning = try #require(((try result.json["warnings"] as? [[String: Any]]) ?? []).first { $0["code"] as? String == "groups_not_excluded" })
        let message = warning["message"] as? String ?? ""
        #expect(message.contains("Climbing crew 🧗 (\(world.chat("crew")))"))
        #expect(message.contains(world.chat("trip")))
        #expect(!message.contains("--yes"))
        // Reading them later says so too, with or without a one-to-one conversation on file.
        try world.run(["exclude", "add", "健二"])
        for person in ["Sam Park", "健二"] {
            let read = try world.json(["read", person])
            #expect(try read.errorCode == "excluded", "\(person)")
            #expect(try (read.error?["message"] as? String)?.contains("2 group conversations with them stay readable") == true, "\(person)")
        }
        try world.run(["exclude", "remove", "健二", "--yes"])
        // Only what this call added is marked; the list still holds every exclusion.
        #expect(try result.dataArray.allSatisfy { $0["added"] as? Bool == true })
        let next = try world.json(["exclude", "add", "Ava"])
        let entries = try next.dataArray
        #expect(entries.count == 4)
        #expect(
            entries.filter { $0["added"] as? Bool == true }.compactMap { $0["ref"] as? String }.sorted()
                == ["address:+14155550166", world.chat("ava")].sorted())
        #expect(try world.json(["exclude", "list"]).dataArray.allSatisfy { $0["added"] == nil })
    }

    /// A hand-edited `address:` entry that is no number or email keeps no one out, so the
    /// list never says it covers conversations.
    @Test func aMalformedAddressEntryIsListedAsExcludingNothing() throws {
        let world = try World()
        try (world.settings + "\n[privacy]\nexclude = [\"address:Maya Chen\"]\n").write(toFile: world.config, atomically: true, encoding: .utf8)
        let entry = try world.json(["exclude", "list"]).dataArray.first
        #expect(entry?["ref"] as? String == "address:Maya Chen")
        #expect(entry?["address"] == nil)
        #expect(entry?["name"] as? String == "Excludes nothing: not a number or email")
        #expect(try !world.run(["exclude", "list"]).stdout.contains("every one-to-one conversation"))
        #expect(try world.json(["exclude", "remove", "address:Maya Chen", "--yes"]).dataArray.isEmpty)
    }

    @Test func aPersonWithoutConversationsCanBeExcluded() throws {
        let world = try World()
        // Northwind Dental has a card and no conversation yet.
        let added = try world.run(["exclude", "add", "Northwind Dental"])
        #expect(added.status == 0)
        #expect(world.settings.contains("\"address:+14155550100\""))
        #expect(try world.json(["send", "Northwind Dental", "hi", "--dry-run"]).errorCode == "excluded")
        #expect(try world.json(["send", "+14155550100", "hi", "--dry-run"]).errorCode == "excluded")
        #expect(try world.json(["read", "Northwind Dental"]).errorCode == "excluded")
        #expect(try world.run(["exclude", "add", "Northwind Dental"]).stdout.contains("already excluded"))
        #expect(try world.json(["exclude", "remove", "address:+14155550100", "--yes"]).status == 0)
        #expect(try world.json(["send", "Northwind Dental", "hi", "--dry-run", "--typing", "paced"]).status == 0)
    }
}

@Suite("References in every command")
struct ReferenceTests {
    @Test func incompleteNumbersAreRefusedEverywhere() throws {
        let world = try World()
        let commands: [[String]] = [
            ["who", "555-0142"], ["read", "555-0142"], ["calls", "555-0142"], ["search", "dinner", "--in", "555-0142"],
            ["search", "dinner", "--from", "555-0142"], ["chats", "--with", "555-0142"], ["watch", "--in", "555-0142"],
            ["exclude", "add", "555-0142"],
        ]
        for command in commands {
            let result = try world.json(command)
            #expect(result.status == 3, "tincan \(command.joined(separator: " "))")
            #expect(try result.errorCode == "incomplete_number", "tincan \(command.joined(separator: " "))")
            // Maya's number ends with the digits: a candidate, never the choice.
            let candidates = try result.error?["candidates"] as? [[String: Any]] ?? []
            #expect(candidates.compactMap { $0["reference"] as? String } == ["+14155550142"], "tincan \(command.joined(separator: " "))")
        }
        let short = try world.json(["who", "0142"])
        #expect(try short.errorCode == "incomplete_number")
        #expect((try short.error?["message"] as? String)?.contains("too short") == true)
        let hint = try world.json(["who", "555-0142"]).error?["hint"] as? String ?? ""
        #expect(hint.contains("`tincan who <+number>`"), "\(hint)")
        #expect(!world.settings.contains("exclude = [\""))
    }

    @Test func meIsYouInEveryCommand() throws {
        let world = try World()
        let who = try world.json(["who", "me"])
        #expect(who.status == 0)
        let addresses = (try who.dataObject["addresses"] as? [[String: Any]] ?? []).compactMap { $0["address"] as? String }
        #expect(addresses == [World.ownAddress])
        #expect(try world.json(["calls", "me"]).status == 0)
    }

    @Test func whoMePointsEarlierCallsAtEveryOwnAddress() throws {
        // You send from two addresses; only one is on your card.
        let messages = try MessagesFixture()
        let maya = try messages.addHandle("+14155550142")
        let chat = try messages.addChat("iMessage;-;+14155550142", participants: [maya])
        for (index, own) in ["+14155550101", "+14155550102"].enumerated() {
            try messages.addMessage("from \(own)", in: chat, from: .meTo(maya), at: .minute(index)) { $0.destinationCallerID = own }
        }
        let calls = try CallHistoryFixture()
        for index in 0..<7 {
            try calls.addCall(address: index.isMultiple(of: 2) ? "+14155550102" : "+14155550101", at: .minute(100 + index), answered: true, duration: 60)
        }
        var environment = try World.environment(
            messages, contacts: #"[{"id": "you", "given_name": "Robin", "family_name": "Hale", "phones": ["+14155550101"]}]"#)
        environment["TINCAN_CALL_HISTORY_DB"] = calls.database.path
        let who = try CLI.run(["who", "me", "--json"], environment: environment)
        #expect(who.status == 0)
        let summary = try who.dataObject["calls"] as? [String: Any] ?? [:]
        #expect(summary["total"] as? Int == 7)
        let command = (summary["earlier"] as? [String: Any])?["command"] as? String ?? ""
        #expect(command.hasPrefix("tincan calls me --before "), "\(command)")
        // Following it finds the two calls the summary counted but didn't show.
        let arguments = Array(command.split(separator: " ").dropFirst().map(String.init))
        #expect(try CLI.run(arguments, environment: environment).dataArray.count == 2)
    }

    @Test func notFoundHintsQuoteWhatWasTyped() throws {
        let world = try World()
        let result = try world.json(["read", "x $(id)"])
        #expect(try result.errorCode == "not_found")
        #expect((try result.error?["hint"] as? String)?.contains("`tincan contacts 'x $(id)'`") == true)
    }
}

@Suite("Contact addresses")
struct ContactAddressTests {
    @Test func incompleteNumbersAndBadEmailsAreRefused() throws {
        let world = try World(writableContacts: true)
        for number in ["555-0142", "0142"] {
            let result = try world.json(["contacts", "add", "--name", "Test Person", "--phone", number, "--dry-run"])
            #expect(try result.errorCode == "incomplete_number", "\(number)")
            let edit = try world.json(["contacts", "edit", "Sam Park", "--add-phone", number, "--dry-run"])
            #expect(try edit.errorCode == "incomplete_number", "\(number)")
        }
        for email in ["bad@", "@example.com", "bad@example", "bad@example."] {
            let result = try world.json(["contacts", "add", "--name", "Test Person", "--email", email, "--dry-run"])
            #expect(try result.errorCode == "invalid_input", "\(email)")
        }
        #expect(try world.json(["contacts", "add", "--name", "Test Person", "--email", "test@example.com", "--dry-run"]).status == 0)
    }

    @Test func addingANumberOtherCardsHaveWarns() throws {
        let world = try World(writableContacts: true)
        let result = try world.json(["contacts", "edit", "Sam Park", "--add-phone", "+14155550142", "--dry-run"])
        #expect(result.status == 0)
        #expect(try result.warningCodes == ["shared_address"])
        let human = try world.run(["contacts", "edit", "Sam Park", "--add-phone", "+14155550142", "--dry-run"])
        #expect(human.stderr.contains("Maya Chen (contact:maya)"))
    }

    @Test func findMatchesNumbersEndingWithTheDigits() throws {
        let world = try World()
        let found = try world.json(["contacts", "find", "555-0142"]).dataArray.compactMap { $0["ref"] as? String }
        #expect(found == ["contact:maya"])
        // A number that names no line names no card either, as in every other command.
        let show = try world.json(["contacts", "show", "0142"])
        #expect(try show.errorCode == "incomplete_number")
        #expect(!(try show.error?["hint"] as? String ?? "").contains("contacts add"))
        let local = try world.json(["contacts", "show", "555-0109"])
        #expect(try local.errorCode == "incomplete_number")
        #expect((try local.error?["candidates"] as? [Any] ?? []).isEmpty)
    }
}
