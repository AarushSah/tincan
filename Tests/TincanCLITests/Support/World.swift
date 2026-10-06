import Foundation
import TincanKit

/// An invented person's Messages, call history, Contacts and settings, written to a
/// temporary directory so the real `tincan` binary can run against them.
///
/// Everything is made up: names such as Maya Chen, numbers in the 555-01xx range and
/// example.com emails. Times are relative to when the world is built, so `--since 2h`,
/// `today` and the home screen's last seven days all have something to find.
///
/// The databases are built once per test process and never change; each `World` gets its
/// own settings file, so tests that exclude conversations or change settings stay isolated.
final class World {
    /// The shared, read-only data.
    struct Data {
        let messages: String
        let calls: String
        let contacts: String
        let directory: URL
        let rows: Rows
    }

    /// Row ids and GUIDs tests refer to.
    struct Rows {
        var mayaFirst: MessagesFixture.Row!
        var mayaYes: MessagesFixture.Row!
        /// Maya's ❤️ on `mayaYes`: a reaction, not a message.
        var mayaLove: MessagesFixture.Row!
        var mayaLatest: MessagesFixture.Row!
        var secret: MessagesFixture.Row!
        var groupReactionTarget: MessagesFixture.Row!
        var chats: [String: Int64] = [:]
    }

    static let shared: Data = {
        do { return try build() } catch { fatalError("Could not build the fixture world: \(error)") }
    }()

    let data: Data
    let config: String
    /// This world's contacts file: the shared one, or a copy that commands may change.
    let contacts: String
    let directory: URL

