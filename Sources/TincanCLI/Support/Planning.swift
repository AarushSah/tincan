import Foundation
import TincanKit

extension Context {
    /// Runs a planner, then reports what it found the way every command reports: its
    /// warnings through `Output`, including those found before it stopped, and a refusal as
    /// the `TincanError` it describes.
    func plan<T>(_ body: (inout [PlanWarning]) throws -> T) throws -> T {
        var warnings: [PlanWarning] = []
        defer { warn(warnings) }
        do {
            return try body(&warnings)
        } catch let refusal as PlanRefusal {
            throw error(for: refusal)
        }
    }

    /// Adds a planner's warnings to the result, in order.
    func warn(_ warnings: [PlanWarning]) {
        for warning in warnings {
            switch warning {
            case .notice(let code, let message): output.warn(code, message)
            case .sharedAddress(let person, let consequence): warnSharedAddress(person, consequence: consequence)
            case .filteredConversation(let chat, let consequence): warnFiltered([chat], consequence: consequence)
            }
        }
    }

    /// The error a planner's refusal describes, worded as every command words it.
    func error(for refusal: PlanRefusal) -> TincanError {
        switch refusal {
        case .issue(let issue):
            return TincanError(issue)
        case .unresolved(let error, let command):
            return describe(error, command: command)
        case .incompleteNumber(let number, let owner, let tooShort, let options, let command):
            return incompleteNumber(number, owner: owner, tooShort: tooShort, options: options, command: command)
        case .excludedPerson(let person, let chats):
            return .excludedPerson(person, chats: chats)
        }
    }
}

extension TincanError {
    /// A planner's refusal, word for word.
    init(_ issue: PlanIssue) {
        let exit: Exit
        switch issue.kind {
        // A wrong value on the command line exits as every usage error does.
        case .usage: exit = TincanError.usage(issue.message, hint: issue.hint).exit
        case .failure: exit = .failure
        case .needsInput: exit = .needsInput
        case .permission: exit = .permission
        }
        self.init(code: issue.code, message: issue.message, hint: issue.hint, exit: exit, candidates: issue.candidates.map(Candidate.init))
    }
}

extension TincanError.Candidate {
    init(_ candidate: PlanIssue.Candidate) {
        self.init(
            reference: candidate.reference, name: candidate.name, detail: candidate.detail, addresses: candidate.addresses,
            organization: candidate.organization, conversations: candidate.conversations, lastActivity: candidate.lastActivity
        )
    }
}
