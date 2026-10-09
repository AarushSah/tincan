import ArgumentParser
import Foundation
import TincanKit

/// Asks before a change in a terminal, and requires --yes anywhere else, the same rule
/// `send` follows. Throws `refusal` when there is no one to ask, by default the one for
/// Contacts. Throws when the change must not happen; returns to go ahead.
func confirmChange(yes: Bool, context: Context, preview: () -> Void, question: String, refusal: TincanError? = nil) throws {
    guard !yes else { return }
    guard !context.output.json, Terminal.canPrompt else {
        throw refusal
            ?? TincanError(
                code: "confirmation_required",
                message: "Changing Contacts without a terminal needs --yes.",
                hint: "Only add --yes after the person has approved this change. Preview it with --dry-run.",
                exit: .needsInput
            )
    }
    preview()
    // Warnings, such as conversations that use a removed number, come before the question.
    context.output.flushWarnings()
    guard confirm(question, context: context) else {
        context.output.line(context.style.muted("Nothing was changed."))
        context.programStatus.idle("Nothing was changed.")
        throw ExitCode.success
    }
    // The change takes a moment, and the terminal drops this report when tincan exits.
    context.programStatus.working()
}

/// Asks a yes/no question on the terminal. Defaults to no. The question can name people,
/// so it is sanitized like all human output. Every question approves an action, and the
/// terminal's status says tincan is waiting for it; the caller reports what comes next.
func confirm(_ question: String, context: Context) -> Bool {
    let style = context.style
    context.programStatus.blocked(.permission, question)
    let prompt = TerminalText.sanitize(style.accent("? ") + question + style.muted(" [y/N] "), keepStyles: style.enabled)
    FileHandle.standardError.write(Data(prompt.utf8))
    guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
    return answer == "y" || answer == "yes"
}

enum Backups {
    /// `~/Library/Application Support/tincan/backups`, or next to the contacts file when
    /// `TINCAN_CONTACTS_FILE` is set, so fixtures never write to your Library.
    static func directory(_ sources: DataSources) -> String {
        if let file = sources.contactsFile {
            return (file as NSString).deletingLastPathComponent + "/tincan-backups"
        }
        return NSString(string: "~/Library/Application Support/tincan/backups").expandingTildeInPath
    }

    /// Saves a vCard next to earlier backups and returns its path.
    static func saveVCard(_ data: Data, contactID: String, sources: DataSources) throws -> String {
        let directory = directory(sources)
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw failed(directory)
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let safeID = contactID.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let path = "\(directory)/\(stamp)-\(safeID).vcf"
        guard FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw failed(path)
        }
        return path
    }

    private static func failed(_ path: String) -> TincanError {
        TincanError(
            code: "backup_failed",
            message: "Could not save a backup to \(path.replacingOccurrences(of: NSHomeDirectory(), with: "~")), so the contact was not changed.",
            hint: "Check that the folder is writable, then try again."
        )
    }
}
