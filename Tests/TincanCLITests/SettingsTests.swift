import Foundation
import Testing
import TincanKit

@Suite("Settings and exclusions")
struct SettingsTests {
    // MARK: config

    @Test func configShowsSetsAndResets() throws {
        let world = try World()
        let shown = try world.json(["config"])
        #expect(try shown.json["command"] as? String == "config show")
        let values = try shown.dataObject
        #expect(values["region"] as? String == "US")
        #expect(values["send_wpm"] as? Int == 80)
        #expect(values["send_typing"] as? String == "auto")
        try JSONShape.expect(shown.json, matches: "config")

        #expect(try world.json(["config", "set", "send.wpm", "55"]).status == 0)
        #expect(try world.json(["config", "set", "send.typing", "paced"]).status == 0)
        #expect(try world.json(["config", "set", "region", "gb"]).dataObject["region"] as? String == "GB")
        #expect(world.settings.contains("wpm = 55"))
        #expect(world.settings.contains("typing = \"paced\""))

        let unknown = try world.json(["config", "set", "colour", "blue"])
        #expect(unknown.status == 64)
        #expect(try unknown.errorCode == "invalid_input")
        #expect(try world.json(["config", "set", "send.wpm", "1000"]).status == 64)
        #expect(try world.json(["config", "set", "region", "XX"]).status == 64)

        try world.run(["exclude", "add", world.chat("lee")])
        let reset = try world.json(["config", "reset"]).dataObject
        #expect(reset["send_wpm"] as? Int == 80)
        #expect((reset["excluded"] as? [String])?.count == 1)
        let all = try world.json(["config", "reset", "--all", "--yes"]).dataObject
        #expect((all["excluded"] as? [String])?.isEmpty == true)
    }

    @Test func aBrokenSettingsFileIsReported() throws {
        let world = try World(settings: "send.wpm = fast\n")
        let result = try world.json(["chats"])
        #expect(result.status == 1)
        #expect(try result.errorCode == "invalid_config")
        #expect(try (result.error?["hint"] as? String)?.contains("tincan config reset --all") == true)
        // Resetting keeps exclusions, so it can't go ahead when they can't be read...
        let reset = try world.json(["config", "reset"])
        #expect(reset.status == 1)
        #expect(try reset.errorCode == "invalid_config")
        #expect(world.settings == "send.wpm = fast\n")
        // ...unless the person asks to start over, which clears whatever exclusions it held.
        let unconfirmed = try world.json(["config", "reset", "--all"])
        #expect(try unconfirmed.errorCode == "confirmation_required")
        #expect(world.settings == "send.wpm = fast\n")
        #expect(try world.json(["config", "reset", "--all", "--yes"]).status == 0)
        #expect(try world.json(["chats"]).status == 0)
    }

    @Test func tomlOutsideTheSubsetNamesWhatIsUnsupported() throws {
        let world = try World(settings: "[send]\nwpm = { value = 42 }\n")
        let result = try world.json(["chats"])
        #expect(result.status == 1)
        #expect(try result.errorCode == "invalid_config")
        let message = try result.error?["message"] as? String ?? ""
        #expect(message.contains("on line 2: inline tables aren't supported"), "\(message)")
        #expect(message.contains("tincan's settings file supports only a subset of TOML"), "\(message)")
        let hint = try result.error?["hint"] as? String ?? ""
        #expect(hint.contains(TOMLLite.subset), "\(hint)")
        // Doctor fails its Settings check with the same explanation.
        let checks = try world.json(["doctor"]).dataObject["checks"] as? [[String: Any]] ?? []
        let settings = checks.first { $0["id"] as? String == "config" }
        #expect(settings?["status"] as? String == "fail")
        #expect((settings?["detail"] as? String)?.contains("inline tables aren't supported") == true)
    }

