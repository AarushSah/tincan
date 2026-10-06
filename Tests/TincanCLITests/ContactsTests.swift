import Foundation
import Testing

@Suite("Contacts")
struct ContactsTests {
    @Test func findSearchesNamesNumbersAndEmails() throws {
        let world = try World()
        let everyone = try world.json(["contacts"])
        #expect(everyone.status == 0)
        #expect(try everyone.json["command"] as? String == "contacts find")
        #expect(try everyone.dataArray.count == 9)
        let sams = try world.json(["contacts", "find", "sam"]).dataArray.compactMap { $0["ref"] as? String }
        #expect(sams == ["contact:sam-park", "contact:sam-rivera"])
        let byNumber = try world.json(["contacts", "(415) 555-0142"]).dataArray.compactMap { $0["ref"] as? String }
        #expect(byNumber == ["contact:maya"])
        let limited = try world.json(["contacts", "--limit", "3"])
        #expect(try limited.dataArray.count == 3)
        #expect(try limited.warningCodes == ["truncated"])
        try JSONShape.expect(everyone.json, matches: "contacts-find")
    }

    @Test func showPrintsOneCardOrAsksWhichOne() throws {
        let world = try World()
        let maya = try world.json(["contacts", "show", "Maya"])
        let card = try maya.dataObject
        #expect(card["ref"] as? String == "contact:maya")
        #expect((card["phones"] as? [[String: Any]])?.first?["normalized"] as? String == "+14155550142")
        #expect(card["birthday"] as? String == "1990-03-04")
        try JSONShape.expect(maya.json, matches: "contacts-show")

        let sam = try world.json(["contacts", "show", "Sam"])
        #expect(sam.status == 3)
        #expect(try sam.errorCode == "ambiguous")
        let candidates = try sam.error?["candidates"] as? [[String: Any]] ?? []
        #expect(candidates.compactMap { $0["reference"] as? String } == ["contact:sam-park", "contact:sam-rivera"])
        let hint = try sam.error?["hint"] as? String ?? ""
        #expect(hint.contains("tincan contacts show <reference>"))
        #expect(!hint.contains("contact:sam-park"))
        #expect(candidates.first?["addresses"] as? [String] == ["+14155550188"])
    }

    @Test func addRefusesDuplicatesAndPreviewsWithDryRun() throws {
        let world = try World(writableContacts: true)
        let before = try String(contentsOfFile: world.contacts, encoding: .utf8)
        let duplicate = try world.json(["contacts", "add", "--name", "Maya C", "--phone", "+1 415 555 0142", "--dry-run"])
        #expect(duplicate.status == 3)
        #expect(try duplicate.errorCode == "duplicate_contact")
        #expect(try (duplicate.error?["candidates"] as? [[String: Any]])?.first?["reference"] as? String == "contact:maya")

        let preview = try world.json(["contacts", "add", "--name", "Riya Shah", "--phone", "work:+14155550133", "--email", "riya@example.com", "--dry-run"])
        #expect(preview.status == 0)
        let data = try preview.dataObject
        #expect(data["dry_run"] as? Bool == true)
        let contact = data["contact"] as? [String: Any]
        #expect(contact?["given_name"] as? String == "Riya")
        #expect(contact?["family_name"] as? String == "Shah")
        #expect((contact?["phones"] as? [[String: Any]])?.first?["label"] as? String == "work")
        try JSONShape.expect(preview.json, matches: "contacts-add-dry-run")
        #expect(try String(contentsOfFile: world.contacts, encoding: .utf8) == before)
    }

