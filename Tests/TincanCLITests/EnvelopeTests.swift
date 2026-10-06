import Foundation
import Testing

/// The agent contract: one envelope per command, stable error codes with a hint, and exit
/// codes 0 ok, 1 failure, 2 partial or attention, 3 needs input, 4 permission.
@Suite("Envelopes, errors and exit codes")
struct EnvelopeTests {
    let world: World

    init() throws { world = try World() }

    func expectEnvelope(_ result: CLIResult, command: String, ok: Bool, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let json = try result.json
        #expect(json["tincan"] is String, sourceLocation: sourceLocation)
        #expect(json["schema"] as? Int == 1, sourceLocation: sourceLocation)
        #expect(json["command"] as? String == command, sourceLocation: sourceLocation)
        #expect(json["ok"] as? Bool == ok, sourceLocation: sourceLocation)
        #expect(json["warnings"] is [Any], sourceLocation: sourceLocation)
        if ok {
            #expect(json["error"] == nil, sourceLocation: sourceLocation)
        } else {
            let error = json["error"] as? [String: Any]
            #expect(error?["code"] is String, sourceLocation: sourceLocation)
            #expect((error?["message"] as? String)?.isEmpty == false, sourceLocation: sourceLocation)
            #expect((error?["hint"] as? String)?.isEmpty == false, sourceLocation: sourceLocation)
        }
        #expect(result.stdout.hasSuffix("}\n") && result.stdout.filter { $0 == "\n" }.count == 1, "one document, one line", sourceLocation: sourceLocation)
    }

    @Test func everyCommandAnswersWithOneEnvelope() throws {
        let commands: [(arguments: [String], name: String)] = [
            ([], "home"), (["chats"], "chats"), (["read", "Maya"], "read"), (["who", "Maya"], "who"), (["inbox"], "inbox"),
            (["search", "dinner"], "search"), (["calls"], "calls"), (["contacts"], "contacts find"), (["contacts", "show", "Maya"], "contacts show"),
            (["config"], "config show"), (["config", "path"], "config path"), (["exclude"], "exclude list"), (["skill"], "skill"),
            (["send", "maya@example.com", "hi", "--dry-run"], "send"), (["contacts", "add", "--name", "Riya Shah", "--dry-run"], "contacts add"),
            (["contacts", "edit", "Maya", "--nickname", "M", "--dry-run"], "contacts edit"),
        ]
        for command in commands {
            let result = try world.json(command.arguments)
            #expect(result.status == 0, "tincan \(command.arguments.joined(separator: " ")): \(result.stderr)")
            try expectEnvelope(result, command: command.name, ok: true)
            #expect(result.stderr.isEmpty)
        }
    }