    @Test func aSettingsFileThatIsNotWhereTheOverrideSaysStopsEverything() throws {
        let world = try World(settings: "region = \"US\"\n[privacy]\nexclude = [\"iMessage;-;+16285550131\"]\n")
        let missing = world.directory.appendingPathComponent("moved/config.toml").path
        let elsewhere = ["TINCAN_CONFIG": missing]
        for command in [["chats"], ["read", "Sam Rivera"], ["search", "pineapple"], ["inbox", "--after", "0"], ["config"], ["exclude", "list"]] {
            let result = try world.json(command, environment: elsewhere)
            #expect(result.status == 1, "tincan \(command.joined(separator: " "))")
            #expect(try result.errorCode == "config_missing", "tincan \(command.joined(separator: " "))")
            for secret in Self.secrets { #expect(!result.stdout.contains(secret)) }
        }
        let error = try #require(try world.json(["chats"], environment: elsewhere).error)
        #expect((error["message"] as? String)?.contains("TINCAN_CONFIG points at") == true)
        #expect((error["hint"] as? String)?.contains("unset TINCAN_CONFIG") == true)
        // Nothing writes new settings in their place, which would have no exclusions.
        for command in [
            ["config", "set", "region", "GB"], ["config", "reset"], ["config", "reset", "--all", "--yes"], ["exclude", "add", world.chat("lee")],
        ] {
            #expect(try world.json(command, environment: elsewhere).errorCode == "config_missing", "tincan \(command.joined(separator: " "))")
        }
        #expect(!FileManager.default.fileExists(atPath: missing))
        // Where it looks is still easy to find.
        #expect(try world.json(["config", "path"], environment: elsewhere).dataObject["path"] as? String == missing)
    }

    // MARK: exclude

    @Test func exclusionsAreStoredByChatGUID() throws {
        let world = try World()
        let added = try world.json(["exclude", "add", world.chat("rivera")])
        #expect(added.status == 0)
        #expect(world.settings.contains("exclude = [\"iMessage;-;+16285550131\"]"))
        let list = try world.json(["exclude", "list"])
        #expect(try list.dataArray.map { $0["ref"] as? String } == [world.chat("rivera")])
        #expect(try list.dataArray.first?["name"] as? String == "Sam Rivera")
        try JSONShape.expect(list.json, matches: "exclude-list")

        let again = try world.json(["exclude", "add", "Sam Rivera"])
        #expect(again.status == 0)
        #expect(try world.run(["exclude", "add", "Sam Rivera"]).stdout.contains("already excluded"))

        // References are parsed the same everywhere: case and padding don't matter.
        let shouted = " " + world.chat("rivera").replacingOccurrences(of: "chat:", with: "Chat:") + " "
        let removed = try world.json(["exclude", "remove", shouted, "--yes"])
        #expect(removed.status == 0)
        #expect(try removed.dataArray.isEmpty)
        #expect(world.settings.contains("exclude = []"))
        let notExcluded = try world.json(["exclude", "remove", world.chat("rivera"), "--yes"])
        #expect(notExcluded.status == 64)
        #expect(try notExcluded.errorCode == "invalid_input")
    }

    @Test func liftingExclusionsNeedsThePersonsApproval() throws {
        let world = try World()
        try world.run(["exclude", "add", "Sam Rivera"])
        try world.run(["exclude", "add", world.chat("lee")])
        let before = world.settings
        // Without a terminal, or with --json, nothing changes without --yes.
        for command in [["exclude", "remove", world.chat("rivera")], ["exclude", "remove", "Sam Rivera"], ["config", "reset", "--all"]] {
            for json in [false, true] {
                let result = try world.run(command + (json ? ["--json"] : []))
                #expect(result.status == 3, "tincan \(command.joined(separator: " "))")
                if json {
                    #expect(try result.errorCode == "confirmation_required")
                    let hint = try result.error?["hint"] as? String ?? ""
                    #expect(hint.contains("Only add --yes after they ask"), "\(hint)")
                } else {
                    #expect(result.stderr.contains("needs --yes"))
                }
                #expect(world.settings == before)
            }
        }
        // In a terminal it asks, and no is the default.
        let declined = try world.runInTerminal(["exclude", "remove", world.chat("rivera")], answer: "")
        #expect(declined.status == 0)
        // Letting the conversation back in lifts the exclusion of its number, which covers it.
        #expect(
            declined.stdout.contains(
                "Let tincan read and send to Sam Rivera (\(world.chat("rivera"))) and every one-to-one conversation at +1 (628) 555-0131 again?"))
        #expect(declined.stdout.contains("Nothing was changed."))
        #expect(world.settings == before)
        let approved = try world.runInTerminal(["exclude", "remove", world.chat("rivera")], answer: "y")
        #expect(approved.status == 0)
        #expect(approved.stdout.contains("No longer excluded"))
        #expect(try world.json(["exclude", "list"]).dataArray.compactMap { $0["ref"] as? String } == [world.chat("lee")])
        let reset = try world.runInTerminal(["config", "reset", "--all"], answer: "n")
        #expect(reset.stdout.contains("clear 1 excluded conversation?"))
        #expect(try world.json(["exclude", "list"]).dataArray.count == 1)
        #expect(try world.runInTerminal(["config", "reset", "--all"], answer: "yes").status == 0)
        #expect(try world.json(["exclude", "list"]).dataArray.isEmpty)
    }

