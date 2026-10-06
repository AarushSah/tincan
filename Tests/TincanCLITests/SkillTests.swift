import ArgumentParser
import Foundation
import Testing

@testable import TincanCLI

/// `tincan skill`: the guide for assistants and its topics are embedded as written, name only
/// what tincan has, stay about using tincan, and export as a skill folder.
@Suite("Skill guide")
struct SkillTests {
    let world: World

    init() throws { world = try World() }

    static let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let folder = package.appendingPathComponent("skills/tincan")

    /// Every file of the skill folder, by its path in it.
    static let files = ["SKILL.md"] + BundledSkill.topics.map(\.file)

    static func source(_ path: String) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: Embedding

    @Test func everyFileIsEmbeddedAsWritten() throws {
        // SwiftPM relinks only when code changes, so a binary can hold an older copy.
        let stale = "The binary embeds an older copy. ./scripts/check.sh relinks it; by hand, delete .build/debug/tincan and run `swift build`."
        let core = try world.json(["skill"])
        #expect(core.status == 0)
        #expect(try core.dataObject["content"] as? String == Self.source("SKILL.md"), "SKILL.md: \(stale)")
        #expect(try core.dataObject["topic"] == nil)
        for topic in BundledSkill.topics {
            let result = try world.json(["skill", topic.name])
            #expect(result.status == 0, "\(result.stdout)")
            let data = try result.dataObject
            #expect(data["topic"] as? String == topic.name)
            #expect(data["name"] as? String == "tincan")
            #expect(data["content"] as? String == (try Self.source(topic.file)), "\(topic.file): \(stale)")
            let human = try world.run(["skill", topic.name])
            #expect(human.stdout == (data["content"] as? String ?? "") + "\n")
            #expect(human.stderr.isEmpty)
        }
        try JSONShape.expect(world.json(["skill", "sending"]).json, matches: "skill-topic")
    }

    @Test func topicsMatchTheFolderAndThePackage() throws {
        let references = try FileManager.default.contentsOfDirectory(atPath: Self.folder.appendingPathComponent("references").path)
        #expect(Set(references) == Set(BundledSkill.topics.map { ($0.file as NSString).lastPathComponent }))
        #expect(Set(BundledSkill.topics.map(\.name)).count == BundledSkill.topics.count)
        let manifest = try String(contentsOf: Self.package.appendingPathComponent("Package.swift"), encoding: .utf8)
        for topic in BundledSkill.topics {
            #expect(manifest.contains("\"\(topic.name)\""), "Package.swift doesn't embed \(topic.file)")
            // Mach-O section names hold at most 16 characters.
            #expect(topic.section.count <= 16, "\(topic.section)")
            #expect(!topic.summary.isEmpty && !topic.summary.hasSuffix("."))
        }
    }

    // MARK: Content

    @Test func theGuideNamesEveryTopic() throws {
        let guide = try Self.source("SKILL.md")
        for topic in BundledSkill.topics {
            // Printed, the guide is read with the command; installed, with the file.
            #expect(guide.contains("`tincan skill \(topic.name)`"), "SKILL.md doesn't name \(topic.name)")
            #expect(guide.contains("`\(topic.file)`"), "SKILL.md doesn't name \(topic.file)")
            #expect(guide.contains("| \(topic.summary) |"), "SKILL.md describes \(topic.name) differently from --list")
        }
    }

    @Test func theGuideTriggersAsASkill() throws {
        let guide = try Self.source("SKILL.md")
        let parts = guide.components(separatedBy: "---\n")
        #expect(parts.count >= 3 && parts[0].isEmpty, "SKILL.md starts with front matter")
        let frontMatter = parts[1].split(separator: "\n").map(String.init)
        #expect(frontMatter.first == "name: tincan")
        let description = frontMatter.first { $0.hasPrefix("description: ") }.map { String($0.dropFirst(13)) } ?? ""
        #expect(description.count <= 1024)
        for word in ["iMessage", "SMS", "RCS", "call history", "Contacts", "Use when"] {
            #expect(description.contains(word), "description should mention \(word)")
        }
    }

    /// The skill is for using tincan. Building it, testing it and contributing belong to the
    /// repository's own guides.
    @Test func theGuideIsOnlyAboutUsingTincan() throws {
        let development = [
            "swift test", "swift build", "agents.md", "fixture", "scripts/", "check.sh", "roadmap", "tincan_export_world",
            "## development", "contribut", "snapshot", "pull request", ".build/", "the tincan project",
        ]
        for path in Self.files {
            let text = try Self.source(path).lowercased()
            for phrase in development {
                #expect(!text.contains(phrase), "\(path) mentions \(phrase)")
            }
        }
    }