    @Test func changesWithoutATerminalNeedYes() throws {
        let world = try World(writableContacts: true)
        let before = try String(contentsOfFile: world.contacts, encoding: .utf8)
        let add = try world.json(["contacts", "add", "--name", "Riya Shah", "--phone", "+14155550133"])
        #expect(add.status == 3)
        #expect(try add.errorCode == "confirmation_required")
        let edit = try world.run(["contacts", "edit", "Maya", "--nickname", "Mayo"])
        #expect(edit.status == 3)
        #expect(edit.stderr.contains("needs --yes"))
        #expect(try String(contentsOfFile: world.contacts, encoding: .utf8) == before)

        let added = try world.json(["contacts", "add", "--name", "Riya Shah", "--phone", "+14155550133", "--yes"])
        #expect(added.status == 0)
        #expect(try world.json(["contacts", "show", "Riya"]).status == 0)

        let edited = try world.json(["contacts", "edit", "Maya", "--nickname", "Mayo", "--yes"])
        #expect(edited.status == 0)
        let result = try edited.dataObject
        #expect((result["after"] as? [String: Any])?["nickname"] as? String == "Mayo")
        let backup = result["backup"] as? String ?? ""
        #expect(backup.hasPrefix(world.directory.path))
        #expect(FileManager.default.fileExists(atPath: backup))
    }

    @Test func aCompanyCardKeepsItsNameWhole() throws {
        let world = try World(writableContacts: true)
        let added = try world.json(["contacts", "add", "--org", "Northwind Traders", "--phone", "+14155550198", "--yes"])
        #expect(added.status == 0)
        // Saved and read back, the company's name is not split into a first and last name.
        let edited = try world.json(["contacts", "edit", "Northwind Traders", "--add-email", "hello@example.com", "--yes"])
        #expect(edited.status == 0)
        let card = try world.json(["contacts", "show", "Northwind Traders"]).dataObject
        #expect(card["name"] as? String == "Northwind Traders")
        #expect(card["organization"] as? String == "Northwind Traders")
        #expect(card["given_name"] == nil)
        #expect(card["family_name"] == nil)
        #expect(card["is_organization"] as? Bool == true)
    }

    @Test func editPreviewsChanges() throws {
        let world = try World(writableContacts: true)
        let result = try world.json(["contacts", "edit", "Maya", "--add-phone", "work:+14155550199", "--birthday", "", "--dry-run"])
        #expect(result.status == 0)
        #expect(try result.dataObject["changes"] as? [String] == ["clear birthday", "add phone +14155550199 (work)"])
        let missing = try world.json(["contacts", "edit", "Maya", "--remove-email", "nobody@example.com", "--dry-run"])
        #expect(missing.status == 64)
        #expect(try missing.errorCode == "invalid_input")
    }

    /// The preview is the card as it would be saved, so labels and defaults are visible.
    @Test func editPreviewShowsTheCardAfterTheChange() throws {
        let world = try World(writableContacts: true)
        let preview = try world.json(["contacts", "edit", "Maya", "--remove-email", "maya@example.com", "--add-email", "maya.chen@example.com", "--dry-run"])
        #expect(preview.status == 0)
        let after = try #require(try preview.dataObject["after"] as? [String: Any])
        let emails = (after["emails"] as? [[String: Any]]) ?? []
        #expect(emails.count == 1)
        #expect(emails.first?["value"] as? String == "maya.chen@example.com")
        #expect(emails.first?["label"] as? String == "home")
        #expect(after["ref"] as? String == "contact:maya")
    }

    /// Removing a number or email and adding it back relabels it; it must not delete it.
    @Test func removingAndAddingTheSameAddressRelabelsIt() throws {
        let world = try World(writableContacts: true)
        let preview = try world.json(["contacts", "edit", "Maya", "--remove-email", "maya@example.com", "--add-email", "work:maya@example.com", "--dry-run"])
        #expect(preview.status == 0)
        // Not leaving the card, so nothing about conversations changes.
        #expect(try preview.warningCodes.isEmpty)
        #expect(try preview.dataObject["addresses_in_use"] == nil)
        let saved = try world.json(["contacts", "edit", "Maya", "--remove-phone", "+14155550142", "--add-phone", "work:+14155550142", "--yes"])
        #expect(saved.status == 0)
        let phones = (try saved.dataObject["after"] as? [String: Any])?["phones"] as? [[String: Any]] ?? []
        #expect(phones.map { $0["label"] as? String } == ["work"])
        #expect(phones.first?["normalized"] as? String == "+14155550142")
        let card = try world.json(["contacts", "show", "contact:maya"]).dataObject
        #expect(((card["phones"] as? [[String: Any]]) ?? []).count == 1)
        // A relabeled number keeps the way the card wrote it, whatever form was typed.
        let sam = try world.json(["contacts", "edit", "Sam Park", "--remove-phone", "+14155550188", "--add-phone", "work:+14155550188", "--dry-run"])
        let samPhones = (try sam.dataObject["after"] as? [String: Any])?["phones"] as? [[String: Any]] ?? []
        #expect(samPhones.map { $0["value"] as? String } == ["+1 415 555 0188"])
        #expect(samPhones.map { $0["label"] as? String } == ["work"])
    }