    @Test func excludingAPersonCoversEachOfTheirThreads() throws {
        let world = try World()
        #expect(try world.json(["exclude", "add", "Maya"]).status == 0)
        let refs = try world.json(["exclude", "list"]).dataArray.compactMap { $0["ref"] as? String }
        #expect(Set(refs) == Set(["maya", "mayaText", "mayaMail"].map(world.chat) + ["address:+14155550142", "address:maya@example.com"]))
        #expect(try world.json(["exclude", "remove", "Maya", "--yes"]).status == 0)
        #expect(try world.json(["exclude", "list"]).dataArray.isEmpty)
    }

    /// Sam Rivera's conversation holds the only mentions of these words.
    static let secrets = ["pineapple", "secret plans"]

    @Test func excludedContentAppearsNowhere() throws {
        let world = try World()
        try world.run(["exclude", "add", "Sam Rivera"])
        let commands: [[String]] = [
            [], ["chats"], ["chats", "--unread"], ["chats", "--all", "--limit", "50"], ["read", "Sam Rivera"], ["read", world.chat("rivera")],
            ["search", "word is"], ["search", "plans for"], ["search", "e", "--limit", "500"], ["inbox"],
            ["inbox", "--since", "3d", "--mine", "--limit", "500"],
            ["inbox", "--after", "0", "--limit", "500"], ["who", "Sam Rivera"], ["who", "+16285550131"],
        ]
        for command in commands {
            for json in [false, true] {
                let result = try world.run(command + (json ? ["--json"] : []))
                for secret in Self.secrets {
                    #expect(!result.stdout.contains(secret), "tincan \(command.joined(separator: " ")) printed \(secret)")
                    #expect(!result.stderr.contains(secret))
                }
            }
        }
        let rivera = world.chat("rivera")
        // Listed so you know it exists, without content or unread counts.
        let listed = try world.json(["chats", "--limit", "50"]).dataArray.first { $0["ref"] as? String == rivera }
        #expect(listed?["excluded"] as? Bool == true)
        #expect(listed?["last_message"] == nil)
        #expect(listed?["unread"] == nil)
        #expect(!(try world.json(["chats", "--unread"]).dataArray.contains { $0["ref"] as? String == rivera }))
        #expect(!(try world.json([]).dataObject["unread"] as? [[String: Any]] ?? []).contains { $0["ref"] as? String == rivera })
        let inbox = try world.json(["inbox", "--after", "0", "--limit", "500", "--mine"]).dataObject
        #expect(!(inbox["conversations"] as? [[String: Any]] ?? []).contains { $0["chat"] as? String == rivera })
        #expect(!(inbox["reactions"] as? [[String: Any]] ?? []).contains { $0["chat"] as? String == rivera })

        for reference in ["Sam Rivera", rivera, "+16285550131"] {
            let read = try world.json(["read", reference])
            #expect(read.status == 3)
            #expect(try read.errorCode == "excluded")
        }
        let who = try world.json(["who", "Sam Rivera"])
        #expect(try who.warningCodes.contains("excluded_conversations"))
        #expect(try (who.dataObject["conversations"] as? [Any])?.isEmpty == true)
    }

