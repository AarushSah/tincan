import ArgumentParser
import Foundation
import Testing
import TincanKit

@testable import TincanCLI

/// Help is the full command reference, so its examples must work.
@Suite("Help and examples")
struct HelpTests {
    /// Every command a person can see, with its path: `["contacts", "add"]`.
    static let commands: [(path: [String], type: ParsableCommand.Type)] = {
        var result: [(path: [String], type: ParsableCommand.Type)] = []
        func visit(_ type: ParsableCommand.Type, path: [String]) {
            for sub in type.configuration.subcommands where sub.configuration.shouldDisplay {
                let subPath = path + [sub._commandName]
                result.append((subPath, sub))
                visit(sub, path: subPath)
            }
        }
        visit(Tincan.self, path: [])
        return result
    }()

    /// The example command lines in a command's help.
    static func examples(_ type: ParsableCommand.Type) -> [String] {
        let discussion = type.configuration.discussion
        let section =
            type == Tincan.self
            ? discussion.components(separatedBy: "Start here:").last ?? ""
            : discussion.components(separatedBy: "Examples:").dropFirst().joined()
        return section.split(separator: "\n").compactMap { line -> String? in
            var text = line.trimmingCharacters(in: .whitespaces)
            if let pipe = text.range(of: "| ", options: .backwards) { text = String(text[pipe.upperBound...]) }
            guard text.hasPrefix("tincan") else { return nil }
            // The home screen's list has descriptions after two spaces.
            if type == Tincan.self, let gap = text.range(of: "  ") { text = String(text[..<gap.lowerBound]) }
            return text
        }
    }

    static var allExamples: [String] {
        ([Tincan.self as ParsableCommand.Type] + commands.map(\.type)).flatMap(examples)
    }

    @Test func everyCommandEndsItsHelpWithExamples() {
        #expect(Self.examples(Tincan.self).count >= 5)
        for command in Self.commands {
            let name = command.path.joined(separator: " ")
            #expect(!command.type.configuration.abstract.isEmpty, "\(name) has no abstract")
            #expect(command.type.configuration.abstract.hasSuffix("."), "\(name)'s abstract is not a sentence")
            let examples = Self.examples(command.type)
            #expect(!examples.isEmpty, "tincan \(name) --help has no examples")
            // Examples show the command they document.
            #expect(examples.allSatisfy { $0.hasPrefix("tincan " + command.path[0]) }, "\(name): \(examples)")
            let discussion = command.type.configuration.discussion
            let lastParagraph = discussion.components(separatedBy: "\n\n").last ?? ""
            #expect(lastParagraph.hasPrefix("Examples:"), "tincan \(name) --help should end with examples")
            // Each example fits on one line of an 80-column terminal.
            for line in lastParagraph.split(separator: "\n").dropFirst() {
                #expect(line.count <= 79, "tincan \(name) --help wraps: \(line)")
            }
        }
    }

    @Test(arguments: HelpTests.allExamples)
    func examplesParse(_ example: String) throws {
        let arguments = Array(Shell.split(example).dropFirst())
        #expect(throws: Never.self, "\(example)") { _ = try Tincan.parseAsRoot(arguments) }
    }

