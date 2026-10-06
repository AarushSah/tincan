import ArgumentParser
import Foundation
import TincanKit

struct Skill: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the operating guide for assistants, matching this version.",
        discussion: """
            Assistants should read the guide once before using tincan, and each topic before they first need it: \(BundledSkill.topics.map(\.name).joined(separator: ", ")). With --json the text is in data.content.

            --export writes the guide and its topics as a skill folder, SKILL.md and references/, for an assistant that loads skills from files. It creates the folder, leaves identical files alone, and replaces files that differ only with --yes, or after asking in a terminal. Export again after updating tincan.

            Examples:
              tincan skill
              tincan skill sending
              tincan skill --list
              tincan skill json --json
              tincan skill --export ~/.claude/skills/tincan --dry-run
              tincan skill --export ~/.claude/skills/tincan
            """
    )

    @Argument(help: ArgumentHelp("A topic to print instead of the guide, such as sending. --list shows every topic.", valueName: "topic"))
    var topic: String?

    @Flag(help: "List the topics, with what each covers.")
    var list = false

    @Option(help: ArgumentHelp("Write SKILL.md and references/ into this folder, such as an assistant's skills folder.", valueName: "folder"))
    var export: String?

    @Flag(help: "With --export, show what would be written without writing.")
    var dryRun = false

    @Flag(name: .shortAndLong, help: "With --export, replace files that differ without asking. Without a terminal to ask in, replacing them requires it.")
    var yes = false

    @OptionGroup var global: GlobalOptions

    struct Guide: Encodable {
        let name: String
        let topic: String?
        let version: String
        let content: String
    }

    struct ListedTopic: Encodable {
        let name: String
        let summary: String
        let file: String
    }

    struct Export: Encodable {
        let directory: String
        let files: [File]
        let dryRun: Bool?

        struct File: Encodable {
            let path: String
            /// `created`, `replaced` or `unchanged`; with `dry_run`, what would happen.
            let status: String
        }
    }

    func run() async throws {
        try await runCommand("skill", options: global) { context in
            if export == nil, dryRun || yes {
                throw TincanError.usage(
                    "--dry-run and --yes apply only to --export.", hint: "Preview an export with `tincan skill --export <folder> --dry-run`.")
            }
            if let export {
                guard topic == nil, !list else {
                    throw TincanError.usage(
                        "--export writes the guide and every topic, so it takes no topic and no --list.",
                        hint: "Run `tincan skill --export \(shellQuote(export)) --dry-run` to preview it.")
                }
                try Self.export(to: export, dryRun: dryRun, yes: yes, context: context)
            } else if list {
                guard topic == nil else {
                    throw TincanError.usage(
                        "--list lists every topic, so it takes no topic.", hint: "Run `tincan skill --list`, or `tincan skill <topic>` for one topic.")
                }
                Self.list(context: context)
            } else if let topic {
                guard let found = BundledSkill.topic(named: topic) else { throw Self.unknownTopic(topic) }
                let content = BundledSkill.text(of: found)
                context.output.result(Guide(name: "tincan", topic: found.name, version: TincanVersion.current, content: content))
                context.output.line(content)
            } else {
                let content = BundledSkill.text
                context.output.result(Guide(name: "tincan", topic: nil, version: TincanVersion.current, content: content))
                context.output.line(content)
            }
        }
    }

    static func unknownTopic(_ topic: String) -> TincanError {
        TincanError.usage(
            "\"\(topic)\" isn't a topic of tincan's guide.",
            hint:
                "Topics: \(BundledSkill.topics.map(\.name).joined(separator: ", ")). Run `tincan skill <topic>`, or `tincan skill --list` for what each covers."
        )
    }

    static func list(context: Context) {
        let topics = BundledSkill.topics
        context.output.result(topics.map { ListedTopic(name: $0.name, summary: $0.summary, file: $0.file) })
        guard !context.output.json else { return }
        let width = (topics.map(\.name.count).max() ?? 0) + 3
        for topic in topics {
            context.output.line(context.style.bold(topic.name) + String(repeating: " ", count: width - topic.name.count) + topic.summary)
        }
        context.output.hint()
        context.output.hint("Print one with `tincan skill <topic>`.")
    }

    /// Writes the guide and its topics into `folder`, laid out as a skill folder. Files that
    /// already match are left alone; files that differ may hold the person's own edits, so
    /// they are replaced only with --yes or after asking. Nothing is written on a refusal.
    static func export(to folder: String, dryRun: Bool, yes: Bool, context: Context) throws {
        guard !folder.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw TincanError.usage("--export needs a folder.", hint: "Pass one, such as `tincan skill --export ~/.claude/skills/tincan --dry-run`.")
        }
        let directory = URL(fileURLWithPath: NSString(string: folder).expandingTildeInPath).standardized
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isFolder), !isFolder.boolValue {
            throw TincanError.usage("\(shown(directory.path)) is a file, not a folder.", hint: "Pass a folder to --export, such as ~/.claude/skills/tincan.")
        }
        let plan = try BundledSkill.files().map { file -> (url: URL, data: Data, status: String) in
            let url = directory.appendingPathComponent(file.path)
            let data = Data(file.content.utf8)
            let existing = FileManager.default.contents(atPath: url.path)
            return (url, data, existing == nil ? "created" : existing == data ? "unchanged" : "replaced")
        }
        func result() -> Export {
            Export(directory: directory.path, files: plan.map { Export.File(path: $0.url.path, status: $0.status) }, dryRun: dryRun ? true : nil)
        }
        func render(_ verbs: [String: String], mark: String) {
            for file in plan {
                let line = (verbs[file.status] ?? file.status) + " " + shown(file.url.path)
                context.output.line(file.status == "unchanged" ? context.style.muted("  " + line) : mark + line)
            }
        }
        if dryRun {
            context.output.result(result())
            guard !context.output.json else { return }
            render(["created": "Would create", "replaced": "Would replace", "unchanged": "Unchanged"], mark: "  ")
            context.output.line(context.style.muted("Dry run: nothing was written."))
            return
        }
        let replaced = plan.filter { $0.status == "replaced" }
        if !replaced.isEmpty {
            let names = Formatting.list(replaced.map { shown($0.url.path) })
            let files = Formatting.plural(replaced.count, "file")
            try confirmChange(
                yes: yes, context: context,
                preview: { context.output.line("These differ from this version of tincan's guide, and may hold edits: \(names).") },
                question: "Replace \(files)?",
                refusal: TincanError(
                    code: "confirmation_required",
                    message: "Replacing \(files) that differ\(replaced.count == 1 ? "s" : "") needs --yes: \(names).",
                    hint:
                        "The person may have edited \(replaced.count == 1 ? "it" : "them"). Show them the list, and add --yes only after they approve replacing \(replaced.count == 1 ? "it" : "them").",
                    exit: .needsInput
                )
            )
        }
        for file in plan where file.status != "unchanged" {
            do {
                try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.data.write(to: file.url, options: .atomic)
            } catch {
                throw TincanError(
                    code: "export_failed",
                    message: TincanError.sentence("Could not write \(shown(file.url.path)): \(error.localizedDescription)"),
                    hint: "Check that the folder is writable, or export to another folder."
                )
            }
        }
        context.output.result(result())
        render(["created": "Created", "replaced": "Replaced", "unchanged": "Unchanged"], mark: context.style.success("✓ "))
    }

    /// A path as a person reads it, with the home folder as ~.
    static func shown(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// The guide and its topics, embedded in the binary's `__TEXT` segment at link time, one
/// section per file (see Package.swift), so `tincan skill` works offline and always matches
/// the installed version.
enum BundledSkill {
    struct Topic {
        let name: String
        /// One line on what the topic covers, as the guide's topic table says it.
        let summary: String

        /// Where the topic lives in the skill folder.
        var file: String { "references/\(name).md" }

        /// The section that holds the topic, as Package.swift names it: at most 16 characters.
        var section: String { "__ts_" + name.replacingOccurrences(of: "-", with: "_") }
    }

    /// Every topic, in the order the guide lists them. Package.swift embeds the same names.
    static let topics: [Topic] = [
        Topic(name: "reading", summary: "Conversations, search, calls, people and message fields"),
        Topic(name: "keeping-up", summary: "New messages with inbox cursors and watch"),
        Topic(name: "sending", summary: "Routing, bubbles, files, typing, statuses and send errors"),
        Topic(name: "identity", summary: "References, candidates, shared and incomplete numbers"),
        Topic(name: "contacts", summary: "Finding, adding and editing contact cards"),
        Topic(name: "privacy", summary: "Exclusions, untrusted text, hidden text and junk"),
        Topic(name: "setup", summary: "Permissions, doctor, settings and installing this guide"),
        Topic(name: "json", summary: "Every field, warning, error code and exit code"),
    ]

    static let coreSection = "__tincan_skill"

    /// `SKILL.md`.
    static var text: String { section(coreSection) ?? fallback }

    static func text(of topic: Topic) -> String {
        section(topic.section) ?? "tincan's \(topic.name) topic was not embedded in this build. See skills/tincan/\(topic.file) in the source."
    }

    /// A topic by name, ignoring case. Its file name, as in `references/sending.md`, works too.
    static func topic(named text: String) -> Topic? {
        var name = text.trimmingCharacters(in: .whitespaces).lowercased()
        if name.hasPrefix("references/") { name.removeFirst("references/".count) }
        if name.hasSuffix(".md") { name.removeLast(3) }
        return topics.first { $0.name == name }
    }

    /// The skill folder's files, `SKILL.md` first. Throws when this build lacks one, so an
    /// export never writes the placeholder text.
    static func files() throws -> [(path: String, content: String)] {
        let missing = TincanError(code: "error", message: "This build of tincan doesn't include its whole guide.", hint: "Reinstall tincan, then export again.")
        guard let core = section(coreSection) else { throw missing }
        var files = [(path: "SKILL.md", content: core)]
        for topic in topics {
            guard let text = section(topic.section) else { throw missing }
            files.append((topic.file, text))
        }
        return files
    }

    /// The contents of section `name` in the main executable's `__TEXT` segment.
    static func section(_ name: String) -> String? {
        guard let header = _dyld_get_image_header(0) else { return nil }
        var size: UInt = 0
        let raw = UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self)
        guard let bytes = getsectiondata(raw, "__TEXT", name, &size), size > 0 else { return nil }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(size)), as: UTF8.self)
    }

    static let fallback = "tincan's skill guide was not embedded in this build. See skills/tincan/SKILL.md in the source."
}
