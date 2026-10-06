import Foundation
import TincanKit

/// Where tincan reads from. Normally Apple's own files; the environment can point every
/// source at fixtures so the whole CLI runs against invented data:
///
///     TINCAN_MESSAGES_DB       a chat.db to read instead of ~/Library/Messages/chat.db
///     TINCAN_CALL_HISTORY_DB   a CallHistory.storedata to read instead of the system one
///     TINCAN_CONTACTS_FILE     a JSON file of contacts; Apple Contacts is never touched
///
/// Tests and demos use these. While any is set, tincan refuses to send, because Messages
/// could not confirm a send in a database it doesn't write to.
struct DataSources {
    static let messagesVariable = "TINCAN_MESSAGES_DB"
    static let callHistoryVariable = "TINCAN_CALL_HISTORY_DB"
    static let contactsVariable = "TINCAN_CONTACTS_FILE"

    /// Overridden Messages database, if any.
    let messagesOverride: String?
    let callHistoryOverride: String?
    let contactsFile: String?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        func path(_ name: String) -> String? {
            guard let value = environment[name]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
            return NSString(string: value).expandingTildeInPath
        }
        messagesOverride = path(Self.messagesVariable)
        callHistoryOverride = path(Self.callHistoryVariable)
        contactsFile = path(Self.contactsVariable)
    }

    var messagesPath: String { messagesOverride ?? MessagesDatabase.defaultPath }
    /// The send ledger for those Messages: beside an overriding database, as
    /// `tincan-sent.jsonl`, so fixture data never reads or writes this Mac's.
    var sendLedgerPath: String {
        guard let messagesOverride else { return SendLedger.defaultPath }
        return ((messagesOverride as NSString).deletingLastPathComponent as NSString).appendingPathComponent("tincan-sent.jsonl")
    }
    var callHistoryPath: String { callHistoryOverride ?? CallHistoryDatabase.defaultPath }

    /// Whether any source points away from this Mac's own data.
    var isOverridden: Bool { messagesOverride != nil || callHistoryOverride != nil || contactsFile != nil }

    /// The variables that are set, with their paths.
    var overrides: [(variable: String, path: String)] {
        [
            messagesOverride.map { (Self.messagesVariable, $0) },
            callHistoryOverride.map { (Self.callHistoryVariable, $0) },
            contactsFile.map { (Self.contactsVariable, $0) },
        ].compactMap { $0 }
    }

    /// Full Disk Access as it applies to the Messages database tincan will read. With an
    /// override this is plain readability of that file.
    func fullDiskAccess() -> Permissions.State {
        guard let messagesOverride else { return Permissions.fullDiskAccess() }
        let descriptor = open(messagesOverride, O_RDONLY)
        if descriptor >= 0 {
            close(descriptor)
            return .granted
        }
        return errno == EPERM || errno == EACCES ? .denied : .unknown
    }
}
