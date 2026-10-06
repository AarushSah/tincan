import TincanKit

/// What to do about a missing permission, shared by errors, warnings and doctor. macOS
/// gives tincan the permissions of the app that runs it, so every step names that app.
/// `interactive` is whether `tincan doctor --fix` could run where this is read: with a
/// terminal, it grants the same app; an assistant without one passes the step on, or asks
/// the person before `tincan doctor --request contacts`.
enum PermissionAdvice {
    /// The step in System Settings, and in a terminal, the walk-through.
    static func grant(_ permission: Permission, host: PermissionHost = .current, interactive: Bool = Terminal.canPrompt) -> String {
        host.grantStep(permission) + (interactive ? " `tincan doctor --fix` walks through it." : "")
    }

    /// How to allow Contacts before macOS has asked. Contacts can't be added to its list by
    /// hand: the app has to ask. In a terminal, `doctor --fix` shows the question; without
    /// one, `doctor --request contacts` does, once the person agrees, and they answer it on
    /// the Mac's screen.
    static func requestContacts(host: PermissionHost = .current, interactive: Bool = Terminal.canPrompt) -> String {
        if host.kind == .ssh {
            return "macOS usually can't ask an SSH session for Contacts. For names, run tincan in a terminal app on the Mac itself."
        }
        if host.canAskForContacts == false {
            return
                "\(host.entry) doesn't say why it would use Contacts, so macOS may refuse it without asking. For names, run tincan from a terminal app that can ask, such as Terminal, and run `tincan doctor --fix` there."
        }
        return interactive
            ? "Run `tincan doctor --fix` and allow access when macOS asks."
            : "Ask the person whether \(host.entry) may use Contacts. If they agree, run `tincan doctor --request contacts`: macOS asks on this Mac's screen, and the person answers there."
    }

    /// When macOS was asked for Contacts and showed no question.
    static func contactsNotAsked(host: PermissionHost = .current) -> String {
        "\(host.sentenceSubject) may not be able to ask for Contacts. For names, run tincan from a terminal app that can ask, such as Terminal, and run `tincan doctor --fix` there."
    }

    /// How to allow Contacts after it was turned off.
    static func allowContacts(host: PermissionHost = .current) -> String {
        host.grantStep(.contacts)
            + (host.canAskForContacts == false
                ? " If \(host.entry) isn't listed, it can't ask for Contacts; for names, run tincan from a terminal app that can." : "")
    }
}
