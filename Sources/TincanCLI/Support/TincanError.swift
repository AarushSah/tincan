import Foundation
import TincanKit

/// An error a person or agent can act on: a stable code, a sentence, a next step and an
/// exit status. Every failure tincan reports goes through this type, and every one names
/// what to do next.
struct TincanError: Error, CustomStringConvertible {
    enum Exit: Int32 {
        /// The operation failed.
        case failure = 1
        /// Some work completed and some did not, or a check needs attention.
        case partial = 2
        /// Input is missing, ambiguous or needs confirmation: only the person can decide.
        case needsInput = 3
        /// macOS privacy settings block the operation.
        case permission = 4
        /// The command line is wrong: it doesn't parse, or a value in it can't be used.
        /// `EX_USAGE` from sysexits(3), as ArgumentParser uses.
        case usage = 64
    }

    /// One possible answer. `detail` is a short line for people; the other fields are the
    /// facts behind it, for the person or an assistant to decide with.
    struct Candidate: Encodable {
        let reference: String
        let name: String
        let detail: String?
        /// Canonical phone numbers and emails.
        var addresses: [String]? = nil
        var organization: String? = nil
        /// How many conversations include this person, or 1 for a conversation.
        var conversations: Int? = nil
        var lastActivity: Date? = nil
        /// One-to-one conversations with this person that are excluded, left out of
        /// `conversations` and `last_activity`.
        var excludedConversations: Int? = nil
        /// Other cards with one of these addresses, and the conversations on it they share.
        var sharesAddressWith: [SharedCard]? = nil

        struct SharedCard: Encodable {
            let contact: String
            let name: String
            let address: String
            let chats: [String]?
        }

        init(
            reference: String, name: String, detail: String?, addresses: [String]? = nil, organization: String? = nil, conversations: Int? = nil,
            lastActivity: Date? = nil
        ) {
            self.reference = reference
            self.name = name
            self.detail = detail
            self.addresses = addresses.flatMap { $0.isEmpty ? nil : $0 }
            self.organization = organization
            self.conversations = conversations
            self.lastActivity = lastActivity
        }

        /// Everything the resolver knows about a candidate.
        init(_ candidate: TincanKit.Candidate) {
            self.init(
                reference: candidate.reference, name: candidate.name, detail: candidate.detail, addresses: candidate.addresses,
                organization: candidate.organization, conversations: candidate.conversations, lastActivity: candidate.lastActivity
            )
            let shared = candidate.sharesAddressWith.map {
                SharedCard(contact: $0.reference, name: $0.name, address: $0.address, chats: $0.chats.isEmpty ? nil : $0.chats)
            }
            sharesAddressWith = shared.isEmpty ? nil : shared
            excludedConversations = candidate.excludedConversations > 0 ? candidate.excludedConversations : nil
        }

        /// A contact card, with its addresses and company.
        init(contact: Contact, detail: String?, directory: Directory) {
            self.init(
                reference: "contact:\(contact.id)", name: contact.displayName, detail: detail,
                addresses: directory.addresses(of: contact).map(\.value),
                organization: contact.isOrganization || contact.organization.isEmpty ? nil : contact.organization
            )
        }
    }

    let code: String
    let message: String
    /// The next step: usually a command to run.
    var hint: String
    var exit: Exit = .failure
    var candidates: [Candidate] = []

    var description: String { message }

    // MARK: Common errors

    /// Full Disk Access is missing. It belongs to the app that runs tincan, which names it.
    static func fullDiskAccess(_ what: String, host: PermissionHost = .current) -> TincanError {
        TincanError(
            code: "full_disk_access_required",
            message: "tincan can't read \(what): \(host.subject) doesn't have Full Disk Access.",
            hint: PermissionAdvice.grant(.fullDiskAccess, host: host),
            exit: .permission
        )
    }