    @Test func commandsScopedToAnExcludedPersonSayWhyNothingIsThere() throws {
        let world = try World()
        try world.run(["exclude", "add", "Sam Rivera"])
        // An empty answer must never read as "they never said it".
        let commands: [[String]] = [
            ["search", "secret", "--in", "Sam Rivera"], ["search", "secret", "--from", "Sam Rivera"],
            ["search", "secret", "--from", "+16285550131"], ["chats", "--with", "Sam Rivera"],
        ]
        for command in commands {
            let result = try world.json(command)
            #expect(result.status == 0, "tincan \(command.joined(separator: " "))")
            #expect(try result.dataArray.isEmpty)
            #expect(try result.warningCodes == ["excluded_conversations"], "tincan \(command.joined(separator: " "))")
            #expect(try world.run(command).stderr.contains("1 conversation with Sam Rivera is excluded"))
        }
        for scope in [["--in", "Sam Rivera"], ["--from", "Sam Rivera"]] {
            let running = try CLI.start(["watch", "--json", "--after", "0", "--interval", "0.2"] + scope, environment: world.environment)
            let deadline = Date().addingTimeInterval(10)
            while !running.output.contains("\n"), Date() < deadline { usleep(20_000) }
            let ready = try #require(try running.stop().jsonLines.first)
            #expect(ready["type"] as? String == "ready")
            let warnings = (ready["warnings"] as? [[String: Any]]) ?? []
            #expect(warnings.compactMap { $0["code"] as? String } == ["excluded_conversations"])
            #expect((warnings.first?["message"] as? String)?.hasSuffix("excluded and not watched.") == true)
        }
        // Someone with nothing excluded gets no such warning.
        #expect(try world.json(["search", "dinner", "--in", "Maya"]).warningCodes.isEmpty)
        #expect(try world.json(["chats", "--with", "Maya"]).warningCodes.isEmpty)
    }

