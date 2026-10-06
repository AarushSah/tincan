import Foundation

/// One call from the phone and FaceTime history this Mac syncs from your iPhone.
public struct Call: Sendable, Identifiable {
    public enum Direction: String, Sendable, Codable { case incoming, outgoing }

    /// What happened. Apple does not record why an outgoing call ended, so an outgoing call
    /// without talk time is `notConnected` (unanswered, busy or cancelled).
    public enum Outcome: String, Sendable, Codable {
        case answered
        case missed
        case connected
        case notConnected = "not_connected"
    }

    public enum Kind: String, Sendable, Codable {
        case phone
        case faceTimeAudio = "facetime_audio"
        case faceTimeVideo = "facetime_video"
        /// A call through another app that reports to the Phone app (WhatsApp, Zoom, …).
        case app
    }

    /// `ZCALLRECORD.Z_PK`, shown as `call:<id>`.
    public let id: Int64
    public let uniqueID: String?
    public let date: Date
    public let duration: TimeInterval
    public let direction: Direction
    public let outcome: Outcome
    public let kind: Kind
    /// Bundle id of the app for `.app` calls.
    public let provider: String?
    /// Remote addresses: one for ordinary calls, several for group FaceTime.
    public let addresses: [String]
    /// Region label such as "California", when known.
    public let location: String?
    /// The caller-ID name recorded at the time, if any.
    public let recordedName: String?
    public let isRead: Bool
    public let isJunk: Bool

    public var reference: String { "call:\(id)" }
    public var isMissed: Bool { outcome == .missed }
}

/// Read-only access to `CallHistory.storedata`.
public final class CallHistoryDatabase {
    public static var defaultPath: String {
        NSString(string: "~/Library/Application Support/CallHistoryDB/CallHistory.storedata").expandingTildeInPath
    }

    public let database: SQLiteDatabase
    private let region: String?
    private let columns: Set<String>

    public init(path: String = CallHistoryDatabase.defaultPath, region: String? = PhoneRegions.systemRegion) throws {
        database = try SQLiteDatabase(path: path)
        self.region = region
        // Read up front: a read that fails must fail, not pass for a schema without columns.
        columns = Set(try database.columns(of: "ZCALLRECORD"))
    }