    static func contactsAccess(_ status: ContactsAuthorization, host: PermissionHost = .current) -> TincanError {
        TincanError(
            code: "contacts_access_required",
            message: status == .notDetermined
                ? "\(host.sentenceSubject) hasn't been allowed to read Contacts yet."
                : "Contacts access is \(status.rawValue.replacingOccurrences(of: "_", with: " ")) for \(host.subject).",
            hint: status == .notDetermined ? PermissionAdvice.requestContacts(host: host) : PermissionAdvice.allowContacts(host: host),
            exit: .permission
        )
    }

    /// A value on the command line is wrong, or options don't fit together. Exit 64, like a
    /// command line that doesn't parse: the caller fixes the command, nobody has to decide.
    static func usage(_ message: String, hint: String) -> TincanError {
        TincanError(code: "invalid_input", message: message, hint: hint, exit: .usage)
    }

    /// Every one-to-one conversation with `person` is excluded. `groups` counts the group
    /// conversations with them that stay readable, which the message then names, so the
    /// answer is never taken for everything being excluded.
    static func excludedPerson(_ person: Person, chats: [Chat], groups: Int = 0) -> TincanError {
        TincanError(
            code: "excluded",
            message: (chats.isEmpty
                ? "One-to-one conversations with \(person.name) are excluded from tincan."
                : chats.count == 1
                    ? "Your conversation with \(person.name) is excluded from tincan."
                    : "Your \(chats.count) conversations with \(person.name) are excluded from tincan.")
                + (groups > 0
                    ? " \(Formatting.plural(groups, "group conversation")) with them stay\(groups == 1 ? "s" : "") readable: `tincan chats --with \(shellQuote(person.reference))`."
                    : ""),
            hint: excludedHint,
            exit: .needsInput
        )
    }

    /// Exclusions are the person's decision; the hint never offers a way around one.
    static let excludedHint =
        "The person chose to keep this out of tincan, and only they can change that. They can review exclusions with `tincan exclude list`."

    /// The Messages database couldn't be opened.
    static func messagesUnavailable(_ error: SQLiteError, override: String?) -> TincanError {
        switch error {
        case .accessDenied:
            return fullDiskAccess("your messages")
        case .notFound(let path) where override != nil:
            return TincanError(
                code: "messages_missing",
                message: "\(DataSources.messagesVariable) points at \(path), which doesn't exist.",
                hint: "Fix the path. Unset \(DataSources.messagesVariable) only if the person wants tincan to read this Mac's own Messages."
            )
        case .notFound:
            return TincanError(
                code: "messages_missing",
                message: "Messages has no database on this Mac.",
                hint: "Open Messages and sign in to iMessage once, then try again."
            )
        default:
            return database(error)
        }
    }

    /// The call history database couldn't be opened.
    static func callHistoryUnavailable(_ error: SQLiteError, override: String?) -> TincanError {
        switch error {
        case .accessDenied:
            return fullDiskAccess("your call history")
        case .notFound(let path) where override != nil:
            return TincanError(
                code: "call_history_missing",
                message: "\(DataSources.callHistoryVariable) points at \(path), which doesn't exist.",
                hint: "Fix the path. Unset \(DataSources.callHistoryVariable) only if the person wants tincan to read this Mac's own call history."
            )
        case .notFound:
            return TincanError(
                code: "call_history_missing",
                message: "This Mac has no call history.",
                hint: "Call history syncs from an iPhone signed in to the same Apple Account with iCloud and Continuity turned on."
            )
        default:
            return database(error)
        }
    }

