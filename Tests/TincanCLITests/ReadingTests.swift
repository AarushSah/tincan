import Foundation
import Testing

@testable import TincanCLI

@Suite("Reading: chats, read, who and search")
struct ReadingTests {
    let world: World

    init() throws { world = try World() }

    // MARK: chats

    @Test func chatsListsConversationsNewestFirst() throws {
        let result = try world.json(["chats"])
        #expect(result.status == 0)
        let chats = try result.dataArray
        #expect(chats.first?["ref"] as? String == world.chat("crew"))
        #expect(chats.contains { $0["ref"] as? String == world.chat("maya") })
        // Unknown senders and junk stay hidden without --all.
        #expect(!chats.contains { $0["ref"] as? String == world.chat("junk") })
        let all = try world.json(["chats", "--all", "--limit", "50"]).dataArray
        #expect(all.contains { $0["ref"] as? String == world.chat("junk") && $0["filtered"] as? Bool == true })
        try JSONShape.expect(result.json, matches: "chats")
    }

    @Test func junkNamedDirectlySaysWhereMessagesFiledIt() throws {
        let junk = world.chat("junk")
        let read = try world.json(["read", junk])
        #expect(try read.warningCodes == ["filtered_conversation"])
        #expect((try read.dataObject["conversation"] as? [String: Any])?["filtered"] as? Bool == true)
        let who = try world.json(["who", "+14155550123"])
        #expect(try who.warningCodes.contains("filtered_conversation"))
        let conversations = try who.dataObject["conversations"] as? [[String: Any]] ?? []
        #expect(conversations.first { $0["ref"] as? String == junk }?["filtered"] as? Bool == true)
        let send = try world.json(["send", junk, "stop", "--dry-run", "--typing", "paced"])
        #expect(send.status == 0)
        #expect(try send.warningCodes == ["filtered_conversation"])
        #expect(try send.dataObject["filtered"] as? Bool == true)
        let warning = try (send.json["warnings"] as? [[String: Any]])?.first?["message"] as? String ?? ""
        #expect(warning.hasPrefix("Messages filed this conversation under Unknown Senders or Junk."))
        // Ordinary conversations say nothing of the sort.
        let maya = try world.json(["read", world.chat("maya")])
        #expect(try !maya.warningCodes.contains("filtered_conversation"))
        #expect((try maya.dataObject["conversation"] as? [String: Any])?["filtered"] == nil)
    }

    @Test func chatsFiltersUnreadAndByPerson() throws {
        let unread = try world.json(["chats", "--unread"]).dataArray.compactMap { $0["ref"] as? String }
        #expect(Set(unread) == Set(["crew", "stranger", "rivera", "mayaMail"].map(world.chat)))
        let withMaya = try world.json(["chats", "--with", "Maya"]).dataArray.compactMap { $0["ref"] as? String }
        #expect(Set(withMaya) == Set(["maya", "mayaText", "mayaMail", "crew"].map(world.chat)))
    }

    @Test func chatsSaysWhenMoreExist() throws {
        let result = try world.json(["chats", "--limit", "2"])
        #expect(try result.dataArray.count == 2)
        #expect(try result.warningCodes == ["truncated"])
        #expect(try result.json["has_more"] as? Bool == true)
        let cursor = try #require(try result.next?["cursor"] as? String)
        let human = try world.run(["chats", "--limit", "2"])
        #expect(human.stderr == "More: tincan chats --before \(cursor) --limit 2\n")
        #expect(!human.stdout.contains("More:"))
        #expect(!human.stderr.contains("Showing"))
        let filtered = try world.json(["chats", "--limit", "1", "--with", "Maya Chen"])
        let next = try #require(try filtered.next?["command"] as? String)
        #expect(next.contains("--with 'Maya Chen'"))
        let more = try world.run(Array(Shell.split(next).dropFirst()))
        #expect(more.status == 0)
        #expect(try more.dataArray.count == 1)
        #expect(try more.dataArray.first?["ref"] as? String != filtered.dataArray.first?["ref"] as? String)
        let unread = try world.json(["chats", "--limit", "1", "--unread", "--all"])
        #expect(try (unread.next?["command"] as? String)?.contains("--unread --all") == true)
    }

    // MARK: read