    @Test func usageErrorsExit64WithJSONWhenAsked() throws {
        let bad = try world.json(["read", "Maya", "--limit", "many"])
        #expect(bad.status == 64)
        try expectEnvelope(bad, command: "read", ok: false)
        #expect(try bad.errorCode == "invalid_arguments")
        #expect(try bad.error?["hint"] as? String == "Run `tincan read --help` for usage.")
        try JSONShape.expect(bad.json, matches: "error-usage")

        let nested = try world.json(["contacts", "add", "--bogus"])
        #expect(nested.status == 64)
        try expectEnvelope(nested, command: "contacts add", ok: false)
        let root = try world.json(["--bogus"])
        try expectEnvelope(root, command: "home", ok: false)
        #expect(try root.error?["hint"] as? String == "Run `tincan --help` for usage.")
        let beforeCommand = try world.json(["--color", "never", "chats", "--limit", "x"])
        try expectEnvelope(beforeCommand, command: "chats", ok: false)

        // A limit too large to count one more row past is refused, not a crash.
        for command in [["read", "Maya"], ["search", "lunch"], ["inbox", "--since", "1w"], ["chats"], ["calls"], ["contacts"]] {
            let huge = try world.json(command + ["--limit", "9223372036854775807"])
            #expect(huge.status == 64, "\(command)")
            #expect(try huge.errorCode == "invalid_input", "\(command)")
        }

        // Times that aren't numbers are refused; ones beyond the database's range mean
        // everything that way. Neither may crash.
        for command in [["read", "Maya"], ["search", "lunch"], ["inbox"], ["calls"]] {
            for time in ["infd", "nanh"] {
                let refused = try world.json(command + ["--since", time])
                #expect(refused.status == 64, "\(command) --since \(time)")
                #expect(try refused.errorCode == "invalid_input", "\(command) --since \(time)")
            }
            for option in [["--since", "1e300d"], ["--since", "400000w"], ["--since", "0001-01-01"]] {
                #expect(try world.json(command + option).status == 0, "\(command) \(option)")
            }
        }
        #expect(try world.json(["read", "Maya", "--before", "9999-01-01"]).status == 0)
        for option in [["--interval", "inf"], ["--interval", "nan"], ["--interval", "7200"], ["--batch", "nan"], ["--batch", "inf"]] {
            let watch = try world.json(["watch"] + option)
            #expect(watch.status == 64, "watch \(option)")
        }

        let environment = try world.run(["read"], environment: ["TINCAN_OUTPUT": "json"])
        #expect(environment.status == 64)
        try expectEnvelope(environment, command: "read", ok: false)

        let human = try world.run(["read", "Maya", "--limit", "many"])
        #expect(human.status == 64)
        #expect(human.stdout.isEmpty)
        #expect(human.stderr.contains("Usage: tincan read"))
        let unknownOption = try world.run(["chats", "--bogus"])
        #expect(unknownOption.status == 64)
        #expect(unknownOption.stderr.contains("Unknown option '--bogus'"))

        // tincan's own checks of a value exit the same way, with or without --json.
        let zero = try world.run(["chats", "--limit", "0"])
        #expect(zero.status == 64)
        #expect(zero.stderr.hasPrefix("? --limit must be at least 1."), "\(zero.stderr)")
        let zeroJSON = try world.json(["chats", "--limit", "0"])
        #expect(zeroJSON.status == 64)
        #expect(try zeroJSON.errorCode == "invalid_input")
    }

    @Test func notFoundAndAmbiguousReferencesNeedInput() throws {
        let missing = try world.json(["read", "Zed Nobody"])
        #expect(missing.status == 3)
        try expectEnvelope(missing, command: "read", ok: false)
        #expect(try missing.errorCode == "not_found")
        let chat = try world.json(["read", "chat:999"])
        #expect(try chat.errorCode == "not_found")
        let sam = try world.run(["who", "Sam"])
        #expect(sam.status == 3)
        #expect(sam.stderr.contains("contact:sam-park"))
        #expect(sam.stderr.contains("contact:sam-rivera"))
        // The hint names no candidate: choosing is the person's decision.
        #expect(sam.stderr.contains("→ Ask the person which one they mean"))
        #expect(sam.stderr.contains("`tincan who <reference>`"))
    }

