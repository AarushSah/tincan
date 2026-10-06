import Foundation
import Testing

@testable import TincanKit

@Suite("Call history")
struct CallHistoryTests {
    // MARK: Outcomes and kinds

    @Test func outcomesFollowDirectionAnswerAndTalkTime() throws {
        let fixture = try CallHistoryFixture()
        let answered = try fixture.addCall(address: "+14155550142", at: .minute(1), answered: true, duration: 95)
        let missed = try fixture.addCall(address: "+14155550142", at: .minute(2))
        let connected = try fixture.addCall(address: "+14155550142", at: .minute(3), outgoing: true, duration: 12.5)
        let notConnected = try fixture.addCall(address: "+14155550142", at: .minute(4), outgoing: true, answered: true)

        let calls = Dictionary(uniqueKeysWithValues: try fixture.open().calls().map { ($0.id, $0) })
        #expect(calls[answered]?.outcome == .answered)
        #expect(calls[answered]?.direction == .incoming)
        #expect(calls[answered]?.duration == 95)
        #expect(calls[missed]?.outcome == .missed)
        #expect(calls[missed]?.isMissed == true)
        #expect(calls[connected]?.outcome == .connected)
        #expect(calls[connected]?.direction == .outgoing)
        // Apple records no reason for outgoing calls; without talk time they did not connect.
        #expect(calls[notConnected]?.outcome == .notConnected)
    }

    @Test(
        "Kinds come from the call type and provider",
        arguments: [
            (CallHistoryFixture.CallType.phone, "com.apple.Telephony" as String?, Call.Kind.phone),
            (.phone, nil, .phone),
            (.faceTimeVideo, "com.apple.FaceTime", .faceTimeVideo),
            (.faceTimeAudio, "com.apple.FaceTime", .faceTimeAudio),
            (.phone, "com.apple.FaceTime", .faceTimeAudio),
            (.phone, "net.whatsapp.WhatsApp", .app),
        ])
    func kinds(type: CallHistoryFixture.CallType, provider: String?, kind: Call.Kind) throws {
        let fixture = try CallHistoryFixture()
        try fixture.addCall(address: "+14155550142", at: .minute(1), type: type, provider: provider)
        let call = try #require(try fixture.open().calls().first)
        #expect(call.kind == kind)
        #expect(call.provider == (kind == .app ? provider : nil))
    }

    @Test func callFactsAreKept() throws {
        let fixture = try CallHistoryFixture()
        let id = try fixture.addCall(
            address: "+14155550142", at: .minute(1), location: "California", name: "Maya Ortiz",
            isRead: false, junkConfidence: 1
        )
        let call = try #require(try fixture.open().calls().first)
        #expect(call.id == id)
        #expect(call.reference == "call:\(id)")
        #expect(call.date == .minute(1))
        #expect(call.location == "California")
        #expect(call.recordedName == "Maya Ortiz")
        #expect(!call.isRead)
        #expect(call.isJunk)
        #expect(call.uniqueID != nil)
    }

    @Test func filteredCallsAreJunk() throws {
        let fixture = try CallHistoryFixture()
        try fixture.addCall(address: "+14155550199", at: .minute(1), filteredOutReason: 2)
        try fixture.addCall(address: "+14155550142", at: .minute(2))
        #expect(try fixture.open().calls().map(\.isJunk) == [false, true])
    }

    // MARK: Addresses

    @Test func nationalNumbersUseTheCallsCountry() throws {
        let fixture = try CallHistoryFixture()
        try fixture.addCall(address: "090-1234-5678", at: .minute(1), countryCode: "jp")
        try fixture.addCall(address: "020 7946 0000", at: .minute(2), countryCode: "gb")
        try fixture.addCall(address: "(415) 555-0142", at: .minute(3), countryCode: nil) // falls back to the region
        let calls = try fixture.open(region: "US").calls()
        #expect(calls.map(\.addresses) == [["+14155550142"], ["+442079460000"], ["+819012345678"]])
    }

    @Test func addressesThatAreNotPhoneNumbersStayAsTheyAre() throws {
        let fixture = try CallHistoryFixture()
        try fixture.addCall(address: "maya.ortiz@example.com", at: .minute(1), type: .faceTimeVideo, provider: "com.apple.FaceTime")
        try fixture.addCall(address: "12345", at: .minute(2), countryCode: "us")
        let calls = try fixture.open().calls()
        #expect(calls.map(\.addresses) == [["12345"], ["maya.ortiz@example.com"]])
    }