    @Test func aSinceWindowPointsToOlderMessagesWithoutLoadingThem() throws {
        // The whole window fits: `earlier` points before it, without --since, and `next`
        // stays empty, so following `next` never walks past the window.
        let fits = try world.json(["read", "Maya", "--since", "2d"])
        let data = try fits.dataObject
        let messages = data["messages"] as? [[String: Any]] ?? []
        let oldest = try #require(messages.first?["ref"] as? String)
        #expect(try fits.json["has_more"] as? Bool == false)
        #expect(try fits.json["next"] == nil)
        let earlier = try #require(data["earlier"] as? [String: Any])
        #expect(earlier["cursor"] as? String == oldest)
        #expect(earlier["command"] as? String == "tincan read contact:maya --before \(oldest) --limit 40 --json")
        let before = try world.json(["read", "contact:maya", "--before", oldest]).dataObject["messages"] as? [[String: Any]] ?? []
        #expect(!before.isEmpty)
        let human = try world.run(["read", "Maya", "--since", "2d"])
        #expect(human.stderr.contains("Earlier: tincan read Maya --before \(oldest)\n"))

        // Within the window, paging keeps --since; `next` continues there.
        let page = try world.json(["read", "Maya", "--since", "2d", "--limit", "1"])
        let pageEarlier = try page.dataObject["earlier"] as? [String: Any]
        #expect((pageEarlier?["command"] as? String)?.hasSuffix("--limit 1 --since 2d --json") == true)
        #expect(try (page.json["next"] as? [String: Any])?["command"] as? String == pageEarlier?["command"] as? String)
        #expect(try world.run(["read", "Maya", "--since", "2d", "--limit", "1"]).stderr.contains("--limit 1 --since 2d"))

        // An empty window points before its start.
        let empty = try world.json(["read", "Maya", "--since", "1m"])
        #expect(try (empty.dataObject["messages"] as? [Any])?.isEmpty == true)
        #expect(try empty.json["next"] == nil)
        let emptyEarlier = try #require(try empty.dataObject["earlier"] as? [String: Any])
        let start = try #require(emptyEarlier["cursor"] as? String)
        #expect(emptyEarlier["command"] as? String == "tincan read contact:maya --before \(start) --limit 40 --json")
        #expect(try !((world.json(["read", "contact:maya", "--before", start]).dataObject["messages"] as? [Any]) ?? []).isEmpty)
        let emptyHuman = try world.run(["read", "Maya", "--since", "1m"])
        #expect(emptyHuman.stdout.contains("No messages in this range.") && emptyHuman.stderr.contains("Earlier: tincan read Maya --before "))

        // Nothing older than the window: no pointer.
        let whole = try world.json(["read", "Maya", "--since", "52w"]).dataObject
        #expect(whole["earlier"] == nil)
        #expect(try !world.run(["read", "Maya", "--since", "52w"]).stdout.contains("Earlier:"))
    }

    @Test func readMergesAPersonsThreadsAcrossServices() throws {
        let result = try world.json(["read", "Maya", "--limit", "200"])
        #expect(result.status == 0)
        let data = try result.dataObject
        let conversation = data["conversation"] as? [String: Any]
        #expect(Set(conversation?["chats"] as? [String] ?? []) == Set(["maya", "mayaText", "mayaMail"].map(world.chat)))
        #expect(conversation?["current_services"] as? [String] == ["imessage", "sms"])
        #expect(conversation?["services"] == nil)
        #expect((conversation?["person"] as? [String: Any])?["contact"] as? String == "contact:maya")
        let messages = data["messages"] as? [[String: Any]] ?? []
        // Messages from several threads say which one they're in.
        #expect(Set(messages.compactMap { $0["chat"] as? String }).count == 3)
        let dates = messages.compactMap { $0["at"] as? String }
        #expect(dates == dates.sorted() || dates.count < 2)
        #expect(try result.json["has_more"] as? Bool == false)
        #expect(data["has_more"] == nil)
        #expect(data["truncated"] == nil)
        #expect(messages.allSatisfy { $0["ref"] as? String == "m:\($0["id"] as? Int ?? -1)" })
        try JSONShape.expect(result.json, matches: "read")
    }

