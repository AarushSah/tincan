import Foundation
import Testing

@testable import TincanCLI

/// OSC 7501 status reports: their exact bytes, when tincan writes them, and what commands
/// report in a terminal. Sending is off on the fixture world, so nothing is ever sent.
@Suite("Program status")
struct ProgramStatusTests {
    static let esc = "\u{1B}"

    @Test func reportsAreExactBytes() {
        #expect(ProgramStatus.sequence(.working) == "\(Self.esc)]7501;state=working:app=tincan\(Self.esc)\\")
        #expect(
            ProgramStatus.sequence(.working, progress: 40, message: "Sending 3 messages to Maya Chen")
                == "\(Self.esc)]7501;state=working:progress=40:app=tincan:msg=U2VuZGluZyAzIG1lc3NhZ2VzIHRvIE1heWEgQ2hlbg==\(Self.esc)\\")
        #expect(
            ProgramStatus.sequence(.blocked, kind: .permission, message: "Send 2 messages to Maya Chen?")
                == "\(Self.esc)]7501;state=blocked:kind=permission:app=tincan:msg=U2VuZCAyIG1lc3NhZ2VzIHRvIE1heWEgQ2hlbj8=\(Self.esc)\\")
        #expect(
            ProgramStatus.sequence(.blocked, kind: .auth, progress: 250, message: "Waiting for Full Disk Access in System Settings")
                == "\(Self.esc)]7501;state=blocked:kind=auth:progress=100:app=tincan:msg=V2FpdGluZyBmb3IgRnVsbCBEaXNrIEFjY2VzcyBpbiBTeXN0ZW0gU2V0dGluZ3M=\(Self.esc)\\"
        )
        #expect(ProgramStatus.sequence(.working, progress: -5) == "\(Self.esc)]7501;state=working:progress=0:app=tincan\(Self.esc)\\")
        // kind goes only with blocked, and progress only with working and blocked.
        #expect(
            ProgramStatus.sequence(.done, kind: .question, progress: 100, message: "Sent 3 messages to Maya Chen.")
                == "\(Self.esc)]7501;state=done:app=tincan:msg=U2VudCAzIG1lc3NhZ2VzIHRvIE1heWEgQ2hlbi4=\(Self.esc)\\")
        #expect(ProgramStatus.sequence(.error, kind: .auth) == "\(Self.esc)]7501;state=error:app=tincan\(Self.esc)\\")
        #expect(
            ProgramStatus.sequence(.idle, message: "Nothing was sent.") == "\(Self.esc)]7501;state=idle:app=tincan:msg=Tm90aGluZyB3YXMgc2VudC4=\(Self.esc)\\")
        // A message with nothing to show is left out.
        #expect(ProgramStatus.sequence(.idle, message: " \n\t ") == "\(Self.esc)]7501;state=idle:app=tincan\(Self.esc)\\")
    }

    @Test func messagesAreOneShortLine() {
        // Names come from other people: controls, line breaks and bidirectional overrides
        // become spaces, so the terminal never refuses the report.
        #expect(ProgramStatus.line("Send 2 messages\nto\tMaya\(Self.esc)[2J  Chen\u{202E}?\u{2028}") == "Send 2 messages to Maya [2J Chen ?")
        #expect(ProgramStatus.line("\u{7F}\u{85}\r\n") == "")
        #expect(ProgramStatus.line("Sent.") == "Sent.")

        let accented = ProgramStatus.line(String(repeating: "é", count: 150))
        #expect(accented.utf8.count <= ProgramStatus.messageLimit)
        #expect(accented.hasSuffix("…"))
        #expect(accented.dropLast().allSatisfy { $0 == "é" })
        // A character of several scalars is never split.
        let family = "👨‍👩‍👧"
        let families = ProgramStatus.line(String(repeating: family, count: 40))
        #expect(families.utf8.count <= ProgramStatus.messageLimit)
        #expect(families.dropLast().allSatisfy { String($0) == family })

        let longest = ProgramStatus.sequence(.blocked, kind: .permission, progress: 100, message: String(repeating: "\u{10FFFF}", count: 5000))
        #expect(longest.utf8.count < 4096)
    }

    @Test func onlyATerminalOnStandardErrorGetsReports() {
        func reports(json: Bool = false, term: String? = "xterm-256color", standardError: Bool = true) -> Bool {
            Terminal.reportsStatus(json: json, environment: term.map { ["TERM": $0] } ?? [:], standardError: standardError)
        }
        #expect(reports())
        #expect(reports(term: nil))
        #expect(!reports(json: true))
        #expect(!reports(term: "dumb"))
        #expect(!reports(standardError: false))
    }

    @Test func onlyLongWorkReportsHowItEnded() {
        var written: [String] = []
        let quick = ProgramStatus(enabled: true, write: { written.append($0) })
        // Nothing reported yet, so there is nothing to end.
        quick.idle("Nothing was changed.")
        #expect(written.isEmpty)
        // A quick change leaves working for the terminal to drop when tincan exits.
        quick.blocked(.permission, "Save these changes to Maya Chen?")
        quick.working()
        quick.done("Saved.")
        quick.failed("Failed.")
        #expect(
            written == [ProgramStatus.sequence(.blocked, kind: .permission, message: "Save these changes to Maya Chen?"), ProgramStatus.sequence(.working)])
        #expect(!quick.ended)

        written = []
        let send = ProgramStatus(enabled: true, write: { written.append($0) })
        send.keepsOutcome = true
        send.done("Sent 2 messages to Maya Chen.")
        #expect(written.isEmpty)
        send.working("Sending 2 messages to Maya Chen", progress: 0)
        send.working("Sending 2 messages to Maya Chen", progress: 50)
        send.done("Sent 2 messages to Maya Chen.")
        // Once ended, later endings change nothing.
        send.failed("Failed.")
        send.idle("Nothing was sent.")
        #expect(
            written == [
                ProgramStatus.sequence(.working, progress: 0, message: "Sending 2 messages to Maya Chen"),
                ProgramStatus.sequence(.working, progress: 50, message: "Sending 2 messages to Maya Chen"),
                ProgramStatus.sequence(.done, message: "Sent 2 messages to Maya Chen."),
            ])
        #expect(send.ended)

        var silent: [String] = []
        let off = ProgramStatus(enabled: false, write: { silent.append($0) })
        off.keepsOutcome = true
        off.working("Sending 1 message to Maya Chen", progress: 0)
        off.blocked(.permission, "Send 1 message to Maya Chen?")
        off.idle("Nothing was sent.")
        #expect(silent.isEmpty)
        #expect(!off.started)
    }

    // MARK: In a terminal

    /// Each report in `output`, in order, as `state kind progress%: msg`, after checking that
    /// it names tincan and keeps the key order.
    static func reports(_ output: String) throws -> [String] {
        let report = try Regex("\u{1B}\\]7501;([^\u{1B}\u{07}]*)\u{1B}\\\\", as: (Substring, Substring).self)
        return try output.matches(of: report).map { match in
            var fields: [(key: String, value: String)] = []
            for pair in match.output.1.split(separator: ":") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                fields.append((parts[0], parts.count > 1 ? parts[1] : ""))
            }
            let order = ["state", "kind", "progress", "app", "msg"]
            let keys = fields.map(\.key)
            #expect(keys == order.filter(keys.contains), "\(keys)")
            let value = { (key: String) in fields.first { $0.key == key }?.value }
            #expect(value("app") == "tincan")
            var text = value("state") ?? "?"
            if let kind = value("kind") { text += " " + kind }
            if let progress = value("progress") { text += " \(progress)%" }
            if let encoded = value("msg") {
                guard let data = Data(base64Encoded: encoded), let message = String(data: data, encoding: .utf8) else {
                    throw FixtureError(description: "msg isn't base64 UTF-8: \(encoded)")
                }
                #expect(!message.unicodeScalars.contains { $0.value < 0x20 || TerminalText.isRemoved($0) }, "\(message.debugDescription)")
                text += ": " + message
            }
            return text
        }
    }

    @Test func sendReportsTheQuestionAndHowItEnded() throws {
        let world = try World()
        let maya = world.chat("maya")
        let declined = try world.runInTerminal(["send", maya, "hi"], answer: "n")
        #expect(declined.status == 0)
        #expect(try Self.reports(declined.stdout) == ["blocked permission: Send 1 message to Maya Chen?", "idle: Nothing was sent."])

        // Sending is off on the fixture world, so the send fails after it starts.
        let approved = try world.runInTerminal(["send", maya, "hi", "there"], answer: "y")
        #expect(approved.status == 1)
        let reports = try Self.reports(approved.stdout)
        #expect(reports.prefix(2) == ["blocked permission: Send 2 messages to Maya Chen?", "working 0%: Sending 2 messages to Maya Chen"])
        #expect(reports.count == 3)
        #expect(reports.last?.hasPrefix("error: tincan doesn't send while TINCAN_MESSAGES_DB") == true, "\(reports)")

        let yes = try world.runInTerminal(["send", maya, "hi", "--yes"], answer: "")
        #expect(try Self.reports(yes.stdout).first == "working 0%: Sending 1 message to Maya Chen")
    }

    @Test func aConfirmedChangeLeavesOnlyWorking() throws {
        let world = try World()
        let approved = try world.runInTerminal(["config", "reset", "--all"], answer: "y")
        #expect(approved.status == 0)
        let reports = try Self.reports(approved.stdout)
        #expect(reports.count == 2, "\(reports)")
        #expect(reports.first?.hasPrefix("blocked permission: ") == true)
        #expect(reports.last == "working")
        let declined = try world.runInTerminal(["config", "reset", "--all"], answer: "n")
        #expect(try Self.reports(declined.stdout).last == "idle: Nothing was changed.")
    }

    @Test func noReportsForJSONADumbTerminalOrNoTerminal() throws {
        let world = try World()
        let maya = world.chat("maya")
        let json = try CLI.runInTerminal(["send", maya, "hi", "--yes", "--json"], environment: world.environment, answer: "")
        #expect(json.stdout.contains("sending_unavailable"))
        #expect(!json.stdout.contains("\u{1B}]7501"))
        let dumb = try CLI.runInTerminal(["send", maya, "hi"], environment: world.environment.merging(["TERM": "dumb"]) { $1 }, answer: "n")
        #expect(dumb.stdout.contains("Nothing was sent."))
        #expect(!dumb.stdout.contains("\u{1B}]7501"))
        // Standard error is a file here.
        let noTerminal = try world.run(["send", maya, "hi", "--yes"])
        #expect(noTerminal.status == 1)
        #expect(!(noTerminal.stdout + noTerminal.stderr).contains("\u{1B}]7501"))
        // Reads don't report, even in a terminal.
        let read = try world.runInTerminal(["read", maya], answer: "")
        #expect(read.status == 0)
        #expect(!read.stdout.contains("\u{1B}]7501"))
    }
}