    /// The core is read in full by every assistant, so it stays small and easy to scan:
    /// short lines and short paragraphs, with details in the topics.
    @Test func theGuideStaysSmallAndScannable() throws {
        let guide = try Self.source("SKILL.md")
        #expect(guide.utf8.count <= 8 * 1024, "SKILL.md is \(guide.utf8.count) bytes; move details to a topic")
        for path in Self.files {
            let text = try Self.source(path)
            let body = path == "SKILL.md" ? text.components(separatedBy: "---\n").dropFirst(2).joined(separator: "---\n") : text
            var paragraph = 0
            for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
                let isTable = line.hasPrefix("|")
                #expect(isTable || line.count <= 130, "\(path) has a long line: \(line)")
                // Consecutive prose lines, a list item and its continuation, or a paragraph.
                let startsBlock = line.isEmpty || isTable || line.hasPrefix("#") || line.hasPrefix("- ") || line.first?.isNumber == true
                paragraph = line.isEmpty || isTable ? 0 : startsBlock ? 1 : paragraph + 1
                #expect(paragraph <= 3, "\(path) has a paragraph longer than three lines, ending: \(line)")
            }
        }
    }

    // MARK: Accuracy

    /// Every `tincan …` command in the skill parses, and the ones that only read run on the
    /// fixture world without a usage error.
    @Test func everyCommandInTheSkillWorks() throws {
        var commands: [(path: String, command: String)] = []
        for path in Self.files {
            let text = try Self.source(path)
            for match in text.matches(of: try Regex(#"`(tincan(?: [^`]*)?)`"#)) {
                commands.append((path, String(match.output[1].substring ?? "")))
            }
        }
        #expect(commands.count > 50)
        for (path, command) in commands where !command.contains("--help") && !command.contains("<command>") {
            let example = Self.fillPlaceholders(command)
            let arguments = Array(Shell.split(example).dropFirst())
            #expect(throws: Never.self, "\(path): \(command)") { _ = try Tincan.parseAsRoot(arguments) }
            guard HelpTests.readsOnly(example) else { continue }
            let result = try world.run(arguments.contains("-j") || arguments.contains("--json") ? arguments : arguments + ["-j"])
            #expect([0, 2, 3].contains(result.status), "\(path): \(example) exited \(result.status): \(result.stdout)\(result.stderr)")
        }
    }

    /// Stands in a value for each placeholder, such as `<who>` or `m:<id>`. `<ref>` is a
    /// person's or conversation's reference, as `who` gives it.
    static func fillPlaceholders(_ command: String) -> String {
        let values = [
            "ref": "chat:3", "target_ref": "m:1", "cursor": "m:1", "id": "1", "number": "+14155550142", "time": "2h", "folder": "/tmp/tincan-skill",
            "topic": "sending", "email": "maya.chen@example.com", "seconds": "20", "+number": "+14155550142", "chat": "chat:1",
        ]
        var text = command.replacingOccurrences(of: " …", with: "")
        while let range = text.range(of: #"<[^<>]+>"#, options: .regularExpression) {
            let name = String(text[range].dropFirst().dropLast())
            text.replaceSubrange(range, with: values[name] ?? "Maya")
        }
        return text
    }

    /// The codes the source can report: warnings through `warn`, `Notice` or a planner's
    /// `.notice`, and errors (`TincanError`, or a planner's `PlanIssue`) with the exit status
    /// each is thrown with.
    static func sourceCodes() throws -> (warnings: Set<String>, errors: [String: Set<Int32>]) {
        let sources = package.appendingPathComponent("Sources")
        let exits: [String: Int32] = ["failure": 1, "partial": 2, "needsInput": 3, "permission": 4, "usage": 64]
        var warnings = Set<String>()
        var errors: [String: Set<Int32>] = [:]
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for match in text.matches(of: try Regex(#"(?:warn\(\s*|Notice\(\s*code:\s*|\.notice\(\s*code:\s*)"([a-z_]+)""#)) {
                warnings.insert(String(match.output[1].substring ?? ""))
            }
            for match in text.matches(of: try Regex(#"(?:TincanError|PlanIssue)\(\s*code:\s*"([a-z_]+)""#)) {
                // The error's arguments run to its closing parenthesis.
                var depth = 1
                var end = match.range.upperBound
                while depth > 0, end < text.endIndex {
                    if text[end] == "(" { depth += 1 } else if text[end] == ")" { depth -= 1 }
                    end = text.index(after: end)
                }
                let arguments = text[match.range.upperBound..<end]
                let exit = arguments.firstMatch(of: try Regex(#"(?:exit|kind):\s*\.(\w+)"#)).flatMap { $0.output[1].substring.map(String.init) } ?? "failure"
                errors[String(match.output[1].substring ?? ""), default: []].insert(exits[exit] ?? -1)
            }
        }
        return (warnings, errors)
    }

    /// The rows of the table under `heading` in `text`: each row's cells.
    static func table(_ heading: String, in text: String) -> [[String]] {
        let section = text.components(separatedBy: "\n\(heading)\n").dropFirst().first?.components(separatedBy: "\n## ").first ?? ""
        return section.split(separator: "\n").filter { $0.hasPrefix("| `") }.map { row in
            row.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
    }

    static func codes(in cell: String) -> [String] {
        cell.matches(of: #/`([a-z_]+)`/#).map { String($0.output.1) }
    }

    @Test func everyCodeInTheSkillExistsAndEveryCodeIsInTheSkill() throws {
        let source = try Self.sourceCodes()
        let json = try Self.source("references/json.md")
        let warnings = Self.table("## Warnings", in: json).flatMap { Self.codes(in: $0[0]) }
        #expect(
            Set(warnings) == source.warnings,
            "json.md warnings: missing \(source.warnings.subtracting(warnings)), unknown \(Set(warnings).subtracting(source.warnings))")
        var errors: [String: Int32] = [:]
        for row in Self.table("## Error codes", in: json) {
            for code in Self.codes(in: row[0]) { errors[code] = Int32(row[1]) }
        }
        #expect(
            Set(errors.keys) == Set(source.errors.keys),
            "json.md errors: missing \(Set(source.errors.keys).subtracting(errors.keys)), unknown \(Set(errors.keys).subtracting(source.errors.keys))")
        for (code, exit) in errors {
            #expect(source.errors[code] == [exit], "json.md says \(code) exits \(exit); the source uses \(source.errors[code] ?? [])")
        }
        // The core's warning table and the topics' tables name only real codes.
        let all = source.warnings.union(source.errors.keys)
        for path in Self.files {
            let text = try Self.source(path)
            for heading in ["## Warnings to act on", "## Errors", "## Setup errors", "## Warnings and refusals"] {
                for row in Self.table(heading, in: text) {
                    for code in Self.codes(in: row[0]) {
                        #expect(all.contains(code), "\(path) names \(code), which tincan doesn't report")
                    }
                }
            }
        }
    }

    // MARK: Command line

    @Test func listShowsEveryTopic() throws {
        let json = try world.json(["skill", "--list"])
        #expect(json.status == 0)
        let listed = try json.dataArray
        #expect(listed.compactMap { $0["name"] as? String } == BundledSkill.topics.map(\.name))
        #expect(listed.compactMap { $0["file"] as? String } == BundledSkill.topics.map(\.file))
        #expect(listed.compactMap { $0["summary"] as? String } == BundledSkill.topics.map(\.summary))
        try JSONShape.expect(json.json, matches: "skill-list")
        let human = try world.run(["skill", "--list"])
        #expect(human.status == 0)
        for topic in BundledSkill.topics {
            #expect(human.stdout.contains(topic.name) && human.stdout.contains(topic.summary))
        }
        #expect(human.stderr.contains("tincan skill <topic>"))
    }

    @Test func topicNamesAreForgiving() throws {
        for name in ["SENDING", "references/sending.md", "sending.md"] {
            #expect(try world.json(["skill", name]).dataObject["topic"] as? String == "sending", "\(name)")
        }
    }

    @Test func anUnknownTopicIsAUsageError() throws {
        let json = try world.json(["skill", "texting"])
        #expect(json.status == 64)
        #expect(try json.errorCode == "invalid_input")
        let hint = try json.error?["hint"] as? String ?? ""
        for topic in BundledSkill.topics { #expect(hint.contains(topic.name)) }
        let human = try world.run(["skill", "texting"])
        #expect(human.status == 64)
        #expect(human.stdout.isEmpty && human.stderr.contains("reading, keeping-up"))
    }

    @Test func optionsThatDontCombineAreUsageErrors() throws {
        let folder = world.directory.appendingPathComponent("skills").path
        for arguments in [
            ["skill", "--dry-run"], ["skill", "--yes"], ["skill", "sending", "--list"], ["skill", "sending", "--export", folder],
            ["skill", "--list", "--export", folder],
        ] {
            let result = try world.json(arguments)
            #expect(result.status == 64, "\(arguments)")
            #expect(try result.errorCode == "invalid_input", "\(arguments)")
        }
        #expect(!FileManager.default.fileExists(atPath: folder))
    }

    @Test func exportPreviewsThenWritesTheSkillFolder() throws {
        let folder = world.directory.appendingPathComponent("skills/tincan")
        let preview = try world.json(["skill", "--export", folder.path, "--dry-run"])
        #expect(preview.status == 0, "\(preview.stdout)")
        #expect(try preview.dataObject["dry_run"] as? Bool == true)
        #expect(try Self.statuses(preview) == Array(repeating: "created", count: Self.files.count))
        #expect(!FileManager.default.fileExists(atPath: folder.path), "a dry run writes nothing")
        try JSONShape.expect(preview.json, matches: "skill-export")

        let written = try world.json(["skill", "--export", folder.path])
        #expect(written.status == 0, "\(written.stdout)")
        #expect(try written.dataObject["dry_run"] == nil)
        #expect(try written.dataObject["directory"] as? String == folder.path)
        #expect(
            try (written.dataObject["files"] as? [[String: Any]])?.compactMap { $0["path"] as? String }
                == Self.files.map { folder.appendingPathComponent($0).path })
        #expect(try Self.statuses(written) == Array(repeating: "created", count: Self.files.count))
        for path in Self.files {
            #expect(try String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8) == Self.source(path), "\(path)")
        }

        let again = try world.run(["skill", "--export", folder.path])
        #expect(again.status == 0)
        #expect(again.stdout.contains("Unchanged") && !again.stdout.contains("Created"))
    }

    @Test func exportReplacesDifferingFilesOnlyWhenTold() throws {
        let folder = world.directory.appendingPathComponent("skills/tincan")
        #expect(try world.json(["skill", "--export", folder.path]).status == 0)
        let edited = folder.appendingPathComponent("references/sending.md")
        try "My own notes.\n".write(to: edited, atomically: true, encoding: .utf8)
        let removed = folder.appendingPathComponent("references/json.md")
        try FileManager.default.removeItem(at: removed)

        let preview = try world.json(["skill", "--export", folder.path, "--dry-run"])
        let statuses = try Self.statuses(preview)
        #expect(statuses[Self.files.firstIndex(of: "references/sending.md")!] == "replaced")
        #expect(statuses[Self.files.firstIndex(of: "references/json.md")!] == "created")

        // Nothing prompts in JSON mode or without a terminal, and a refusal writes nothing.
        for arguments in [["skill", "--export", folder.path, "--json"], ["skill", "--export", folder.path]] {
            let refused = try world.run(arguments)
            #expect(refused.status == 3, "\(refused.stdout)\(refused.stderr)")
            #expect(try String(contentsOf: edited, encoding: .utf8) == "My own notes.\n")
            #expect(!FileManager.default.fileExists(atPath: removed.path))
        }
        let refused = try world.json(["skill", "--export", folder.path])
        #expect(try refused.errorCode == "confirmation_required")
        #expect(try (refused.error?["message"] as? String)?.contains("sending.md") == true)

        let replaced = try world.json(["skill", "--export", folder.path, "-y"])
        #expect(replaced.status == 0, "\(replaced.stdout)")
        let after = try Self.statuses(replaced)
        #expect(after[Self.files.firstIndex(of: "references/sending.md")!] == "replaced")
        #expect(after[Self.files.firstIndex(of: "references/json.md")!] == "created")
        #expect(after.filter { $0 == "unchanged" }.count == Self.files.count - 2)
        #expect(try String(contentsOf: edited, encoding: .utf8) == Self.source("references/sending.md"))
        #expect(try String(contentsOf: removed, encoding: .utf8) == Self.source("references/json.md"))
    }

    @Test func exportAsksInATerminal() throws {
        let folder = world.directory.appendingPathComponent("skills/tincan")
        #expect(try world.json(["skill", "--export", folder.path]).status == 0)
        let edited = folder.appendingPathComponent("SKILL.md")
        try "My own notes.\n".write(to: edited, atomically: true, encoding: .utf8)
        let declined = try world.runInTerminal(["skill", "--export", folder.path], answer: "n")
        #expect(declined.status == 0)
        #expect(declined.stdout.contains("SKILL.md") && declined.stdout.contains("Nothing was changed."))
        #expect(try String(contentsOf: edited, encoding: .utf8) == "My own notes.\n")
        let approved = try world.runInTerminal(["skill", "--export", folder.path], answer: "y")
        #expect(approved.status == 0)
        #expect(approved.stdout.contains("Replaced"))
        #expect(try String(contentsOf: edited, encoding: .utf8) == Self.source("SKILL.md"))
    }

    @Test func exportNeedsAFolder() throws {
        let file = world.directory.appendingPathComponent("not-a-folder")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        for folder in [file.path, ""] {
            let result = try world.json(["skill", "--export", folder])
            #expect(result.status == 64, "\(folder)")
            #expect(try result.errorCode == "invalid_input", "\(folder)")
        }
    }

    static func statuses(_ result: CLIResult) throws -> [String] {
        try ((result.dataObject["files"] as? [[String: Any]]) ?? []).compactMap { $0["status"] as? String }
    }
}
