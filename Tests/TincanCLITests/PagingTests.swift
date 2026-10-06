import Foundation
import Testing

@Suite("Paging with message cursors")
struct PagingTests {
    let world: World

    init() throws { world = try World() }

    @Test func searchPagesOlderMatchesWithNextCursor() throws {
        let first = try world.json(["search", "e", "--limit", "1"])
        #expect(first.status == 0)
        let next = try #require(try first.next)
        let cursor = try #require(next["cursor"] as? String)
        #expect(cursor.hasPrefix("m:"))
        #expect((next["command"] as? String)?.contains("--before \(cursor)") == true)
        let firstID = try first.dataArray.first.flatMap { ($0["message"] as? [String: Any])?["id"] as? Int }
        let second = try world.json(["search", "e", "--limit", "1", "--before", cursor])
        #expect(second.status == 0)
        let secondID = try second.dataArray.first.flatMap { ($0["message"] as? [String: Any])?["id"] as? Int }
        #expect(firstID != nil && secondID != nil && firstID != secondID)
    }

    @Test func unknownMessageCursorsAreRejected() throws {
        for arguments in [["read", "Maya", "--before", "m:999999"], ["search", "e", "--before", "m:999999"]] {
            let result = try world.json(arguments)
            #expect(result.status == 3)
            #expect(try result.errorCode == "unknown_message")
        }
    }
}

@Suite("Consistent page envelopes")
struct PageEnvelopeTests {
    @Test func listsReportWhetherAnotherPageExists() throws {
        let world = try World()
        for command in [["chats"], ["read", "Maya"], ["search", "e"], ["calls"]] {
            let first = try world.json(command + ["--limit", "1"])
            #expect(first.status == 0)
            #expect(try first.json["has_more"] as? Bool == true)
            #expect(try first.next?["command"] is String)
            let all = try world.json(command + ["--limit", "1000"])
            #expect(try all.json["has_more"] as? Bool == false)
            #expect(try all.next == nil)
        }
        let empty = try world.json(["search", "no fixture contains these words"])
        #expect(try empty.json["has_more"] as? Bool == false)
        #expect(try empty.next == nil)
        // Future-event continuations are not pages of existing results.
        #expect(try world.json(["inbox"]).json["has_more"] == nil)
    }

    @Test func readCanReturnToThePreviousPage() throws {
        let world = try World()
        let first = try world.json(["read", "Maya", "--limit", "3"])
        let next = try #require(try first.next?["command"] as? String)
        let second = try world.run(Array(Shell.split(next).dropFirst()))
        let later = try #require(try (second.dataObject["later"] as? [String: Any])?["command"] as? String)
        let back = try world.run(Array(Shell.split(later).dropFirst()))
        let originalIDs = try (first.dataObject["messages"] as? [[String: Any]])?.compactMap { $0["id"] as? Int }
        let returnedIDs = try (back.dataObject["messages"] as? [[String: Any]])?.compactMap { $0["id"] as? Int }
        #expect(originalIDs == returnedIDs)
        let window = try world.json(["read", "Maya", "--since", "2d"])
        #expect(try window.json["has_more"] as? Bool == false)
        #expect(try window.json["previous"] == nil)
        #expect(try window.dataObject["later"] == nil)
        #expect(try window.dataObject["earlier"] != nil)
    }

    @Test func chatPagesKeepFiltersAndIncludeTiedAndExcludedConversationsOnce() throws {
        let fixture = try MessagesFixture()
        let maya = try fixture.addHandle("+14155550142")
        for index in 1...6 {
            let chat = try fixture.addChat("iMessage;+;group\(index)", participants: [maya])
            try fixture.addMessage("Chat \(index)", in: chat, from: .handle(maya), at: .minute(1)) { $0.isRead = false }
        }
        let environment = try World.environment(fixture)
        let config = try #require(environment["TINCAN_CONFIG"])
        try "region = \"US\"\n[privacy]\nexclude = [\"chat:2\", \"chat:4\"]\n".write(toFile: config, atomically: true, encoding: .utf8)
        for filters in [[], ["--unread"], ["--with", "+14155550142"]] {
            let full = try CLI.run(["chats", "--json"] + filters, environment: environment)
            let excluded = try full.dataArray.filter { $0["excluded"] as? Bool == true }
            #expect(excluded.count == (filters.contains("--unread") || filters.contains("--with") ? 0 : 2))
            #expect(excluded.allSatisfy { $0["last_message"] == nil && $0["last_activity"] == nil })
            var arguments = ["chats", "--limit", "1", "--json"] + filters
            var seen: [String] = []
            for _ in 0..<10 {
                let page = try CLI.run(arguments, environment: environment)
                #expect(page.status == 0)
                seen += try page.dataArray.compactMap { $0["ref"] as? String }
                guard let command = try page.next?["command"] as? String else {
                    #expect(try page.json["has_more"] as? Bool == false)
                    break
                }
                arguments = Array(Shell.split(command).dropFirst())
            }
            #expect(seen == (try full.dataArray.compactMap { $0["ref"] as? String }))
            #expect(Set(seen).count == seen.count)
            #expect(!seen.isEmpty)
        }
    }

    @Test func badChatCursorsGiveActionableErrors() throws {
        let world = try World()
        for cursor in ["not-a-reference", "chat:999999", "chat:0", "chat:-1", world.chat("junk")] {
            let result = try world.json(["chats", "--before", cursor])
            #expect(result.status == 64)
            #expect(try result.errorCode == "invalid_input")
            #expect(try result.error?["hint"] is String)
        }
    }
}