    /// An override points at a settings file that isn't there. Reading defaults instead
    /// would drop the person's exclusions, so nothing runs until the path is fixed.
    static func configMissing(_ error: ConfigError) -> TincanError {
        switch error {
        case .missing(let path, let variable, let standardPath):
            func shown(_ path: String) -> String { path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
            let isFile = variable == "TINCAN_CONFIG"
            var message =
                isFile
                ? "TINCAN_CONFIG points at \(shown(path)), which doesn't exist."
                : "XDG_CONFIG_HOME puts tincan's settings at \(shown(path)), which doesn't exist."
            if let standardPath { message += " Your settings are in \(shown(standardPath))." }
            let fix = isFile ? "Fix the path" : "Point XDG_CONFIG_HOME at the folder that holds tincan/config.toml"
            return TincanError(
                code: "config_missing",
                message: message,
                hint:
                    "\(fix), or unset \(variable)\(standardPath.map { " to use \(shown($0))" } ?? ""). tincan won't run on default settings instead, which would leave out the person's exclusions."
            )
        case .dropsExclusions(let path, let variable, let standardPath, let count):
            func shown(_ path: String) -> String { path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
            return TincanError(
                code: "config_drops_exclusions",
                message:
                    "\(variable) points tincan at \(shown(path)), which leaves out \(Formatting.plural(count, "exclusion")) that \(shown(standardPath)) has.",
                hint:
                    "Unset \(variable) to use \(shown(standardPath)), or copy its [privacy] exclude list into \(shown(path)). tincan won't read this Mac's Messages without the person's exclusions."
            )
        }
    }

    static func database(_ error: SQLiteError) -> TincanError {
        TincanError(
            code: "database_error",
            message: "Reading failed: \(error.description).",
            hint: "Try again; if it keeps failing, run `tincan doctor`."
        )
    }

    /// Converts lower-level errors into actionable ones.
    static func wrap(_ error: Error) -> TincanError {
        if let error = error as? TincanError { return error }
        if let error = error as? SQLiteError {
            switch error {
            case .accessDenied(let path):
                return fullDiskAccess(path.contains("CallHistory") ? "your call history" : "your messages")
            case .notFound(let path):
                return path.contains("CallHistory") ? callHistoryUnavailable(error, override: nil) : messagesUnavailable(error, override: nil)
            default:
                return database(error)
            }
        }
        if let error = error as? ContactsError {
            switch error {
            case .notAuthorized(let status): return contactsAccess(status)
            case .notFound:
                return TincanError(
                    code: "contact_not_found", message: sentence(error.description), hint: "Find the card with `tincan contacts <name>`.", exit: .needsInput)
            case .invalidBirthday, .nothingToChange:
                return usage(sentence(error.description), hint: "See `tincan contacts --help` for the accepted values.")
            case .saveFailed:
                return TincanError(
                    code: "contacts_save_failed", message: sentence(error.description), hint: "Check the card in the Contacts app, then try again.")
            }
        }
        if let error = error as? TOMLLite.Error {
            let path = Config.defaultPath.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            switch error {
            case .invalid(let line, let problem):
                return TincanError(
                    code: "invalid_config",
                    message: "The settings file has a mistake\(line > 0 ? " on line \(line)" : ""): \(problem).",
                    hint:
                        "Fix \(path). Starting over with `tincan config reset --all` also clears the person's exclusions; run it only after they ask for that."
                )
            case .unsupported(let line, let construct):
                // Valid TOML, so not a mistake: say what tincan reads instead.
                return TincanError(
                    code: "invalid_config",
                    message:
                        "The settings file uses TOML that tincan doesn't read, on line \(line): \(construct) aren't supported. tincan's settings file supports only a subset of TOML.",
                    hint: "Rewrite that line in \(path) with what the subset has: \(TOMLLite.subset)."
                )
            }
        }
        if let error = error as? ConfigError {
            return configMissing(error)
        }
        return TincanError(code: "error", message: sentence(String(describing: error)), hint: "Try again; if it keeps failing, run `tincan doctor`.")
    }

    /// Capitalizes the first letter and ends with a period, for lower-level messages.
    static func sentence(_ text: String) -> String {
        guard let first = text.first else { return text }
        let capitalized = first.uppercased() + text.dropFirst()
        return capitalized.hasSuffix(".") || capitalized.hasSuffix("?") ? capitalized : capitalized + "."
    }
}
