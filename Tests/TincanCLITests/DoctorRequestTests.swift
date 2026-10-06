import Foundation
import Testing
import TincanKit

@testable import TincanCLI

/// `doctor --request contacts` asks macOS for Contacts only when asked to, only when macOS
/// hasn't asked the host before, and only when the host can ask. These tests use a fake
/// address book and a contacts file, so macOS never shows a question.
@Suite("Doctor asks for Contacts only on request")
struct DoctorRequestTests {
    /// An address book that records each request for access and answers `answer`.
    final class RecordingContactsProvider: ContactsProvider {
        private(set) var authorization: ContactsAuthorization
        let answer: ContactsAuthorization
        private(set) var requests = 0

        init(_ authorization: ContactsAuthorization, answer: ContactsAuthorization = .authorized) {
            self.authorization = authorization
            self.answer = answer
        }

        func requestAccess() -> ContactsAuthorization {
            requests += 1
            if authorization == .notDetermined { authorization = answer }
            return authorization
        }

        func fetchAll() throws -> [Contact] { [] }
        func fetch(id: String) throws -> Contact? { nil }
        func create(_ draft: ContactDraft) throws -> Contact { throw ContactsError.saveFailed("tests never change contacts") }
        func update(id: String, edits: [ContactEdit]) throws -> Contact { throw ContactsError.saveFailed("tests never change contacts") }
        func vCard(id: String) throws -> Data { Data() }
    }

    static let service = DoctorHostTests.service
    /// An app that doesn't say why it would use Contacts.
    static let agent = DoctorHostTests.agent

    @Test func notDeterminedAsksOnceAndReportsTheAnswer() throws {
        let provider = RecordingContactsProvider(.notDetermined, answer: .authorized)
        var announced = 0
        let outcome = Doctor.requestContacts(provider, host: Self.service, dryRun: false) { announced += 1 }
        #expect(outcome == .asked(.authorized))
        #expect(provider.requests == 1)
        #expect(announced == 1, "human output says to answer on screen before macOS asks")
        let check = try #require(
            Doctor.contactsCheck(Permissions.contacts(provider), detail: "9 contacts.", host: Self.service, interactive: false, request: outcome))
        #expect(check.status == "ok")
        #expect(check.detail == "Allowed just now. 9 contacts.")
        #expect(check.fix == nil)