    /// A world with its own settings file (region US unless `settings` says otherwise).
    /// `contacts` replaces the address book with other JSON, in a file of this world's own;
    /// `writableContacts` gives it a copy of the usual one to add and edit.
    init(settings: String = "region = \"US\"\n", contacts: String? = nil, writableContacts: Bool = false) throws {
        data = Self.shared
        directory = data.directory.appendingPathComponent("world-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        config = directory.appendingPathComponent("config.toml").path
        try settings.write(toFile: config, atomically: true, encoding: .utf8)
        if contacts != nil || writableContacts {
            let path = directory.appendingPathComponent("contacts.json").path
            try (contacts ?? Self.contactsJSON).write(toFile: path, atomically: true, encoding: .utf8)
            self.contacts = path
        } else {
            self.contacts = data.contacts
        }
    }

    var rows: Rows { data.rows }

    /// The environment that points tincan at this world.
    var environment: [String: String] {
        [
            "TINCAN_MESSAGES_DB": data.messages,
            "TINCAN_CALL_HISTORY_DB": data.calls,
            "TINCAN_CONTACTS_FILE": contacts,
            "TINCAN_CONFIG": config,
        ]
    }

    /// The settings file as it is now.
    var settings: String { (try? String(contentsOfFile: config, encoding: .utf8)) ?? "" }

    func chat(_ name: String) -> String { "chat:\(rows.chats[name]!)" }

    /// Runs tincan in this world.
    @discardableResult
    func run(_ arguments: [String], columns: Int = 100, environment extra: [String: String] = [:], stdin: String? = nil) throws -> CLIResult {
        try CLI.run(arguments, environment: environment.merging(["COLUMNS": String(columns)]) { $1 }.merging(extra) { $1 }, stdin: stdin)
    }

    /// Runs tincan in this world in a terminal, answering its yes/no question with `answer`.
    func runInTerminal(_ arguments: [String], answer: String) throws -> CLIResult {
        try CLI.runInTerminal(arguments, environment: environment.merging(["COLUMNS": "100"]) { $1 }, answer: answer)
    }

    /// Runs tincan with `--json`.
    func json(_ arguments: [String], environment extra: [String: String] = [:]) throws -> CLIResult {
        try run(arguments + ["--json"], environment: extra)
    }

    /// Points tincan at `messages` instead of the shared world, with an empty call history
    /// and `contacts`, in region US: for tests that build or change their own Messages data.
    static func environment(_ messages: MessagesFixture, contacts json: String = "[]") throws -> [String: String] {
        let calls = try CallHistoryFixture()
        let directory = messages.database.directory
        let config = directory.appendingPathComponent("config.toml")
        try "region = \"US\"\n".write(to: config, atomically: true, encoding: .utf8)
        let contacts = directory.appendingPathComponent("contacts.json")
        try json.write(to: contacts, atomically: true, encoding: .utf8)
        return [
            "TINCAN_MESSAGES_DB": messages.path, "TINCAN_CALL_HISTORY_DB": calls.database.path,
            "TINCAN_CONTACTS_FILE": contacts.path, "TINCAN_CONFIG": config.path,
        ]
    }

    // MARK: Building

    /// Whole seconds, so dates survive Apple's nanosecond timestamps exactly.
    static let now = Date(timeIntervalSinceReferenceDate: Date().timeIntervalSinceReferenceDate.rounded(.down))

    static func ago(days: Double = 0, hours: Double = 0, minutes: Double = 0) -> Date {
        now.addingTimeInterval(-(days * 86_400 + hours * 3_600 + minutes * 60))
    }

    private static func build() throws -> Data {
        let messages = try MessagesFixture()
        let rows = try fill(messages)
        let calls = try CallHistoryFixture()
        try fill(calls)
        let directory = messages.database.directory
        let contacts = directory.appendingPathComponent("contacts.json")
        try contactsJSON.write(to: contacts, atomically: true, encoding: .utf8)
        // A downloaded attachment needs a file on disk.
        FileManager.default.createFile(atPath: directory.appendingPathComponent("IMG_0042.jpeg").path, contents: Foundation.Data(repeating: 0xFF, count: 64))
        return Data(messages: messages.path, calls: calls.database.path, contacts: contacts.path, directory: directory, rows: rows)
    }

    static let contactsJSON = """
        [
          {"ref": "contact:maya", "given_name": "Maya", "family_name": "Chen", "organization": "Northwind", "job_title": "Designer",
           "birthday": "1990-03-04",
           "phones": [{"label": "mobile", "value": "(415) 555-0142"}], "emails": [{"label": "home", "value": "maya@example.com"}]},
          {"id": "sam-park", "given_name": "Sam", "family_name": "Park", "phones": ["+1 415 555 0188"]},
          {"id": "sam-rivera", "given_name": "Sam", "family_name": "Rivera", "organization": "Northwind", "phones": ["+16285550131"]},
          {"id": "kenji", "given_name": "健二", "family_name": "佐藤", "phones": [{"label": "mobile", "value": "+81 90-1234-5678"}]},
          {"id": "ava", "given_name": "Ava 🌸", "family_name": "Lin", "nickname": "Ava", "phones": ["+14155550166"]},
          {"id": "jordan-lee", "given_name": "Jordan", "family_name": "Lee", "phones": [{"label": "home", "value": "+14155550177"}]},
          {"id": "riley-lee", "given_name": "Riley", "family_name": "Lee", "phones": [{"label": "home", "value": "+14155550177"}]},
          {"id": "dental", "organization": "Northwind Dental", "phones": [{"label": "work", "value": "+14155550100"}]},
          {"id": "max", "given_name": "Maximilian Alexander", "family_name": "von Hohenzollern-Sigmaringen", "phones": ["+14155550155"]}
        ]
        """

    /// Your own address, used as the account your messages went out from.
    static let ownAddress = "+14155550101"

    private static func fill(_ fixture: MessagesFixture) throws -> Rows {
        var rows = Rows()
        let mayaPhone = try fixture.addHandle("+14155550142")
        let mayaSMS = try fixture.addHandle("+14155550142", service: "SMS")
        let mayaEmail = try fixture.addHandle("maya@example.com")
        let samPark = try fixture.addHandle("+14155550188")
        let samRivera = try fixture.addHandle("+16285550131")
        let kenji = try fixture.addHandle("+819012345678")
        let ava = try fixture.addHandle("+14155550166")
        let unknown = try fixture.addHandle("+14155550199", service: "SMS")
        let lee = try fixture.addHandle("+14155550177")
        let max = try fixture.addHandle("+14155550155")
        let junk = try fixture.addHandle("+14155550123", service: "SMS")

        let maya = try fixture.addChat("iMessage;-;+14155550142", participants: [mayaPhone])
        let mayaText = try fixture.addChat("SMS;-;+14155550142", service: "SMS", participants: [mayaSMS])
        let mayaMail = try fixture.addChat("iMessage;-;maya@example.com", participants: [mayaEmail])
        let crew = try fixture.addChat("iMessage;+;chat100000001", displayName: "Climbing crew 🧗", participants: [mayaPhone, samPark, kenji])
        let rivera = try fixture.addChat("iMessage;-;+16285550131", participants: [samRivera])
        let stranger = try fixture.addChat("SMS;-;+14155550199", service: "SMS", participants: [unknown])
        let avaChat = try fixture.addChat("iMessage;-;+14155550166", participants: [ava])
        let leeChat = try fixture.addChat("iMessage;-;+14155550177", participants: [lee])
        let trip = try fixture.addChat("iMessage;+;chat100000002", participants: [ava, kenji, samPark, max])
        let park = try fixture.addChat("iMessage;-;+14155550188", participants: [samPark])
        let maxChat = try fixture.addChat("iMessage;-;+14155550155", participants: [max])
        let junkChat = try fixture.addChat("SMS;-;+14155550123", service: "SMS", participants: [junk], isFiltered: true)
        rows.chats = [
            "maya": maya, "mayaText": mayaText, "mayaMail": mayaMail, "crew": crew, "rivera": rivera, "stranger": stranger,
            "ava": avaChat, "lee": leeChat, "trip": trip, "park": park, "max": maxChat, "junk": junkChat,
        ]
        func mine(_ columns: inout MessagesFixture.MessageColumns) {
            columns.destinationCallerID = ownAddress
            columns.isDelivered = true
        }

        // Two days ago: a long iMessage thread with Maya.
        var at = ago(days: 2, hours: 3)
        func next(_ minutes: Double = 2) -> Date {
            at = at.addingTimeInterval(minutes * 60)
            return at
        }
        rows.mayaFirst = try fixture.addMessage("are we still on for dinner?", in: maya, from: .handle(mayaPhone), at: next())
        rows.mayaYes = try fixture.addMessage("yes! 7:30 at the usual place", in: maya, from: .meTo(mayaPhone), at: next()) { mine(&$0) }
        rows.mayaLove = try fixture.addReaction(.love, to: rows.mayaYes, in: maya, from: .handle(mayaPhone), at: next(1))
        for index in 1...8 {
            try fixture.addMessage("filler \(index) from Maya", in: maya, from: .handle(mayaPhone), at: next(1))
            try fixture.addMessage("filler \(index) from me", in: maya, from: .meTo(mayaPhone), at: next(1)) { mine(&$0) }
        }
        try fixture.addMessage(
            "So here's the thing about the reservation: they only hold tables for fifteen minutes, and the last time we were late they gave ours away to a birthday party of twelve, so please, please be on time tonight.",
            in: maya, from: .handle(mayaPhone), at: next(30)
        )
        try fixture.addMessage("see you at 7:45", in: maya, from: .meTo(mayaPhone), at: next()) {
            mine(&$0)
            $0.dateEdited = at.addingTimeInterval(30)
            $0.summaryInfo = ["ep": [0], "ec": ["0": [["d": 1]]]]
        }
        try fixture.addMessage("Perfect, booked it", in: maya, from: .handle(mayaPhone), at: next()) {
            $0.threadOriginatorGUID = rows.mayaFirst.guid
        }
        try fixture.addMessage(nil, in: maya, from: .meTo(mayaPhone), at: next()) {
            mine(&$0)
            $0.dateRetracted = at.addingTimeInterval(20)
            $0.summaryInfo = ["rp": [0]]
        }
        let photo = try fixture.addMessage("\u{FFFC}", in: maya, from: .handle(mayaPhone), at: next())
        try fixture.addAttachment(
            to: photo, name: "IMG_0042.jpeg", mimeType: "image/jpeg", uti: "public.jpeg", bytes: 2_100_000,
            filename: fixture.database.directory.appendingPathComponent("IMG_0042.jpeg").path)
        let video = try fixture.addMessage("\u{FFFC}", in: maya, from: .handle(mayaPhone), at: next())
        try fixture.addAttachment(to: video, name: "climb.mov", mimeType: "video/quicktime", uti: "com.apple.quicktime-movie", bytes: 48_000_000)
        try fixture.addMessage("https://example.com/menu", in: maya, from: .meTo(mayaPhone), at: next()) {
            mine(&$0)
            $0.balloonBundleID = "com.apple.messages.URLBalloonProvider"
        }
        try fixture.addMessage("8 Ball", in: maya, from: .handle(mayaPhone), at: next()) {
            $0.balloonBundleID = "com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:com.gamerdelights.gamepigeon.ext"
        }
        try fixture.addMessage(nil, in: maya, from: .handle(mayaPhone), at: next()) { $0.isAudioMessage = true }
        try fixture.addMessage("Happy birthday!", in: maya, from: .meTo(mayaPhone), at: next()) {
            mine(&$0)
            $0.expressiveSendStyleID = "com.apple.messages.effect.CKHappyBirthdayEffect"
        }
        try fixture.addMessage("Menu for tonight", in: maya, from: .meTo(mayaPhone), at: next()) {
            mine(&$0)
            $0.subject = "Dinner plans"
        }
        rows.mayaLatest = try fixture.addMessage("did this one go through?", in: maya, from: .meTo(mayaPhone), at: next()) {
            mine(&$0)
            $0.isDelivered = false
            $0.error = 22
        }

        // Yesterday: Maya over SMS, and the climbing group.
        at = ago(days: 1, hours: 2)
        try fixture.addMessage("running late, my phone died", in: mayaText, from: .handle(mayaSMS), at: next(), configure: { $0.service = "SMS" })
        try fixture.addMessage("no worries", in: mayaText, from: .meTo(mayaSMS), at: next()) {
            mine(&$0)
            $0.service = "SMS"
        }
        try fixture.addMessage(nil, in: crew, from: .me, at: next()) {
            $0.itemType = 2
            $0.groupTitle = "Climbing crew 🧗"
        }
        try fixture.addMessage("who's in for saturday?", in: crew, from: .handle(samPark), at: next())
        rows.groupReactionTarget = try fixture.addMessage("行きます！", in: crew, from: .handle(kenji), at: next())
        try fixture.addReaction(.laugh, to: rows.groupReactionTarget, in: crew, from: .handle(samPark), at: next(1))
        try fixture.addMessage("me!", in: crew, from: .handle(mayaPhone), at: next())
        try fixture.addMessage("I'm in", in: crew, from: .me, at: next()) { mine(&$0) }
        try fixture.addMessage(nil, in: crew, from: .handle(kenji), at: next()) {
            $0.itemType = 1
            $0.otherHandle = ava
        }
        try fixture.addMessage("土曜日の朝9時にジムで会いましょう。駐車場は混むので早めに来てください。", in: crew, from: .handle(kenji), at: next())
        try fixture.addMessage("photos from the trip", in: trip, from: .handle(ava), at: next())
        try fixture.addMessage("Hi, it's the Lee house", in: leeChat, from: .handle(lee), at: next())
        try fixture.addMessage("Guten Tag! Wie geht's?", in: maxChat, from: .handle(max), at: next())
        // Unread, as junk often is: only --all shows it.
        try fixture.addMessage("You have won a prize", in: junkChat, from: .handle(junk), at: next()) {
            $0.service = "SMS"
            $0.isRead = false
        }
        try fixture.addMessage("🌸🌸🌸 thank you!!", in: avaChat, from: .handle(ava), at: next())

        // Sam Rivera: the conversation the exclusion tests keep out.
        rows.secret = try fixture.addMessage("the secret word is pineapple", in: rivera, from: .handle(samRivera), at: next())
        try fixture.addReaction(.like, to: rows.secret, in: rivera, from: .meTo(samRivera), at: next(1))

        // Today: unread messages and replies to missed calls.
        at = ago(hours: 5)
        try fixture.addMessage("Did you get my call?", in: park, from: .handle(samPark), at: next())
        try fixture.addMessage("sorry, was driving. call you tonight", in: park, from: .meTo(samPark), at: next()) { mine(&$0) }
        try fixture.addMessage("sent you the photos 📸", in: mayaMail, from: .handle(mayaEmail), at: next()) { $0.isRead = false }
        try fixture.addMessage("secret plans for friday", in: rivera, from: .handle(samRivera), at: next()) { $0.isRead = false }
        at = ago(hours: 1)
        try fixture.addMessage("Your code is 123456", in: stranger, from: .handle(unknown), at: next()) {
            $0.service = "SMS"
            $0.isRead = false
        }
        let last = try fixture.addMessage("rope or bouldering?", in: crew, from: .handle(samPark), at: next()) { $0.isRead = false }
        try fixture.addReaction(.like, to: last, in: crew, from: .handle(mayaPhone), at: next(1))
        return rows
    }

    private static func fill(_ fixture: CallHistoryFixture) throws {
        // Older answered calls, enough to need a second page.
        for day in 0..<24 {
            try fixture.addCall(address: "+14155550177", at: ago(days: 30 - Double(day)), answered: true, duration: 60 + Double(day))
        }
        // Missed, then called back five minutes later.
        try fixture.addCall(address: "+14155550142", at: ago(days: 2, hours: 1))
        try fixture.addCall(address: "+14155550142", at: ago(days: 2, hours: 1).addingTimeInterval(300), outgoing: true, duration: 120)
        // Missed, then texted back in Sam Park's conversation an hour later.
        try fixture.addCall(address: "+14155550188", at: ago(hours: 6))
        // Missed from a company card, and not returned.
        try fixture.addCall(address: "+14155550100", at: ago(hours: 4))
        // Missed and not returned, from a number nobody has.
        try fixture.addCall(address: "+14155550122", at: ago(hours: 3), location: "San Francisco, CA")
        try fixture.addCall(address: "+819012345678", at: ago(hours: 2, minutes: 30), answered: true, duration: 185, type: .faceTimeVideo)
        try fixture.addCall(address: "+14155550166", at: ago(hours: 2), outgoing: true, duration: 0)
        try fixture.addCall(address: "+14155550111", at: ago(hours: 1, minutes: 30), junkConfidence: 1)
        let mayaHandle = try fixture.addHandle(normalized: "+14155550142", value: "+14155550142")
        let samHandle = try fixture.addHandle(normalized: "+14155550188", value: "+14155550188")
        try fixture.addCall(
            address: nil, at: ago(hours: 1), outgoing: true, duration: 600, type: .faceTimeAudio, provider: "com.apple.FaceTime",
            participants: [mayaHandle, samHandle])
        try fixture.addCall(address: nil, at: ago(minutes: 40))
        try fixture.addCall(address: "+16285550131", at: ago(minutes: 20), answered: true, duration: 42, provider: "net.whatsapp.WhatsApp")
    }
}