    @Test func readPagesBackwardsWithMessageCursors() throws {
        let everything = try world.json(["read", "Maya", "--limit", "500"]).dataObject["messages"] as? [[String: Any]] ?? []
        var arguments = ["read", "Maya", "--limit", "7"]
        var seen: [Int] = []
        var pages = 0
        while pages < 20 {
            let result = try world.json(arguments)
            #expect(result.status == 0)
            let data = try result.dataObject
            let messages = data["messages"] as? [[String: Any]] ?? []
            seen = messages.compactMap { $0["id"] as? Int } + seen
            pages += 1
            guard let next = try result.next else {
                #expect(try result.json["has_more"] as? Bool == false)
                #expect(data["earlier"] == nil)
                break
            }
            #expect(try result.json["has_more"] as? Bool == true)
            #expect((data["earlier"] as? [String: Any])?["command"] as? String == next["command"] as? String)
            // Every page but the first has newer messages to go back to.
            #expect((data["later"] != nil) == (pages > 1))
            let cursor = next["cursor"] as? String ?? ""
            #expect(cursor == "m:\(messages.first?["id"] as? Int ?? -1)")
            let command = next["command"] as? String ?? ""
            #expect(command.hasPrefix("tincan read contact:maya --before \(cursor) --limit 7"))
            arguments = Array(Shell.split(command).dropFirst().filter { $0 != "--json" })
        }
        #expect(pages > 2)
        #expect(Set(seen).count == seen.count)
        #expect(seen == everything.compactMap { $0["id"] as? Int })
    }