        // An app whose way of asking macOS isn't known asks too; macOS decides.
        let unknown = RecordingContactsProvider(.notDetermined, answer: .denied)
        #expect(Doctor.requestContacts(unknown, host: .unknown, dryRun: false) == .asked(.denied))
        #expect(unknown.requests == 1)
        let declined = try #require(Doctor.contactsCheck(.denied, detail: nil, host: .unknown, interactive: false, request: .asked(.denied)))
        #expect(declined.status == "fail")
        #expect(declined.detail == "Not allowed when macOS asked, so people appear as phone numbers.")
        #expect(declined.fix == "Turn on the app that runs tincan in System Settings → Privacy & Security → Contacts.")
    }

    @Test func grantedChangesNothing() throws {
        for authorization in [ContactsAuthorization.authorized, .limited] {
            let provider = RecordingContactsProvider(authorization)
            var announced = 0
            #expect(Doctor.requestContacts(provider, host: Self.service, dryRun: false) { announced += 1 } == .alreadyAllowed)
            #expect(provider.requests == 0)
            #expect(announced == 0)
        }
        let check = try #require(Doctor.contactsCheck(.granted, detail: nil, host: Self.service, interactive: false, request: .alreadyAllowed))
        #expect(check.detail == "Names come from Apple Contacts.")
    }

    @Test func deniedIsNeverAskedAgainAndSaysWhereToTurnItOn() throws {
        for authorization in [ContactsAuthorization.denied, .restricted] {
            let provider = RecordingContactsProvider(authorization)
            #expect(Doctor.requestContacts(provider, host: Self.service, dryRun: false) == .alreadyAnswered)
            #expect(provider.requests == 0)
        }
        let check = try #require(Doctor.contactsCheck(.denied, detail: nil, host: Self.service, interactive: false, request: .alreadyAnswered))
        #expect(check.status == "fail")
        #expect(check.detail == "Denied, so people appear as phone numbers. macOS asks only once, so tincan didn't ask again.")
        #expect(check.fix == "Turn on Example Service in System Settings → Privacy & Security → Contacts.")
    }

    @Test func aHostThatCantAskIsNotAsked() throws {
        let provider = RecordingContactsProvider(.notDetermined)
        #expect(Doctor.requestContacts(provider, host: Self.agent, dryRun: false) == .hostCannotAsk)
        #expect(Doctor.requestContacts(provider, host: .ssh, dryRun: false) == .hostCannotAsk)
        #expect(provider.requests == 0)
        let check = try #require(Doctor.contactsCheck(.notDetermined, detail: nil, host: Self.agent, interactive: false, request: .hostCannotAsk))
        #expect(check.status == "fail")
        #expect(check.detail == "Not allowed yet, so people appear as phone numbers. tincan didn't ask macOS.")
        #expect(check.fix?.hasPrefix("agent doesn't say why it would use Contacts, so macOS may refuse it without asking.") == true)
        let ssh = try #require(Doctor.contactsCheck(.notDetermined, detail: nil, host: .ssh, interactive: false, request: .hostCannotAsk))
        #expect(ssh.fix?.contains("can't ask an SSH session") == true)
    }

    @Test func aDryRunSaysItWouldAsk() throws {
        let provider = RecordingContactsProvider(.notDetermined)
        var announced = 0
        #expect(Doctor.requestContacts(provider, host: Self.service, dryRun: true) { announced += 1 } == .wouldAsk)
        #expect(provider.requests == 0)
        #expect(announced == 0)
        let check = try #require(Doctor.contactsCheck(.notDetermined, detail: nil, host: Self.service, interactive: false, request: .wouldAsk))
        #expect(
            check.detail
                == "Not allowed yet, so people appear as phone numbers. Without --dry-run, tincan would ask macOS now, and the person would answer on this Mac's screen."
        )
        #expect(check.fix?.contains("`tincan doctor --request contacts`") == true)
    }

    @Test func noQuestionFromMacOSIsReported() throws {
        let provider = RecordingContactsProvider(.notDetermined, answer: .notDetermined)
        #expect(Doctor.requestContacts(provider, host: Self.service, dryRun: false) == .asked(.notDetermined))
        let check = try #require(
            Doctor.contactsCheck(.notDetermined, detail: nil, host: Self.service, interactive: false, request: .asked(.notDetermined)))
        #expect(check.detail == "macOS didn't show its question, so people appear as phone numbers.")
        #expect(check.fix?.hasPrefix("Example Service may not be able to ask for Contacts.") == true)
    }

    /// Without a request, the fix tells an assistant to ask the person first, then run it.
    @Test func theFixNamesTheExplicitStep() throws {
        let check = try #require(Doctor.contactsCheck(.notDetermined, detail: nil, host: Self.service, interactive: false))
        #expect(check.detail == "Not allowed yet, so people appear as phone numbers.")
        #expect(
            check.fix
                == "Ask the person whether Example Service may use Contacts. If they agree, run `tincan doctor --request contacts`: macOS asks on this Mac's screen, and the person answers there."
        )
        let error = TincanError.contactsAccess(.notDetermined, host: Self.service)
        #expect(error.hint.contains("`tincan doctor --request contacts`"))
    }

    // MARK: The real binary

    /// Contacts that macOS hasn't asked about yet, and that say yes when asked.
    static let undecided = """
        {"authorization": "not_determined", "answer_to_request": "authorized",
         "contacts": [{"id": "maya", "given_name": "Maya", "family_name": "Chen", "phones": ["+14155550142"]}]}
        """

    static func contacts(in result: CLIResult) throws -> [String: Any] {
        let checks = try result.dataObject["checks"] as? [[String: Any]] ?? []
        return try #require(checks.first { $0["id"] as? String == "contacts" })
    }

    @Test func requestIsExplicitAndCombinesOnlyWithDryRun() throws {
        let world = try World()
        for arguments in [["doctor", "--dry-run"], ["doctor", "--fix", "--request", "contacts"]] {
            let result = try world.json(arguments)
            #expect(result.status == 64, "\(arguments)")
            #expect(try result.errorCode == "invalid_input", "\(arguments)")
        }
        let unknown = try world.json(["doctor", "--request", "calendar"])
        #expect(unknown.status == 64)
        #expect(try unknown.errorCode == "invalid_arguments")
    }

    @Test func doctorAloneNeverAsks() throws {
        let world = try World(contacts: Self.undecided)
        let result = try world.json(["doctor"])
        let check = try Self.contacts(in: result)
        #expect(check["status"] as? String == "fail")
        #expect(check["detail"] as? String == "Not allowed yet, so people appear as phone numbers.")
        // Nothing asked the contacts file either.
        #expect(try world.json(["chats"]).warningCodes.contains("contacts_unavailable"))
    }

    @Test func requestReportsTheAnswerInTheContactsCheck() throws {
        let world = try World(contacts: Self.undecided)
        let preview = try Self.contacts(in: world.json(["doctor", "--request", "contacts", "--dry-run"]))
        let result = try world.json(["doctor", "--request", "contacts"])
        #expect(result.status == 0 || result.status == 2)
        #expect(result.stderr.isEmpty, "JSON mode prints nothing else")
        let check = try Self.contacts(in: result)
        // Whether macOS could ask depends on the app that runs these tests, which the tests
        // can't choose, so both outcomes are checked in full above with invented hosts.
        let detail = check["detail"] as? String ?? ""
        if check["status"] as? String == "ok" {
            #expect(detail.hasPrefix("Allowed just now. 1 contacts;"), "\(detail)")
            #expect((preview["detail"] as? String)?.contains("Without --dry-run, tincan would ask macOS now") == true)
        } else {
            #expect(detail == "Not allowed yet, so people appear as phone numbers. tincan didn't ask macOS.", "\(detail)")
            #expect(preview["detail"] as? String == detail)
        }
        // Formatted output reports the same check, after saying to answer on screen when it asks.
        let human = try world.run(["doctor", "--request", "contacts"])
        #expect(human.stdout.contains(detail.prefix(40)), "\(human.stdout)")
        #expect(human.stderr.contains("Answer on this Mac's screen.") == (check["status"] as? String == "ok"))

        // The host depends on what runs the tests; its shape is checked on its own.
        var json = try result.json
        var data = try result.dataObject
        let host = try #require(data["host"] as? [String: Any])
        #expect(["app", "program", "ssh", "unknown"].contains(host["kind"] as? String ?? ""))
        #expect(Set(host.keys).isSubset(of: ["kind", "name", "bundle_id", "path"]))
        #expect(host.values.allSatisfy { $0 is String })
        data["host"] = ["kind": host["kind"] as Any]
        json["data"] = data
        try JSONShape.expect(json, matches: "doctor-request")
    }

    @Test func deniedContactsAreNotAskedAgain() throws {
        let world = try World(contacts: #"{"authorization": "denied", "answer_to_request": "authorized", "contacts": []}"#)
        let check = try Self.contacts(in: world.json(["doctor", "--request", "contacts"]))
        #expect(check["status"] as? String == "fail")
        #expect(check["detail"] as? String == "Denied, so people appear as phone numbers. macOS asks only once, so tincan didn't ask again.")
        #expect((check["fix"] as? String)?.contains("System Settings → Privacy & Security → Contacts") == true)
    }
}