    @Test func permissionErrorsExitFour() throws {
        let locked = world.directory.appendingPathComponent("locked.db")
        try Data(contentsOf: URL(fileURLWithPath: world.data.messages)).write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: locked.path) }
        let environment = ["TINCAN_MESSAGES_DB": locked.path]
        let result = try world.run(["chats", "--json"], environment: environment)
        #expect(result.status == 4)
        #expect(try result.errorCode == "full_disk_access_required")
        // The step names the app that holds the permission, and where to grant it.
        #expect(try (result.error?["message"] as? String)?.contains("doesn't have Full Disk Access") == true)
        #expect(try (result.error?["hint"] as? String)?.contains("System Settings → Privacy & Security → Full Disk Access") == true)
        #expect(try (result.error?["hint"] as? String)?.contains("quit and reopen") == true)
        let human = try world.run(["read", "Maya"], environment: environment)
        #expect(human.status == 4)
        #expect(human.stderr.contains("Full Disk Access"))
        // At home, missing access is a setup step, not an error.
        let home = try world.run(["--json"], environment: environment)
        #expect(home.status == 0)
        #expect(try home.dataObject["setup_needed"] as? Bool == true)
    }

    @Test func missingDataIsAFailureThatNamesTheOverride() throws {
        let result = try world.run(["chats", "--json"], environment: ["TINCAN_MESSAGES_DB": "/nonexistent/chat.db"])
        #expect(result.status == 1)
        #expect(try result.errorCode == "messages_missing")
        #expect(try (result.error?["message"] as? String)?.contains("TINCAN_MESSAGES_DB") == true)
        let calls = try world.run(["calls", "--json"], environment: ["TINCAN_CALL_HISTORY_DB": "/nonexistent/CallHistory.storedata"])
        #expect(calls.status == 1)
        #expect(try calls.errorCode == "call_history_missing")
        // Elsewhere a missing call history is a warning, not a failure.
        let who = try world.run(["who", "Maya", "--json"], environment: ["TINCAN_CALL_HISTORY_DB": "/nonexistent/CallHistory.storedata"])
        #expect(who.status == 0)
        #expect(try who.warningCodes == ["calls_unavailable"])
    }

    @Test func skillPrintsTheBundledGuide() throws {
        let json = try world.json(["skill"])
        let data = try json.dataObject
        #expect(data["name"] as? String == "tincan")
        #expect((data["content"] as? String)?.contains("tincan") == true)
        try JSONShape.expect(json.json, matches: "skill")
        let human = try world.run(["skill"])
        #expect(human.stdout == (data["content"] as? String ?? "") + "\n")
    }

    @Test func doctorReportsChecksAndExitsByHealth() throws {
        let result = try world.json(["doctor"])
        #expect(result.status == 0 || result.status == 2)
        let data = try result.dataObject
        let healthy = data["healthy"] as? Bool
        #expect(healthy == (result.status == 0))
        #expect(data["version"] is String)
        let checks = data["checks"] as? [[String: Any]] ?? []
        for check in checks {
            #expect(check["id"] is String)
            #expect(["ok", "warn", "fail", "skip"].contains(check["status"] as? String ?? ""))
            #expect(check["title"] is String)
            #expect(check["detail"] == nil || check["detail"] is String)
            #expect(check["fix"] == nil || check["fix"] is String)
            #expect(check["status"] as? String == "ok" || check["fix"] is String, "every problem names a fix")
        }
        let ids = Set(checks.compactMap { $0["id"] as? String })
        #expect(ids.isSuperset(of: ["host", "data_sources", "full_disk_access", "contacts", "automation", "accessibility", "config"]))
        #expect(!ids.contains("identity") && !ids.contains("grants"))
        let host = data["host"] as? [String: Any]
        #expect(["app", "program", "ssh", "unknown"].contains(host?["kind"] as? String ?? ""))
        #expect(checks.first?["id"] as? String == "host")
        let sources = checks.first { $0["id"] as? String == "data_sources" }
        #expect(sources?["status"] as? String == "warn")
        #expect((sources?["detail"] as? String)?.contains("TINCAN_MESSAGES_DB=") == true)
        // Reading other data turns sending off, whatever macOS would allow.
        let sending = checks.first { $0["id"] as? String == "automation" }
        #expect(sending?["status"] as? String == "skip")
        #expect(sending?["detail"] as? String == "Sending is off while tincan reads other data.")
        let access = checks.first { $0["id"] as? String == "full_disk_access" }
        #expect(access?["status"] as? String == "ok")
        let fix = try world.json(["doctor", "--fix"])
        #expect(fix.status == 64)
        #expect(try fix.errorCode == "invalid_input")
    }
}