    @Test func excludedContentStaysOutOfWatch() throws {
        let world = try World()
        try world.run(["exclude", "add", "Sam Rivera"])
        let running = try CLI.start(["watch", "--json", "--after", "0", "--mine", "--interval", "0.2"], environment: world.environment)
        usleep(1_500_000)
        let result = running.stop()
        #expect(result.stdout.contains("\"type\":\"message\""))
        for secret in Self.secrets { #expect(!result.stdout.contains(secret)) }
        #expect(!result.stdout.contains("\"chat\":\"\(world.chat("rivera"))\""))
    }

    @Test func anAddressFromTheExclusionListCanBeExcluded() throws {
        let world = try World()
        // `exclude list` shows address:<address>; `exclude add` takes it, in any format.
        let added = try world.json(["exclude", "add", "address:+14155550199"])
        #expect(added.status == 0)
        #expect(world.settings.contains("\"address:+14155550199\""))
        let listed = try world.json(["exclude", "list"]).dataArray.compactMap { $0["ref"] as? String }
        #expect(listed.contains("address:+14155550199"))
        #expect(try world.json(["exclude", "add", "address:(415) 555-0199"]).status == 0)
        #expect(world.settings.components(separatedBy: "address:+14155550199").count == 2)
        #expect(try world.json(["exclude", "add", "address:555-0199"]).errorCode == "incomplete_number")
        let notAnAddress = try world.json(["exclude", "add", "address:Maya"])
        #expect(try notAnAddress.errorCode == "not_found")
        // The hint says how to write one, not a search for the whole reference.
        #expect(try (notAnAddress.error?["hint"] as? String)?.contains("address:<+number>") == true)
    }

    @Test func anAddressIsExcludedAloneNotWithTheRestOfItsCard() throws {
        let world = try World()
        // Maya's card also has maya@example.com; only her number is excluded.
        let added = try world.json(["exclude", "add", "address:+14155550142"])
        #expect(added.status == 0)
        let refs = try added.dataArray.compactMap { $0["ref"] as? String }
        #expect(refs == ["address:+14155550142"])
        #expect(!world.settings.contains("maya@example.com"))
        let chats = try (world.json(["read", "Maya Chen"]).dataObject["conversation"] as? [String: Any])?["chats"] as? [String]
        #expect(chats == [world.chat("mayaMail")])
        // `exclude remove` of the same entry undoes it entirely.
        #expect(try world.json(["exclude", "remove", "address:+14155550142", "--yes"]).dataArray.isEmpty)
        #expect(!world.settings.contains("exclude = [\""))
        // A person by name still takes every address on their card.
        try world.run(["exclude", "add", "Maya Chen"])
        #expect(world.settings.contains("\"address:maya@example.com\""))
        #expect(world.settings.contains("\"address:+14155550142\""))
    }

    @Test func aCandidateSaysItsConversationsAreExcludedWithoutTheirActivity() throws {
        let world = try World()
        try world.run(["exclude", "add", "Sam Rivera"])
        let result = try world.json(["who", "Sam"])
        #expect(try result.errorCode == "ambiguous")
        let candidates = try result.error?["candidates"] as? [[String: Any]] ?? []
        let rivera = try #require(candidates.first { $0["reference"] as? String == "contact:sam-rivera" })
        #expect(rivera["conversations"] as? Int == 0)
        #expect(rivera["excluded_conversations"] as? Int == 1)
        #expect(rivera["last_activity"] == nil)
        let detail = rivera["detail"] as? String ?? ""
        #expect(detail.hasSuffix("1 excluded conversation"), "\(detail)")
        #expect(!detail.contains("no conversations"))
        let park = try #require(candidates.first { $0["reference"] as? String == "contact:sam-park" })
        #expect(park["excluded_conversations"] == nil)
    }

    @Test func anEntryThatExcludesNothingIsNotCountedAsAnAddress() throws {
        let world = try World(settings: "region = \"US\"\n\n[privacy]\nexclude = [\"address:Maya Chen\", \"address:+14155550199\"]\n")
        let values = try world.json(["config"]).dataObject
        #expect(values["excluded_addresses"] as? Int == 1)
        #expect(values["excluded_conversations"] as? Int == 0)
        #expect(values["excluded_nothing"] as? Int == 1)
        #expect(try world.run(["config"]).stdout.contains("1 address, and 1 entry that excludes nothing"))
        let checks = try world.json(["doctor"]).dataObject["checks"] as? [[String: Any]] ?? []
        let settings = checks.first { $0["id"] as? String == "config" }?["detail"] as? String
        #expect(settings?.contains("excluded: 1 address, and 1 entry that excludes nothing") == true, "\(settings ?? "")")
        // Nothing to mention when every entry excludes something.
        let clean = try World(settings: "region = \"US\"\n\n[privacy]\nexclude = [\"address:+14155550199\"]\n")
        #expect(try clean.json(["config"]).dataObject["excluded_nothing"] == nil)
    }

    @Test func exclusionsAreCountedAsConversationsAndAddresses() throws {
        let world = try World()
        try world.run(["exclude", "add", "Sam Rivera"])
        let values = try world.json(["config"]).dataObject
        #expect((values["excluded"] as? [String])?.count == 2)
        #expect(values["excluded_conversations"] as? Int == 1)
        #expect(values["excluded_addresses"] as? Int == 1)
        #expect(try world.run(["config"]).stdout.contains("1 conversation and 1 address"))
        let checks = try world.json(["doctor"]).dataObject["checks"] as? [[String: Any]] ?? []
        let settings = checks.first { $0["id"] as? String == "config" }?["detail"] as? String
        #expect(settings?.contains("excluded: 1 conversation and 1 address") == true)
    }
}
