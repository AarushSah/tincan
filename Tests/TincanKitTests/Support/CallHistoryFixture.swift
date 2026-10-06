import Foundation

@testable import TincanKit

/// Builds a temporary `CallHistory.storedata` with Apple's schema.
///
///     let fixture = try CallHistoryFixture()
///     try fixture.addCall(address: "+14155550142", at: .minute(1), answered: true, duration: 95)
///     let calls = try fixture.open().calls()
///
/// Ordinary calls keep the remote address in `ZCALLRECORD.ZADDRESS`, sometimes in national
/// format with `ZISO_COUNTRY_CODE` saying which country. Group FaceTime calls list their
/// participants through `ZHANDLE` and the `Z_2REMOTEPARTICIPANTHANDLES` join table.
final class CallHistoryFixture {
    /// `ZCALLRECORD.ZCALLTYPE`.
    enum CallType: Int {
        case phone = 1
        case faceTimeVideo = 8
        case faceTimeAudio = 16
    }

    let database: FixtureDatabase
    private var nextUniqueID = 1

    init() throws {
        database = try FixtureDatabase(fileName: "CallHistory.storedata", schema: Schemas.callHistoryTables + Schemas.callHistoryIndexes)
    }

    /// Opens the fixture read-only through tincan's own reader. `region` is the default
    /// country for numbers stored without one.
    func open(region: String? = "US") throws -> CallHistoryDatabase {
        try CallHistoryDatabase(path: database.path, region: region)
    }

    /// Adds a remote participant handle for group calls.
    @discardableResult
    func addHandle(normalized: String?, value: String?) throws -> Int64 {
        var values: [String: SQLiteValue] = ["Z_ENT": .integer(4), "Z_OPT": .integer(1), "ZTYPE": .integer(2)]
        values["ZNORMALIZEDVALUE"] = normalized.map { .text($0) }
        values["ZVALUE"] = value.map { .text($0) }
        return try database.insert(into: "ZHANDLE", values)
    }

    /// Adds a call. Incoming calls are missed unless `answered`; outgoing calls connected
    /// when `duration` is above zero. `countryCode` is lowercase, as the phone stores it.
    @discardableResult
    func addCall(
        address: String?,
        at date: Date,
        outgoing: Bool = false,
        answered: Bool = false,
        duration: TimeInterval = 0,
        type: CallType = .phone,
        provider: String? = "com.apple.Telephony",
        countryCode: String? = "us",
        location: String? = nil,
        name: String? = nil,
        isRead: Bool = true,
        junkConfidence: Int = 0,
        filteredOutReason: Int = 0,
        participants: [Int64] = []
    ) throws -> Int64 {
        let uniqueID = String(format: "CA11CA11-0000-4000-8000-%012ld", nextUniqueID)
        nextUniqueID += 1
        var values: [String: SQLiteValue] = [
            "Z_ENT": .integer(2),
            "Z_OPT": .integer(1),
            "ZDATE": .real(date.timeIntervalSinceReferenceDate),
            "ZDURATION": .real(duration),
            "ZORIGINATED": .integer(outgoing ? 1 : 0),
            "ZANSWERED": .integer(answered ? 1 : 0),
            "ZCALLTYPE": .integer(Int64(type.rawValue)),
            "ZREAD": .integer(isRead ? 1 : 0),
            "ZJUNKCONFIDENCE": .integer(Int64(junkConfidence)),
            "ZFILTERED_OUT_REASON": .integer(Int64(filteredOutReason)),
            "ZUNIQUE_ID": .text(uniqueID),
        ]
        values["ZADDRESS"] = address.map { .text($0) }
        values["ZSERVICE_PROVIDER"] = provider.map { .text($0) }
        values["ZISO_COUNTRY_CODE"] = countryCode.map { .text($0) }
        values["ZLOCATION"] = location.map { .text($0) }
        values["ZNAME"] = name.map { .text($0) }
        let callID = try database.insert(into: "ZCALLRECORD", values)
        for handle in participants {
            try database.insert(
                into: "Z_2REMOTEPARTICIPANTHANDLES",
                [
                    "Z_2REMOTEPARTICIPANTCALLS": .integer(callID),
                    "Z_4REMOTEPARTICIPANTHANDLES": .integer(handle),
                ])
        }
        return callID
    }
}