    /// Adding what the card already has would only duplicate the entry.
    @Test func addingANumberOrEmailTheCardHasIsRefused() throws {
        let world = try World(writableContacts: true)
        for arguments in [["--add-phone", "+14155550142"], ["--add-email", "MAYA@example.com"]] {
            let result = try world.json(["contacts", "edit", "Maya"] + arguments + ["--yes"])
            #expect(result.status == 64, "\(arguments)")
            #expect(try result.errorCode == "invalid_input", "\(arguments)")
            let hint = try result.error?["hint"] as? String ?? ""
            #expect(hint.contains("contact:maya --remove-"), "\(arguments)")
        }
        // Nor may one command add the same number or email twice, in any format or case.
        for arguments in [
            ["edit", "Maya", "--add-phone", "work:+14155550122", "--add-phone", "(415) 555-0122"],
            ["edit", "Maya", "--add-email", "maya@example.net", "--add-email", "MAYA@example.net"],
            ["edit", "Maya", "--remove-phone", "+14155550142", "--add-phone", "work:+14155550142", "--add-phone", "home:+14155550142"],
            ["add", "--name", "Robin Vale", "--phone", "+14155550133", "--phone", "415-555-0133"],
            ["add", "--name", "Robin Vale", "--email", "robin@example.com", "--email", "Robin@Example.com"],
        ] {
            let result = try world.json(["contacts"] + arguments + ["--dry-run"])
            #expect(result.status == 64, "\(arguments)")
            #expect(try result.errorCode == "invalid_input", "\(arguments)")
        }
        let card = try world.json(["contacts", "show", "contact:maya"]).dataObject
        #expect(((card["phones"] as? [[String: Any]]) ?? []).count == 1)
        #expect(((card["emails"] as? [[String: Any]]) ?? []).count == 1)
    }

    @Test func removingAnAddressConversationsUseSaysWhichOnes() throws {
        let world = try World(writableContacts: true)
        let preview = try world.json(["contacts", "edit", "Maya", "--remove-phone", "(415) 555-0142", "--dry-run"])
        #expect(preview.status == 0)
        #expect(try preview.warningCodes == ["address_in_use"])
        let inUse = try preview.dataObject["addresses_in_use"] as? [[String: Any]] ?? []
        #expect(inUse.first?["address"] as? String == "+14155550142")
        let conversations = (inUse.first?["conversations"] as? [[String: Any]]) ?? []
        #expect(Set(conversations.compactMap { $0["ref"] as? String }) == Set(["maya", "mayaText", "crew"].map(world.chat)))
        #expect(conversations.contains { $0["name"] as? String == "Climbing crew 🧗" })
        let human = try world.run(["contacts", "edit", "Maya", "--remove-email", "maya@example.com", "--dry-run"])
        #expect(human.stderr.contains("maya@example.com is used in 1 conversation: Maya Chen (\(world.chat("mayaMail")))"))
        // Saving warns the same way.
        let saved = try world.json(["contacts", "edit", "Maya", "--remove-email", "maya@example.com", "--yes"])
        #expect(saved.status == 0)
        #expect(try saved.warningCodes == ["address_in_use"])
        // An address no conversation uses changes nothing else.
        let unused = try world.json(["contacts", "edit", "Maya", "--add-phone", "+14155550133", "--dry-run"])
        #expect(try unused.warningCodes.isEmpty)
    }