    @Test func readPagesForwardFromAMessage() throws {
        let everything = try world.json(["read", "Maya", "--limit", "500"]).dataObject["messages"] as? [[String: Any]] ?? []
        let ids = everything.compactMap { $0["id"] as? Int }
        #expect(ids.count > 20)
        var arguments = ["read", "Maya", "--after", "m:\(ids[2])", "--limit", "7"]
        var seen: [Int] = []
        var pages = 0
        while pages < 20 {
            let result = try world.json(arguments)
            #expect(result.status == 0)
            let data = try result.dataObject
            seen += (data["messages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? Int }
            pages += 1
            // Earlier messages exist behind every page read forward.
            #expect((data["earlier"] as? [String: Any])?["cursor"] as? String == "m:\(seen[seen.count - ((data["messages"] as? [Any])?.count ?? 0)])")
            guard let next = try result.next else {
                #expect(try result.json["has_more"] as? Bool == false)
                #expect(data["later"] == nil)
                break
            }
            #expect(try result.json["has_more"] as? Bool == true)
            let cursor = next["cursor"] as? String ?? ""
            #expect(cursor == "m:\(seen.last ?? -1)")
            let command = next["command"] as? String ?? ""
            #expect(command == "tincan read contact:maya --after \(cursor) --limit 7 --json")
            #expect((data["later"] as? [String: Any])?["command"] as? String == command)
            arguments = Array(Shell.split(command).dropFirst().filter { $0 != "--json" })
        }
        #expect(pages > 2)
        #expect(seen == Array(ids.dropFirst(3)))
    }

    @Test func readShowsAMessageInContext() throws {
        let everything = try world.json(["read", "Maya", "--limit", "500"]).dataObject["messages"] as? [[String: Any]] ?? []
        let ids = everything.compactMap { $0["id"] as? Int }
        let center = ids[10]
        for reference in ["m:\(center)", String(center)] {
            let result = try world.json(["read", "Maya", "--around", reference, "--limit", "5"])
            #expect(result.status == 0)
            let data = try result.dataObject
            #expect((data["messages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? Int } == Array(ids[8...12]))
            #expect((data["earlier"] as? [String: Any])?["cursor"] as? String == "m:\(ids[8])")
            #expect((data["later"] as? [String: Any])?["cursor"] as? String == "m:\(ids[12])")
            // Reading on from a search result goes forward.
            #expect(try result.next?["command"] as? String == "tincan read contact:maya --after m:\(ids[12]) --limit 5 --json")
            #expect(try result.json["has_more"] as? Bool == true)
            if reference.hasPrefix("m:") { try JSONShape.expect(result.json, matches: "read-around") }
        }
        // At either end of the conversation, the other side fills the page.
        let first = try world.json(["read", "Maya", "--around", "m:\(ids[0])", "--limit", "5"]).dataObject
        #expect((first["messages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? Int } == Array(ids[0...4]))
        #expect(first["earlier"] == nil)
        #expect((first["later"] as? [String: Any])?["cursor"] as? String == "m:\(ids[4])")
        let last = try world.json(["read", "Maya", "--around", "m:\(ids[ids.count - 1])", "--limit", "3"]).dataObject
        #expect((last["messages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? Int } == Array(ids.suffix(3)))
        #expect(last["later"] == nil)
        let three = try world.json(["read", "Maya", "--around", "m:\(center)", "--limit", "3"]).dataObject
        #expect((three["messages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? Int } == Array(ids[9...11]))
        // The commands for more keep the page size and references.
        let human = try world.run(["read", "Maya", "--around", "m:\(center)", "--limit", "5", "--ids"], columns: 120)
        #expect(human.stderr.contains("Earlier: tincan read Maya --before m:\(ids[8]) --limit 5 --ids"))
        #expect(human.stderr.contains("Later: tincan read Maya --after m:\(ids[12]) --limit 5 --ids"))
        // Only the conversation reaches stdout, without the blank lines around it.
        #expect(!human.stdout.contains("Earlier:") && !human.stdout.contains("Later:"))
        #expect(!human.stdout.hasSuffix("\n\n"))
        let plain = try world.run(["read", "Maya", "--around", "m:\(center)", "--limit", "5"], columns: 120).stderr
        #expect(plain.contains("Earlier: tincan read Maya --before m:\(ids[8]) --limit 5\n"))
    }

    @Test func aroundNeedsAMessageInTheConversation() throws {
        let elsewhere = world.rows.groupReactionTarget.rowID
        let result = try world.json(["read", "Maya", "--around", "m:\(elsewhere)"])
        #expect(result.status == 3)
        #expect(try result.errorCode == "unknown_message")
        #expect(try (result.error?["hint"] as? String)?.contains("tincan read \(world.chat("crew")) --around m:\(elsewhere)") == true)
    }

    @Test func aReactionIsNotAMessageToReadAround() throws {
        let love = world.rows.mayaLove!
        let target = "m:\(world.rows.mayaYes.rowID)"
        for reference in ["m:\(love.rowID)", String(love.rowID), love.guid] {
            for option in ["--around", "--after", "--before"] {
                let result = try world.json(["read", "Maya", option, reference])
                #expect(result.status == 3, "\(option) \(reference)")
                #expect(try result.errorCode == "unknown_message")
                #expect(try (result.error?["message"] as? String) == "\(reference) is a reaction, not a message.")
                #expect(try (result.error?["hint"] as? String)?.contains("`target`: pass \(option) \(target).") == true)
                #expect(try (result.error?["hint"] as? String)?.contains("`tincan read Maya \(option) \(target)`") == true)
            }
        }
        // Search pages from messages too.
        let search = try world.json(["search", "filler", "--before", "m:\(love.rowID)"])
        #expect(search.status == 3)
        #expect(try search.errorCode == "unknown_message")
    }

    @Test func repliesNameTheMessageTheyQuote() throws {
        let messages = try world.json(["read", "Maya", "--limit", "500"]).dataObject["messages"] as? [[String: Any]] ?? []
        let reply = try #require(messages.first { $0["text"] as? String == "Perfect, booked it" })
        #expect(reply["reply_to"] as? String == world.rows.mayaFirst.guid)
        #expect(reply["reply_to_ref"] as? String == "m:\(world.rows.mayaFirst.rowID)")
        #expect(messages.filter { $0["reply_to_ref"] != nil }.count == 1)
    }

    @Test func messageOptionsTakeAGUID() throws {
        let first = world.rows.mayaFirst!
        let yes = world.rows.mayaYes!
        for (option, row) in [("--around", first), ("--after", first), ("--before", yes)] {
            let byGUID = try world.json(["read", "Maya", option, row.guid, "--limit", "3"])
            #expect(byGUID.status == 0, "\(option) \(row.guid)")
            #expect(try byGUID.stdout == world.json(["read", "Maya", option, "m:\(row.rowID)", "--limit", "3"]).stdout)
        }
        // One that names no message fails like an unknown m:<id>.
        for option in ["--around", "--after", "--before"] {
            let result = try world.json(["read", "Maya", option, "0B9F3E52-1C44-4B8A-9E0D-7A61C2F5D301"])
            #expect(result.status == 3)
            #expect(try result.errorCode == "unknown_message")
        }
        // A message in another conversation is still refused.
        let elsewhere = try world.json(["read", "Maya", "--around", world.rows.groupReactionTarget.guid])
        #expect(try elsewhere.errorCode == "unknown_message")
        #expect(try (elsewhere.error?["hint"] as? String)?.contains("--around m:\(world.rows.groupReactionTarget.rowID)") == true)
        // --before still takes times.
        #expect(try world.json(["read", "Maya", "--before", "2h"]).status == 0)
        #expect(try world.json(["read", "Maya", "--before", "soon"]).errorCode == "invalid_input")
    }

    @Test func messageReferencesMayBeBareNumbers() throws {
        let everything = try world.json(["read", "Maya", "--limit", "500"]).dataObject["messages"] as? [[String: Any]] ?? []
        let id = try #require(everything.compactMap { $0["id"] as? Int }.dropFirst(5).first)
        for option in ["--before", "--after"] {
            let prefixed = try world.json(["read", "Maya", option, "m:\(id)", "--limit", "3"])
            let bare = try world.json(["read", "Maya", option, String(id), "--limit", "3"])
            #expect(prefixed.status == 0)
            #expect(prefixed.stdout == bare.stdout)
        }
        let search = try world.json(["search", "filler", "--before", String(id)])
        #expect(search.status == 0)
        #expect(try search.stdout == world.json(["search", "filler", "--before", "m:\(id)"]).stdout)
    }

    @Test func readRejectsConflictingOrUnknownAnchors() throws {
        for arguments in [["--after", "m:3", "--before", "m:9"], ["--around", "m:3", "--since", "2h"], ["--after", "m:3", "--since", "2h"]] {
            let result = try world.json(["read", "Maya"] + arguments)
            #expect(result.status == 64)
            #expect(try result.errorCode == "invalid_input")
        }
        for option in ["--before", "--after", "--around"] {
            let result = try world.json(["read", "Maya", option, "m:999999"])
            #expect(result.status == 3)
            #expect(try result.errorCode == "unknown_message")
        }
        // A time is for --since; --after starts from a message.
        let time = try world.json(["read", "Maya", "--after", "yesterday"])
        #expect(time.status == 64)
        #expect(try time.errorCode == "invalid_input")
        #expect(try (time.error?["hint"] as? String)?.contains("--since") == true)
    }

    @Test func readRejectsABadCursor() throws {
        let result = try world.json(["read", "Maya", "--before", "m:abc"])
        #expect(result.status == 64)
        #expect(try result.errorCode == "invalid_input")
        #expect(try (result.error?["hint"] as? String)?.contains("m:<id>") == true)
    }

    @Test func readShowsAGroupWithItsEvents() throws {
        let data = try world.json(["read", "Climbing crew"]).dataObject
        #expect((data["conversation"] as? [String: Any])?["kind"] as? String == "group")
        let messages = data["messages"] as? [[String: Any]] ?? []
        #expect(messages.contains { ($0["event"] as? [String: Any])?["kind"] as? String == "renamed" })
        #expect(messages.contains { ($0["reactions"] as? [[String: Any]])?.first?["reaction"] as? String == "laugh" })
    }

    @Test func readWithoutAOneToOneConversationSaysWhere() throws {
        let result = try world.json(["read", "佐藤"])
        #expect(result.status == 3)
        #expect(try result.errorCode == "no_conversation")
        #expect(try result.error?["hint"] as? String == "They are in 2 groups: run `tincan chats --with contact:kenji`.")
    }

    // MARK: who

    @Test func whoConnectsAPersonToAddressesConversationsAndCalls() throws {
        let result = try world.json(["who", "Maya"])
        let data = try result.dataObject
        let addresses = data["addresses"] as? [[String: Any]] ?? []
        #expect(addresses.map { $0["address"] as? String } == ["+14155550142", "maya@example.com"])
        #expect(addresses.first?["services"] as? [String] == ["imessage", "sms"])
        let conversations = (data["conversations"] as? [[String: Any]] ?? []).compactMap { $0["ref"] as? String }
        #expect(Set(conversations) == Set(["maya", "mayaText", "mayaMail", "crew"].map(world.chat)))
        let calls = data["calls"] as? [String: Any]
        #expect(calls?["missed"] as? Int == 1)
        let recent = calls?["recent"] as? [[String: Any]] ?? []
        let missed = recent.first { $0["outcome"] as? String == "missed" }
        #expect((missed?["returned"] as? [String: Any])?["via"] as? String == "call")
        // Newest first, and no separate copy of the newest call.
        let times = recent.compactMap { $0["at"] as? String }
        #expect(times == times.sorted(by: >))
        #expect(calls?["last"] == nil)
        let human = try world.run(["who", "Maya"])
        #expect(human.stdout.contains("iMessage · SMS"))
        try JSONShape.expect(result.json, matches: "who-person")
    }

    @Test func whoWarnsWhenANumberIsOnSeveralCards() throws {
        let result = try world.json(["who", "+14155550177"])
        #expect(try result.warningCodes.contains("shared_address"))
        let shared = try result.dataObject["shared_with"] as? [[String: Any]] ?? []
        #expect(Set(shared.compactMap { $0["contact"] as? String }) == ["contact:jordan-lee", "contact:riley-lee"])
        let human = try world.run(["who", "+14155550177"])
        #expect(human.stdout.contains("On 2 contact cards: Jordan Lee, Riley Lee"))
        #expect(human.stderr.hasPrefix("! "))
    }

    @Test func whoListsAGroupsPeople() throws {
        let result = try world.json(["who", world.chat("crew")])
        let people = try result.dataObject["participants"] as? [[String: Any]] ?? []
        #expect(people.compactMap { $0["name"] as? String } == ["Maya Chen", "Sam Park", "健二 佐藤"])
        try JSONShape.expect(result.json, matches: "who-group")
    }

    // MARK: search

    @Test func searchFindsTextNewestFirst() throws {
        let result = try world.json(["search", "THE"])
        let matches = try result.dataArray
        #expect(matches.count >= 4)
        let dates = matches.compactMap { ($0["message"] as? [String: Any])?["at"] as? String }
        #expect(dates == dates.sorted(by: >))
        #expect(matches.allSatisfy { ($0["message"] as? [String: Any])?["ref"] as? String == "m:\(($0["message"] as? [String: Any])?["id"] as? Int ?? -1)" })
        try JSONShape.expect(result.json, matches: "search")
    }

    @Test func searchTreatsCurlyAndStraightApostrophesAlike() throws {
        for query in ["wie geht’s", "WIE GEHT'S"] {
            let texts = try world.json(["search", query]).dataArray.compactMap { ($0["message"] as? [String: Any])?["text"] as? String }
            #expect(texts == ["Guten Tag! Wie geht's?"], "\(query)")
        }
        // The window around a long message's match finds it the same way.
        let long = String(repeating: "filler ", count: 30) + "Wie geht’s dir?"
        #expect(Search.window(long, around: "geht's", width: 40).contains("geht’s"))
    }

    @Test func searchNarrowsByConversationAndSender() throws {
        let inMaya = try world.json(["search", "filler", "--in", "Maya"]).dataArray
        #expect(inMaya.count == 16)
        let mine = try world.json(["search", "filler", "--from", "me"]).dataArray
        #expect(mine.count == 8)
        #expect(mine.allSatisfy { ($0["message"] as? [String: Any])?["from"] as? String == "me" })
        let fromMaya = try world.json(["search", "filler", "--from", "Maya", "--limit", "3"])
        #expect(try fromMaya.dataArray.count == 3)
        #expect(try fromMaya.warningCodes == ["truncated"])
        let fromGroup = try world.json(["search", "x", "--from", world.chat("crew")])
        #expect(fromGroup.status == 64)
        #expect(try fromGroup.errorCode == "invalid_input")
    }

    @Test func pagingHintsForPeopleMatchTheJSONCommands() throws {
        let world = try World()
        let json = try world.json(["read", "Maya", "--since", "30d", "--limit", "2"]).dataObject
        let command = try #require((json["earlier"] as? [String: Any])?["command"] as? String)
        #expect(command.contains(" --since 30d"))
        // The same command, with the reference people typed and without --json.
        let human = try world.run(["read", "Maya", "--since", "30d", "--limit", "2"], columns: 200).stderr
        let expected = command.replacingOccurrences(of: "tincan read contact:maya ", with: "tincan read Maya ").replacingOccurrences(of: " --json", with: "")
        #expect(human.contains("Earlier: " + expected + "\n"))
    }
}