    /// Calls newest first. `addresses`, when given, keeps calls involving any of them
    /// (compared after normalization).
    public func calls(since: Date? = nil, before: Date? = nil, missedOnly: Bool = false, addresses: Set<String>? = nil, limit: Int? = nil) throws -> [Call] {
        var conditions: [String] = []
        var bindings: [SQLiteValue] = []
        if let since {
            conditions.append("c.ZDATE >= ?")
            bindings.append(.real(AppleTime.callValue(since)))
        }
        if let before {
            conditions.append("c.ZDATE < ?")
            bindings.append(.real(AppleTime.callValue(before)))
        }
        if missedOnly { conditions.append("c.ZORIGINATED = 0 AND c.ZANSWERED = 0") }
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let participants = try participantAddresses()
        let wanted = addresses.map { Set($0.map { Address($0, region: region).value }) }

        func column(_ name: String, _ fallback: String = "NULL") -> String {
            columns.contains(name) ? "c.\(name)" : fallback
        }
        let sql = """
            SELECT c.Z_PK, \(column("ZUNIQUE_ID")), c.ZDATE, \(column("ZDURATION", "0")), \(column("ZORIGINATED", "0")),
                   \(column("ZANSWERED", "0")), \(column("ZCALLTYPE", "1")), \(column("ZSERVICE_PROVIDER")), \(column("ZADDRESS")),
                   \(column("ZISO_COUNTRY_CODE")), \(column("ZLOCATION")), \(column("ZNAME")), \(column("ZREAD", "1")),
                   \(column("ZJUNKCONFIDENCE", "0")), \(column("ZFILTERED_OUT_REASON", "0"))
            FROM ZCALLRECORD c \(whereClause) ORDER BY c.ZDATE DESC
            """
        var result: [Call] = []
        try database.forEach(sql, bindings) { row in
            let id = row.int64(0) ?? 0
            let country = row.nonEmptyString(9)?.uppercased() ?? region
            var addresses = participants[id] ?? []
            if addresses.isEmpty, let raw = row.nonEmptyString(8) {
                addresses = [Self.canonical(raw, region: country)]
            }
            if let wanted, !addresses.contains(where: { wanted.contains(Address($0, region: region).value) }) { return true }
            let duration = row.double(3) ?? 0
            let originated = row.bool(4)
            let answered = row.bool(5)
            let outcome: Call.Outcome
            if originated {
                outcome = duration > 0 ? .connected : .notConnected
            } else {
                outcome = answered ? .answered : .missed
            }
            let provider = row.nonEmptyString(7)
            let kind: Call.Kind
            switch (row.int(6) ?? 1, provider) {
            case (8, _): kind = .faceTimeVideo
            case (16, _): kind = .faceTimeAudio
            case (_, "com.apple.Telephony"), (_, nil): kind = .phone
            case (_, "com.apple.FaceTime"): kind = .faceTimeAudio
            default: kind = .app
            }
            result.append(
                Call(
                    id: id,
                    uniqueID: row.nonEmptyString(1),
                    date: AppleTime.callDate(row.double(2)) ?? Date(timeIntervalSinceReferenceDate: 0),
                    duration: duration,
                    direction: originated ? .outgoing : .incoming,
                    outcome: outcome,
                    kind: kind,
                    provider: kind == .app ? provider : nil,
                    addresses: addresses,
                    location: row.nonEmptyString(10),
                    recordedName: row.nonEmptyString(11),
                    isRead: row.bool(12),
                    isJunk: (row.int(13) ?? 0) > 0 || (row.int(14) ?? 0) > 0
                ))
            if let limit, result.count >= limit { return false }
            return true
        }
        return result
    }

    /// Remote participants per call from the handle tables, normalized to E.164 when possible.
    private func participantAddresses() throws -> [Int64: [String]] {
        guard database.hasTable("Z_2REMOTEPARTICIPANTHANDLES"), database.hasTable("ZHANDLE") else { return [:] }
        let joinColumns = try database.columns(of: "Z_2REMOTEPARTICIPANTHANDLES")
        guard let callColumn = joinColumns.first(where: { $0.hasSuffix("REMOTEPARTICIPANTCALLS") }),
            let handleColumn = joinColumns.first(where: { $0.hasSuffix("REMOTEPARTICIPANTHANDLES") })
        else { return [:] }
        let hasCountry = columns.contains("ZISO_COUNTRY_CODE")
        var result: [Int64: [String]] = [:]
        try database.forEach(
            """
            SELECT j.\(callColumn), h.ZNORMALIZEDVALUE, h.ZVALUE, \(hasCountry ? "c.ZISO_COUNTRY_CODE" : "NULL")
            FROM Z_2REMOTEPARTICIPANTHANDLES j
            JOIN ZHANDLE h ON h.Z_PK = j.\(handleColumn)
            JOIN ZCALLRECORD c ON c.Z_PK = j.\(callColumn)
            """
        ) { row in
            guard let callID = row.int64(0) else { return true }
            let country = row.nonEmptyString(3)?.uppercased() ?? region
            let value = row.nonEmptyString(1) ?? row.nonEmptyString(2).map { Self.canonical($0, region: country) }
            if let value, result[callID]?.contains(value) != true { result[callID, default: []].append(value) }
            return true
        }
        return result
    }

    /// E.164 for numbers stored in national format, using the call's country.
    static func canonical(_ raw: String, region: String?) -> String {
        let address = Address(raw, region: region)
        return address.kind == .phone && address.phone?.isE164 == true ? address.value : raw
    }
}