    @Test func groupCallsListEveryParticipant() throws {
        let fixture = try CallHistoryFixture()
        let maya = try fixture.addHandle(normalized: "+14155550142", value: "(415) 555-0142")
        let sam = try fixture.addHandle(normalized: "sam.lee@example.com", value: "Sam.Lee@example.com")
        // Without a normalized value, the raw value is normalized with the call's country.
        let kenji = try fixture.addHandle(normalized: nil, value: "090-1234-5678")
        try fixture.addCall(
            address: nil, at: .minute(1), answered: true, duration: 600, type: .faceTimeVideo,
            provider: "com.apple.FaceTime", countryCode: "jp", participants: [maya, sam, kenji]
        )
        let call = try #require(try fixture.open().calls().first)
        #expect(Set(call.addresses) == ["+14155550142", "sam.lee@example.com", "+819012345678"])
        #expect(call.addresses.count == 3)
    }

    @Test func participantHandlesTakePrecedenceOverTheAddressColumn() throws {
        let fixture = try CallHistoryFixture()
        let maya = try fixture.addHandle(normalized: "+14155550142", value: "+14155550142")
        try fixture.addCall(address: "maya.ortiz@example.com", at: .minute(1), participants: [maya])
        #expect(try fixture.open().calls().first?.addresses == ["+14155550142"])
    }

    // MARK: Filters

    /// Calls at minutes 1 to 6: Maya answered, Maya missed, Sam outgoing, Sam missed, a group
    /// call with both, and a missed call from Kenji in Japan.
    private func history() throws -> CallHistoryFixture {
        let fixture = try CallHistoryFixture()
        try fixture.addCall(address: "+14155550142", at: .minute(1), answered: true, duration: 30)
        try fixture.addCall(address: "+14155550142", at: .minute(2))
        try fixture.addCall(address: "+14155550143", at: .minute(3), outgoing: true, duration: 60)
        try fixture.addCall(address: "+14155550143", at: .minute(4))
        let maya = try fixture.addHandle(normalized: "+14155550142", value: "+14155550142")
        let sam = try fixture.addHandle(normalized: "+14155550143", value: "+14155550143")
        try fixture.addCall(
            address: nil, at: .minute(5), answered: true, duration: 90, type: .faceTimeAudio, provider: "com.apple.FaceTime", participants: [maya, sam])
        try fixture.addCall(address: "090-1234-5678", at: .minute(6), countryCode: "jp")
        return fixture
    }

    @Test func callsAreNewestFirst() throws {
        let fixture = try history()
        let calls = try fixture.open().calls()
        #expect(calls.map(\.date) == (1...6).reversed().map { Date.minute($0) })
    }

    @Test func missedOnlyKeepsUnansweredIncomingCalls() throws {
        let fixture = try history()
        let calls = try fixture.open().calls(missedOnly: true)
        #expect(calls.map(\.date) == [.minute(6), .minute(4), .minute(2)])
        #expect(calls.allSatisfy { $0.outcome == .missed })
    }

    @Test func sinceIsInclusiveAndBeforeIsExclusive() throws {
        let fixture = try history()
        let calls = try fixture.open().calls(since: .minute(2), before: .minute(5))
        #expect(calls.map(\.date) == [.minute(4), .minute(3), .minute(2)])
    }

    @Test func addressesMatchAfterNormalization() throws {
        let fixture = try history()
        let database = try fixture.open()
        let withMaya = try database.calls(addresses: ["(415) 555-0142"])
        #expect(withMaya.map(\.date) == [.minute(5), .minute(2), .minute(1)])
        let withKenji = try database.calls(addresses: ["+81 90-1234-5678"])
        #expect(withKenji.map(\.date) == [.minute(6)])
    }

    @Test func theLimitCountsMatchingCalls() throws {
        let fixture = try history()
        let database = try fixture.open()
        #expect(try database.calls(limit: 2).map(\.date) == [.minute(6), .minute(5)])
        #expect(try database.calls(addresses: ["+14155550143"], limit: 2).map(\.date) == [.minute(5), .minute(4)])
    }
}