    /// Examples that only read run against the fixture world. They may name things the
    /// world doesn't have (chat:42) or already has (Maya's number), but never with a flag
    /// or value tincan rejects.
    @Test(arguments: HelpTests.allExamples.filter(HelpTests.readsOnly))
    func readOnlyExamplesRun(_ example: String) throws {
        let world = try World()
        var arguments = Array(Shell.split(example).dropFirst())
        if !arguments.contains("--json") { arguments.append("--json") }
        let result = try world.run(arguments)
        let code = try? result.errorCode
        #expect(
            result.status == 0
                || (result.status == 3
                    && ["not_found", "ambiguous", "contact_not_found", "no_conversation", "duplicate_contact", "unknown_message"].contains(code ?? "")),
            "\(example) exited \(result.status): \(result.stdout)\(result.stderr)")
    }

    static func readsOnly(_ example: String) -> Bool {
        let words = Shell.split(example)
        guard words.count > 1 else { return true }
        let dryRun = words.contains("--dry-run")
        switch words[1] {
        case "send": return dryRun
        case "contacts": return words.count < 3 || !["add", "edit"].contains(words[2]) || dryRun
        case "config": return words.count < 3 || ["show", "path"].contains(words[2]) || words[2].hasPrefix("-")
        case "exclude": return words.count < 3 || words[2] == "list" || words[2].hasPrefix("-")
        // --request asks macOS, unless it is a dry run.
        case "doctor": return !words.contains("--fix") && (!words.contains("--request") || dryRun)
        // Exports write, or read, a folder in the home folder; SkillTests export to temporary ones.
        case "skill": return !words.contains("--export")
        case "watch": return false
        default: return true
        }
    }

    /// Short flags mean one thing everywhere, and `--help` shows them.
    static let shortFlags = ["n": "limit", "y": "yes", "j": "json", "h": "help"]
    /// Commands whose file hasn't adopted `-n` for `--limit` yet; they still say `-l`.
    static let awaitingShortLimit: Set<String> = []

    @Test func shortFlagsAreConventionalAndNeverCollide() throws {
        let shortAndLong = try Regex(#"^\s+-([A-Za-z]), --([a-z-]+)"#)
        let longOnly = try Regex(#"^\s+--([a-z-]+)"#)
        for command in [(path: [String](), type: Tincan.self as ParsableCommand.Type)] + Self.commands {
            let name = command.path.isEmpty ? "tincan" : command.path.joined(separator: " ")
            let help = Tincan.helpMessage(for: command.type, columns: 200)
            var shorts: [String: String] = [:]
            var longs: Set<String> = []
            for line in help.split(separator: "\n").map(String.init) {
                if let match = line.firstMatch(of: shortAndLong), let short = match.output[1].substring, let long = match.output[2].substring {
                    #expect(shorts[String(short)] == nil, "\(name): -\(short) is taken twice")
                    shorts[String(short)] = String(long)
                    longs.insert(String(long))
                } else if let match = line.firstMatch(of: longOnly), let long = match.output[1].substring {
                    longs.insert(String(long))
                }
            }
            for (short, long) in shorts where !(Self.awaitingShortLimit.contains(name) && short == "l") {
                #expect(Self.shortFlags[short] == long, "\(name): -\(short) is --\(long)")
            }
            for (short, long) in Self.shortFlags where longs.contains(long) && !(Self.awaitingShortLimit.contains(name) && long == "limit") {
                #expect(shorts[short] == long, "\(name) --help should show -\(short), --\(long)")
            }
        }
    }

    @Test func shortFlagsWorkLikeLongOnes() throws {
        let world = try World()
        let chats = try world.run(["chats", "-n", "1", "-j"])
        #expect(chats.status == 0)
        #expect(try chats.dataArray.count == 1)
        #expect(try chats.warningCodes == ["truncated"])
        let read = try world.run(["read", "Maya", "-jn", "2"])
        #expect(try (read.dataObject["messages"] as? [Any])?.count == 2, "\(read.stdout)\(read.stderr)")
        // -j asks for JSON even when the rest of the command line doesn't parse.
        let bad = try world.run(["search", "lunch", "-n", "many", "-j"])
        #expect(bad.status == 64)
        #expect(try bad.errorCode == "invalid_arguments")
        try world.run(["exclude", "add", "Ava"])
        let removed = try world.run(["exclude", "remove", "Ava", "-yj"])
        #expect(removed.status == 0, "\(removed.stdout)\(removed.stderr)")
        #expect(try removed.json["ok"] as? Bool == true)
    }

    @Test func jsonIsRecognizedBeforeParsing() {
        #expect(TincanMain.asksForJSON(["chats", "-j"]))
        #expect(TincanMain.asksForJSON(["exclude", "remove", "chat:42", "-yj"]))
        #expect(TincanMain.asksForJSON(["chats", "--json"]))
        #expect(!TincanMain.asksForJSON(["chats", "-n", "5"]))
        #expect(!TincanMain.asksForJSON(["send", "Maya", "--", "-j"]))
        #expect(!TincanMain.asksForJSON(["search", "-", "--limit", "-1"]))
    }

    @Test func serviceValuesAreTheOnesTincanSendsOver() {
        #expect(MessageService.allValueStrings == ["imessage", "sms", "rcs"])
    }
}