    @Test func aDuplicateCardIsOnlyAddedOnceThePersonConfirms() throws {
        let world = try World(writableContacts: true)
        let duplicate = try world.json(["contacts", "add", "--name", "Maya C", "--phone", "+1 415 555 0142", "--dry-run"])
        let hint = try duplicate.error?["hint"] as? String ?? ""
        #expect(hint.contains("Pass --allow-duplicate only after they confirm"))
        #expect(!hint.contains("contact:maya"))
        let candidate = try (duplicate.error?["candidates"] as? [[String: Any]])?.first
        #expect(candidate?["addresses"] as? [String] == ["+14155550142", "maya@example.com"])
        #expect(candidate?["organization"] as? String == "Northwind")
        #expect(try duplicate.error?["message"] as? String == "A card already has this number:")

        // Once the person confirms, the preview still names the card that has it.
        let allowed = try world.json(["contacts", "add", "--name", "Maya C", "--phone", "+1 415 555 0142", "--allow-duplicate", "--dry-run"])
        #expect(allowed.status == 0)
        let warning = try ((allowed.json["warnings"] as? [[String: Any]]) ?? []).first { $0["code"] as? String == "duplicate_contact" }
        #expect(
            warning?["message"] as? String
                == "A card already has this number: Maya Chen (contact:maya). With --allow-duplicate, tincan adds another card anyway.")
        let human = try world.run(["contacts", "add", "--name", "Maya C", "--phone", "+1 415 555 0142", "--allow-duplicate", "--dry-run"])
        #expect(human.stderr.contains("Maya Chen (contact:maya)"))
    }

    @Test func duplicateMessagesCountCardsAndAddresses() throws {
        let world = try World(writableContacts: true)
        func message(_ arguments: [String]) throws -> String? {
            try world.json(["contacts", "add", "--name", "Riya Shah", "--dry-run"] + arguments).error?["message"] as? String
        }
        #expect(try message(["--email", "maya@example.com"]) == "A card already has this email:")
        #expect(try message(["--phone", "+14155550142", "--email", "maya@example.com"]) == "A card already has these numbers and emails:")
        #expect(try message(["--phone", "+14155550177"]) == "2 cards already have this number:")
        #expect(try message(["--phone", "+14155550177", "--phone", "+14155550188"]) == "3 cards already have these numbers:")
    }

    @Test func birthdaysMustBeRealDates() throws {
        let world = try World(writableContacts: true)
        for date in ["02-30", "1990-02-29", "04-31", "1900-02-29", "13-01", "2024-00-10"] {
            for command in [["contacts", "add", "--name", "Riya Shah"], ["contacts", "edit", "Maya"]] {
                let result = try world.json(command + ["--birthday", date, "--dry-run"])
                #expect(result.status == 64, "\(command.joined(separator: " ")) --birthday \(date)")
                #expect(try result.errorCode == "invalid_input")
            }
        }
        for date in ["02-29", "2024-02-29", "2000-02-29", "12-31", "1990-04-30"] {
            let result = try world.json(["contacts", "edit", "Maya", "--birthday", date, "--dry-run"])
            #expect(result.status == 0, "--birthday \(date)")
        }
    }

    @Test func deniedContactsAreAPermissionErrorOrAWarning() throws {
        let world = try World(contacts: #"{"authorization": "denied", "contacts": []}"#)
        let find = try world.json(["contacts", "find", "Maya"])
        #expect(find.status == 4)
        #expect(try find.errorCode == "contacts_access_required")
        let human = try world.run(["contacts", "find", "Maya"])
        #expect(human.status == 4)
        #expect(human.stderr.contains("Contacts access is denied"))
        // Reading still works, with numbers for names and a warning that says why.
        let chats = try world.json(["chats"])
        #expect(chats.status == 0)
        #expect(try chats.warningCodes == ["contacts_unavailable"])
        #expect(try chats.dataArray.contains { $0["name"] as? String == "+1 (415) 555-0142" })
    }

    @Test func aBrokenContactsFileIsReported() throws {
        let world = try World(contacts: #"[{"given_name": 42}]"#)
        let result = try world.json(["contacts"])
        #expect(result.status == 1)
        #expect(try result.errorCode == "contacts_file_invalid")
    }

    @Test func meIsYourOwnCard() throws {
        let nobody = try World()
        let none = try nobody.json(["contacts", "show", "me"])
        #expect(none.status == 3)
        #expect(try none.errorCode == "not_found")
        #expect(try (none.error?["message"] as? String)?.contains("+1 (415) 555-0101") == true)

        let own = try World(contacts: #"[{"id": "you", "given_name": "Robin", "family_name": "Hale", "phones": ["+1 415 555 0101"]}]"#)
        #expect(try own.json(["contacts", "show", "me"]).dataObject["ref"] as? String == "contact:you")
        let edit = try own.json(["contacts", "edit", "ME", "--nickname", "Rob", "--dry-run"])
        #expect(edit.status == 0)

        let two = try World(
            contacts:
                #"[{"id": "you", "given_name": "Robin", "phones": ["+14155550101"]}, {"id": "you-work", "given_name": "Robin", "family_name": "Hale", "phones": ["+14155550101"]}]"#
        )
        let ambiguous = try two.json(["contacts", "show", "me"])
        #expect(ambiguous.status == 3)
        #expect(try ambiguous.errorCode == "ambiguous")
        let candidates = try ambiguous.error?["candidates"] as? [[String: Any]] ?? []
        #expect(Set(candidates.compactMap { $0["reference"] as? String }) == ["contact:you", "contact:you-work"])
    }

    @Test func anIncompleteNumberNamesNoCard() throws {
        let world = try World()
        for command in [["contacts", "show", "555-0142"], ["contacts", "edit", "555-0142", "--nickname", "M", "--dry-run"]] {
            let result = try world.json(command)
            #expect(result.status == 3)
            #expect(try result.errorCode == "incomplete_number", "tincan \(command.joined(separator: " "))")
            let candidates = try result.error?["candidates"] as? [[String: Any]] ?? []
            #expect(candidates.compactMap { $0["reference"] as? String } == ["+14155550142"])
        }
    }

    @Test func anAddressReferenceNamesTheCardWithIt() throws {
        let world = try World()
        for address in ["address:+14155550142", "Address: maya@example.com"] {
            #expect(try world.json(["contacts", "show", address]).dataObject["ref"] as? String == "contact:maya", "\(address)")
            let edit = try world.json(["contacts", "edit", address, "--nickname", "M", "--dry-run"])
            #expect(edit.status == 0, "\(address)")
            #expect((try edit.dataObject["before"] as? [String: Any])?["ref"] as? String == "contact:maya")
        }
        // On two cards, it names neither.
        for command in [["contacts", "show", "address:+14155550177"], ["contacts", "edit", "address:+14155550177", "--nickname", "L", "--dry-run"]] {
            let result = try world.json(command)
            #expect(result.status == 3)
            #expect(try result.errorCode == "ambiguous", "tincan \(command.joined(separator: " "))")
            let candidates = try result.error?["candidates"] as? [[String: Any]] ?? []
            #expect(Set(candidates.compactMap { $0["reference"] as? String }) == ["contact:jordan-lee", "contact:riley-lee"])
        }
        #expect(try world.json(["contacts", "show", "address:555-0142"]).errorCode == "incomplete_number")
        let notAnAddress = try world.json(["contacts", "show", "address:Maya"])
        #expect(try notAnAddress.errorCode == "not_found")
        #expect(try (notAnAddress.error?["hint"] as? String)?.contains("address:<+number>") == true)
        // An address no card has suggests adding it as what it is.
        let email = try world.json(["contacts", "show", "nobody@example.com"])
        #expect(try email.errorCode == "not_found")
        #expect(try (email.error?["hint"] as? String)?.contains("--email nobody@example.com") == true)
        let number = try world.json(["contacts", "show", "+14155550161"])
        #expect(try (number.error?["hint"] as? String)?.contains("--phone +14155550161") == true)
    }
}
