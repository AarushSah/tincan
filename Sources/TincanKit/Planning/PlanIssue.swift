import Foundation

/// A refusal in a planner's own words: a stable code, a sentence, the next step, what kind of
/// answer it needs and, when there is a choice to make, every candidate. The CLI reports it
/// as a `TincanError` word for word, so JSON and human output say exactly what the planner
/// decided.
public struct PlanIssue: Sendable {
    /// What the refusal needs, which the CLI maps to an exit status.
    public enum Kind: Sendable, Equatable {
        /// Something failed.
        case failure
        /// A value on the command line is wrong: the caller fixes the command.
        case usage
        /// Input is missing or ambiguous, or needs the person's decision.
        case needsInput
        /// macOS privacy settings block it.
        case permission
    }

    /// One possible answer, with the facts that tell the candidates apart. tincan lists
    /// candidates and never chooses among them.
    public struct Candidate: Sendable {
        public let reference: String
        public let name: String
        /// One line for people.
        public let detail: String?
        /// Canonical phone numbers and emails.
        public var addresses: [String]
        public var organization: String?
        /// How many conversations include it, when that tells the candidates apart.
        public var conversations: Int?
        public var lastActivity: Date?

        public init(
            reference: String, name: String, detail: String?, addresses: [String] = [], organization: String? = nil,
            conversations: Int? = nil, lastActivity: Date? = nil
        ) {
            self.reference = reference
            self.name = name
            self.detail = detail
            self.addresses = addresses
            self.organization = organization
            self.conversations = conversations
            self.lastActivity = lastActivity
        }

        /// A group as `Resolver.groupCandidate` describes it: its name, and everyone in it.
        public init(group candidate: TincanKit.Candidate) {
            self.init(
                reference: candidate.reference, name: candidate.name, detail: candidate.detail, addresses: candidate.addresses,
                organization: candidate.organization, conversations: candidate.conversations, lastActivity: candidate.lastActivity
            )
        }

        /// A contact card, with its addresses and company.
        public init(contact: Contact, detail: String?, directory: Directory) {
            self.init(
                reference: "contact:\(contact.id)", name: contact.displayName, detail: detail,
                addresses: directory.addresses(of: contact).map(\.value),
                organization: contact.isOrganization || contact.organization.isEmpty ? nil : contact.organization
            )
        }
    }

    public let code: String
    public let message: String
    /// The next step: usually a command to run. Hints never name a candidate, and never
    /// offer a safety flag such as `--yes` as the next step.
    public let hint: String
    public let kind: Kind
    public let candidates: [Candidate]

    public init(code: String, message: String, hint: String, kind: Kind = .failure, candidates: [Candidate] = []) {
        self.code = code
        self.message = message
        self.hint = hint
        self.kind = kind
        self.candidates = candidates
    }

    /// A value on the command line is wrong: `invalid_input`.
    public static func invalidInput(_ message: String, hint: String) -> PlanIssue {
        PlanIssue(code: "invalid_input", message: message, hint: hint, kind: .usage)
    }

    /// A command with a placeholder for the reference, never a candidate's own: the choice
    /// is the person's. `tincan send <reference> …`
    public static func example(_ command: String) -> String {
        "tincan \(command) <reference>" + (command == "send" || command.contains("--") ? " …" : "")
    }
}

/// Why a planner stopped, as data. Most refusals are in the planner's words; the rest carry
/// the facts behind a refusal that every command words the same way.
public enum PlanRefusal: Error, Sendable {
    /// Refused in the planner's words.
    case issue(PlanIssue)
    /// A reference that names nothing, several things or an excluded conversation, or a
    /// number that names no line. `command` is the command its hint suggests, such as `send`
    /// or `contacts add --phone`.
    case unresolved(ResolveError, command: String)
    /// A number on `owner`'s card names no line, as `ResolveError.incompleteNumber` describes
    /// it, and nothing else on the card can be used instead.
    case incompleteNumber(String, owner: String, tooShort: Bool, options: [(address: Address, contacts: [Contact])], command: String)
    /// Excluding someone means tincan never messages them: `chats` are their excluded
    /// one-to-one conversations, empty when only an address of theirs is excluded.
    case excludedPerson(Person, chats: [Chat])
}

/// A warning that comes with a plan: it can go ahead, but the person should know. Most are
/// in the planner's words; the rest carry facts that every command words the same way.
public enum PlanWarning: Sendable {
    /// A warning in the planner's words.
    case notice(code: String, message: String)
    /// `shared_address`: the address `person.sharedAddresses` lists is on other contact
    /// cards too. `consequence` ends the sentence.
    case sharedAddress(Person, consequence: String)
    /// `filtered_conversation`: Messages filed `chat` under Unknown Senders or Junk.
    /// `consequence` ends the sentence.
    case filteredConversation(Chat, consequence: String)

    /// The stable code results carry.
    public var code: String {
        switch self {
        case .notice(let code, _): return code
        case .sharedAddress: return "shared_address"
        case .filteredConversation: return "filtered_conversation"
        }
    }
}
