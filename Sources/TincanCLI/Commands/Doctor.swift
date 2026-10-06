import ArgumentParser
import Foundation
import TincanKit

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check permissions and setup, and fix what's missing.",
        discussion: """
            macOS gives tincan the permissions of the app that runs it: your terminal, editor or assistant app, or SSH. A program that launchd starts, such as an assistant's background service, holds its own, and so does tincan when a launchd job runs it directly. Doctor names that app or program, checks each permission and says how to grant what's missing. Run `tincan doctor --fix` in a terminal to be walked through it; the permissions go to the app you run it in.

            Contacts can't be granted by hand: macOS has to ask the app. `--request contacts` asks macOS now, with or without a terminal, so an assistant can run it once the person agrees. macOS shows its question on this Mac's screen, tincan waits for the person's answer, and the Contacts check reports it. It asks only when macOS hasn't asked before and the app can ask, and never on its own. --dry-run says whether it would ask.

            Exit status is 0 when no check fails and 2 when one does; warnings leave it at 0.

            For tests and demos, TINCAN_MESSAGES_DB, TINCAN_CALL_HISTORY_DB and TINCAN_CONTACTS_FILE point tincan at other data: a chat.db, a CallHistory.storedata and a JSON array of contacts. Apple Contacts is then never touched and sending is off; doctor says so.

            Examples:
              tincan doctor
              tincan doctor --fix
              tincan doctor --json
              tincan doctor --request contacts --dry-run --json
              tincan doctor --request contacts --json
            """
    )

    @Flag(help: "Walk through granting each missing permission to the app that runs tincan (opens System Settings).")
    var fix = false

    @Option(
        help: ArgumentHelp(
            "Ask macOS for a permission now, with or without a terminal. macOS asks on this Mac's screen and tincan waits for the answer; run it only once the person agrees.",
            valueName: "permission"))
    var request: Request?

    @Flag(help: "With --request, say whether tincan would ask, without asking.")
    var dryRun = false

    /// A permission `--request` asks macOS for.
    enum Request: String, CaseIterable, ExpressibleByArgument { case contacts }

    @OptionGroup var global: GlobalOptions

    struct Check: Encodable {
        let id: String
        let status: String
        let title: String
        let detail: String?
        let fix: String?
    }

    /// The app whose permissions tincan runs with.
    struct Host: Encodable {
        /// `app`, `program`, `ssh` or `unknown`.
        let kind: String
        let name: String?
        let bundleId: String?
        let path: String?

        init(_ host: PermissionHost) {
            kind = host.kind.rawValue
            name = host.name
            bundleId = host.bundleID
            path = host.path
        }
    }

    struct Result: Encodable {
        let healthy: Bool
        let version: String
        let executable: String?
        let host: Host
        let checks: [Check]
    }

    func run() async throws {
        try await runCommand("doctor", options: global) { context in
            if request == nil, dryRun {
                throw TincanError.usage("--dry-run applies only to --request.", hint: "Preview a request with `tincan doctor --request contacts --dry-run`.")
            }
            if fix, request != nil {
                throw TincanError.usage(
                    "--fix already asks macOS for what's missing, so it takes no --request.",
                    hint: "Run `tincan doctor --fix` in a terminal, or `tincan doctor --request contacts` alone.")
            }
            if fix {
                guard !context.output.json, Terminal.canPrompt else {
                    throw TincanError.usage(
                        "--fix is interactive; run it in a terminal.", hint: "`tincan doctor --json` reports the same checks without changing anything.")
                }
                try await runFixes(context: context)
                context.output.line()
            }
            var contactsRequest: ContactsRequest?
            // A contacts file that can't be read is reported by the Contacts check below.
            if request == .contacts, let provider = try? context.contactsProvider() {
                let host = PermissionHost.current
                contactsRequest = Self.requestContacts(provider, host: host, dryRun: dryRun) {
                    context.output.status("Asking macOS whether \(host.subject) may access your contacts. Answer on this Mac's screen.")
                }
            }
            let checks = gather(context: context, contactsRequest: contactsRequest)
            let healthy = !checks.contains { $0.status == "fail" }
            context.output.result(
                Result(healthy: healthy, version: TincanVersion.current, executable: Permissions.executablePath, host: Host(.current), checks: checks))
            if !context.output.json { render(checks, healthy: healthy, context: context) }
            if !healthy { throw ExitCode(TincanError.Exit.partial.rawValue) }
        }
    }

    // MARK: Checks

    private func gather(context: Context, contactsRequest: ContactsRequest?) -> [Check] {
        let host = PermissionHost.current
        let interactive = Terminal.canPrompt
        var checks = [Self.hostCheck(host)]

        if context.sources.isOverridden {
            checks.append(
                Check(
                    id: "data_sources", status: "warn", title: "Reading other data",
                    detail: context.sources.overrides.map { "\($0.variable)=\($0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))" }
                        .joined(separator: ", ") + ". Sending is off.",
                    fix: "They were set on purpose. Unset them only if the person wants tincan to read this Mac's own Messages, calls and Contacts."))
        }

        let fullDiskAccess = context.sources.fullDiskAccess()
        var readable: String?
        if fullDiskAccess == .granted, let database = try? context.messages(), let count = try? database.database.scalarInteger("SELECT COUNT(*) FROM message")
        {
            let calls = (try? context.calls().database.scalarInteger("SELECT COUNT(*) FROM ZCALLRECORD")) ?? nil
            readable = "\(count.formatted()) messages" + (calls.map { " and \($0.formatted()) calls" } ?? "; no call history on this Mac") + " readable."
        }
        checks.append(Self.fullDiskAccessCheck(fullDiskAccess, detail: readable, host: host, interactive: interactive))

        let contacts: Permissions.State
        do {
            contacts = Permissions.contacts(try context.contactsProvider())
        } catch {
            let failure = TincanError.wrap(error)
            checks.append(Check(id: "contacts", status: "fail", title: "Contacts" + host.titleSuffix, detail: failure.message, fix: failure.hint))
            contacts = .unknown
        }
        var named: String?
        if contacts == .granted, let directory = try? context.directory(), let resolver = try? context.resolver() {
            let direct = resolver.chats.filter { $0.kind == .direct }
            let withName = direct.filter { chat in
                let address = chat.participants.first ?? chat.identifier
                return directory.uniqueContact(for: address) != nil
            }.count
            let shared = Set(resolver.knownAddresses.filter { directory.matches(for: $0).count > 1 }.map { Address($0, region: directory.region).value }).count
            named = "\(directory.contacts.count.formatted()) contacts; \(withName) of \(direct.count) one-to-one conversations have a name."
            if shared > 0 { named! += " \(shared) number\(shared == 1 ? " is" : "s are") on more than one card." }
        }
        if let check = Self.contactsCheck(contacts, detail: named, host: host, interactive: interactive, request: contactsRequest) { checks.append(check) }

        // tincan never sends while it reads other data, so what macOS allows doesn't matter.
        checks.append(Self.automationCheck(context.sources.isOverridden ? nil : Permissions.automation(), host: host, interactive: interactive))
        checks.append(Self.accessibilityCheck(Permissions.accessibility(), host: host, interactive: interactive))

        if let database = try? context.messages(), let own = try? database.ownAddresses(), !own.isEmpty {
            let formatted = own.prefix(3).map { Address($0, region: context.region).formatted }
            checks.append(Check(id: "account", status: "ok", title: "Your Messages addresses", detail: formatted.joined(separator: ", "), fix: nil))
        }

        do {
            let config = try context.config()
            let excluded = ConfigCommand.excludedSummary(config).map { "; excluded: \($0)" } ?? ""
            checks.append(
                Check(
                    id: "config", status: "ok", title: "Settings",
                    detail: "Typing \(config.typing.rawValue) at \(Config.formatNumber(config.wordsPerMinute)) wpm" + excluded + ". "
                        + Config.defaultPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                    fix: nil))
        } catch {
            let failure = TincanError.wrap(error)
            checks.append(Check(id: "config", status: "fail", title: "Settings", detail: failure.message, fix: failure.hint))
        }
        return checks
    }

    private func render(_ checks: [Check], healthy: Bool, context: Context) {
        let style = context.style
        let output = context.output
        let width = min(context.terminal.width, 100)
        let title = "tincan \(TincanVersion.current)"
        // Paths lose their middle, not the file name at the end.
        let path = TextWidth.truncateMiddle(
            (Permissions.executablePath ?? "").replacingOccurrences(of: NSHomeDirectory(), with: "~"), to: width - TextWidth.columns(title) - 7)
        output.line(Layout.header(title, details: [path], trailing: "", width: width, style: style))
        output.line()
        for check in checks {
            let symbol: String
            switch check.status {
            case "ok": symbol = style.success("✓")
            case "warn": symbol = style.warning("!")
            case "skip": symbol = style.muted("–")
            default: symbol = style.danger("✗")
            }
            output.line("\(symbol) \(style.bold(TextWidth.truncate(check.title, to: width - 2)))")
            if let detail = check.detail {
                for line in Layout.hanging(Self.shortenLongWords(detail, to: width - 2), first: "  ", rest: "  ", width: width) {
                    output.line(style.muted(line))
                }
            }
            if let fix = check.fix {
                for line in TextWidth.wrapKeepingCode(Self.shortenLongWords(fix, to: width - 4), width: width - 4).enumerated().map({
                    ($0.offset == 0 ? "  → " : "    ") + $0.element
                }) {
                    output.line(style.muted(line))
                }
            }
        }
        output.line()
        output.line(healthy ? style.success("Ready.") : style.warning("Needs attention."))
        output.hint(healthy ? "Try `tincan chats`." : "Run `tincan doctor --fix`.")
    }

    /// `text` with each word wider than `width`, such as a long path, shortened in the
    /// middle, so wrapping never splits it across lines. `--json` keeps the whole text.
    static func shortenLongWords(_ text: String, to width: Int) -> String {
        text.split(separator: " ", omittingEmptySubsequences: false)
            .map { TextWidth.columns(String($0)) > width ? TextWidth.truncateMiddle(String($0), to: width) : String($0) }
            .joined(separator: " ")
    }

    // MARK: Guided fixes

    private func runFixes(context: Context) async throws {
        let style = context.style
        let output = context.output
        let host = PermissionHost.current
        let sources = context.sources
        output.line(style.bold("Setting up tincan") + style.muted("  macOS gives tincan the permissions of \(host.subject)"))
        output.line()

        var restart = false
        if sources.fullDiskAccess() != .granted {
            output.line(style.accent("1. Full Disk Access") + style.muted("  lets tincan read Messages and call history"))
            if host.kind == .ssh {
                // The person may not be at the Mac, so nothing opens there.
                output.line("   On the Mac, open System Settings → General → Sharing, click ⓘ next to Remote Login")
                output.line("   and turn on Allow full disk access for remote users. It applies to new SSH sessions.")
            } else {
                let found = (host.kind == .app || host.kind == .program) && host.path != nil
                output.line("   System Settings will open at Full Disk Access" + (found ? ", with \(host.entry) shown in Finder." : "."))
                output.line("   Turn on \(host.entry). If it isn't listed, drag it in or click + and choose it.")
                output.line("   macOS applies it when \(host.subject) starts, so \(Self.restart(host)) afterwards.")
                Permissions.openSettings(for: .fullDiskAccess)
                if found, let path = host.path { Permissions.reveal(path) }
            }
            if await !waitFor("Full Disk Access", context: context, returnMeans: "continue", { sources.fullDiskAccess() == .granted }) {
                restart = true
            }
        }
        let provider = try context.contactsProvider()
        if Permissions.contacts(provider) != .granted {
            output.line(style.accent("2. Contacts") + style.muted("  shows names instead of numbers, and lets you add or edit contacts"))
            if provider.authorization == .notDetermined {
                output.line("   Click OK when macOS asks whether \(host.subject) may access your contacts.")
                switch provider.requestAccess() {
                case .authorized, .limited:
                    output.status(style.success("   ✓ ") + "Contacts allowed\n")
                case .denied, .restricted:
                    output.line(style.warning("   Not allowed. ") + PermissionAdvice.allowContacts(host: host))
                case .notDetermined:
                    output.line(style.warning("   macOS didn't ask. ") + PermissionAdvice.requestContacts(host: host, interactive: true))
                }
            } else {
                output.line("   Turn on \(host.entry) in the Contacts list that opens.")
                Permissions.openSettings(for: .contacts)
                await waitFor("Contacts", context: context) { Permissions.contacts(provider) == .granted }
            }
        }
        // Sending and typing are off while tincan reads other data.
        if !sources.isOverridden, Permissions.automation() != .granted {
            output.line(style.accent("3. Sending") + style.muted("  lets \(host.subject) hand your messages to Messages"))
            output.line("   Click OK when macOS asks whether \(host.subject) may control Messages.")
            if Permissions.automation(prompt: true) == .denied {
                output.line("   It was turned off earlier; turn on Messages under \(host.entry) in the list that opens.")
                Permissions.openSettings(for: .automation)
                await waitFor("Messages control", context: context) { Permissions.automation() == .granted }
            }
        }
        if !sources.isOverridden, Permissions.accessibility() != .granted {
            output.line(style.accent("4. Accessibility") + style.muted("  optional: lets people see you typing"))
            if confirm("Set up the typing indicator now?", style: style) {
                output.line("   Turn on \(host.entry) in the list that opens. If it isn't listed, drag it in or click + and choose it.")
                _ = Permissions.accessibility(prompt: true)
                Permissions.openSettings(for: .accessibility)
                if host.kind == .app || host.kind == .program, let path = host.path { Permissions.reveal(path) }
                await waitFor("Accessibility", context: context) { Permissions.accessibility() == .granted }
            }
        }
        if restart {
            output.line()
            output.line(
                style.warning(
                    host.kind == .ssh
                        ? "Start a new SSH session once Full Disk Access is on, then run `tincan doctor` again."
                        : Self.capitalizingFirst(Self.restart(host)) + " once Full Disk Access is on, then run `tincan doctor` again."))
        }
    }

    /// Polls for up to three minutes; Return stops waiting. Reads the keyboard only when a
    /// line is ready, so no background reader is left behind to swallow later answers.
    /// Returns whether `granted` came true.
    @discardableResult
    private func waitFor(_ name: String, context: Context, returnMeans: String = "skip", _ granted: @escaping () -> Bool) async -> Bool {
        let style = context.style
        context.output.status(style.muted("   Waiting for \(name)… (press Return to \(returnMeans))"))
        for _ in 0..<360 {
            if granted() {
                context.output.status(style.success("   ✓ ") + "\(name) granted\n")
                return true
            }
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, 0) > 0 {
                _ = readLine()
                break
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if returnMeans == "skip" { context.output.status(style.warning("   Skipped \(name) for now.") + "\n") } else { context.output.status("\n") }
        return false
    }
}

extension Doctor {
    /// Which app's permissions tincan runs with.
    static func hostCheck(_ host: PermissionHost) -> Check {
        switch host.kind {
        case .app:
            var detail =
                "macOS gives tincan the permissions of the app that runs it, so the checks below are \(host.entry)'s. Each app you run tincan from needs its own."
            // Directions for the + button, when the app isn't where its name says.
            if let path = host.path, !isStandardLocation(path) || host.fileName != host.name {
                detail += " \(host.entry) is at \(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))."
            }
            return Check(id: "host", status: "ok", title: "Permissions come from \(host.entry)", detail: detail, fix: nil)
        case .program:
            let location = host.path.map { $0.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
            var detail: String
            if host.isTincan {
                detail = "A launchd job runs tincan directly, so macOS gives tincan its own permissions, and the checks below are tincan's."
                if let location { detail += " tincan is at \(location)." }
            } else {
                detail = "macOS gives tincan the permissions of \(host.entry), the program launchd started to run it, so the checks below are \(host.entry)'s."
                // A service inside an app gets the grants itself; the app's do nothing for it.
                if let location { detail += " \(host.entry) is the program at \(location)" + (location.contains(".app/") ? ", not the app around it." : ".") }
            }
            return Check(id: "host", status: "ok", title: "Permissions come from \(host.entry)", detail: detail, fix: nil)
        case .ssh:
            return Check(
                id: "host", status: "ok", title: "Permissions come from SSH",
                detail: "macOS gives tincan the permissions of what runs it. Over SSH that is sshd-keygen-wrapper, which every SSH login shares.", fix: nil)
        case .unknown:
            return Check(
                id: "host", status: "warn", title: "Permissions come from the app that runs tincan",
                detail: "tincan couldn't tell which app that is. macOS names it when it asks for a permission.",
                fix:
                    "Grant the permissions below to the terminal, editor or assistant app you run tincan from. A launchd job that runs tincan directly needs them for tincan itself."
            )
        }
    }

    /// Apps in these folders need no directions to find.
    static func isStandardLocation(_ path: String) -> Bool {
        ["/Applications/", "/System/Applications/", NSHomeDirectory() + "/Applications/"].contains { path.hasPrefix($0) }
    }

    static func fullDiskAccessCheck(_ state: Permissions.State, detail: String?, host: PermissionHost, interactive: Bool) -> Check {
        let title = "Full Disk Access" + host.titleSuffix
        guard state != .granted else {
            return Check(id: "full_disk_access", status: "ok", title: title, detail: detail ?? "Messages and call history are readable.", fix: nil)
        }
        return Check(
            id: "full_disk_access", status: "fail", title: title, detail: "Needed to read Messages and call history.",
            fix: PermissionAdvice.grant(.fullDiskAccess, host: host, interactive: interactive))
    }

    /// What `--request contacts` did, which the Contacts check reports.
    enum ContactsRequest: Equatable {
        /// Access was already allowed, so nothing changed.
        case alreadyAllowed
        /// macOS already has the person's answer; it asks each app only once.
        case alreadyAnswered
        /// macOS can't ask the host, so tincan didn't ask.
        case hostCannotAsk
        /// A dry run in which tincan would have asked.
        case wouldAsk
        /// tincan asked, and macOS answered this; `notDetermined` when it showed no question.
        case asked(ContactsAuthorization)
    }

    /// Asks macOS for Contacts access for `host`, once, when macOS hasn't asked yet and can
    /// ask the host; otherwise changes nothing. macOS shows its question on the Mac's screen
    /// and `requestAccess()` waits for the answer. `asking` runs just before it asks.
    static func requestContacts(_ provider: ContactsProvider, host: PermissionHost, dryRun: Bool, asking: () -> Void = {}) -> ContactsRequest {
        switch provider.authorization {
        case .authorized, .limited:
            return .alreadyAllowed
        case .denied, .restricted:
            return .alreadyAnswered
        case .notDetermined:
            // macOS refuses an app that doesn't say why it uses Contacts without asking, and
            // can't show an SSH session its question.
            guard host.canAskForContacts != false, host.kind != .ssh else { return .hostCannotAsk }
            if dryRun { return .wouldAsk }
            asking()
            return .asked(provider.requestAccess())
        }
    }

    /// Nil when the state isn't known, which the caller already reported. `request` is what
    /// `--request contacts` did, if it ran.
    static func contactsCheck(_ state: Permissions.State, detail: String?, host: PermissionHost, interactive: Bool, request: ContactsRequest? = nil) -> Check? {
        let title = "Contacts" + host.titleSuffix
        switch state {
        case .unknown:
            return nil
        case .granted:
            let names = detail ?? "Names come from Apple Contacts."
            if case .asked = request { return Check(id: "contacts", status: "ok", title: title, detail: "Allowed just now. " + names, fix: nil) }
            return Check(id: "contacts", status: "ok", title: title, detail: names, fix: nil)
        case .notDetermined:
            let missing = "Not allowed yet, so people appear as phone numbers."
            switch request {
            case .hostCannotAsk:
                return Check(
                    id: "contacts", status: "fail", title: title, detail: missing + " tincan didn't ask macOS.",
                    fix: PermissionAdvice.requestContacts(host: host, interactive: interactive))
            case .wouldAsk:
                return Check(
                    id: "contacts", status: "fail", title: title,
                    detail: missing + " Without --dry-run, tincan would ask macOS now, and the person would answer on this Mac's screen.",
                    fix: PermissionAdvice.requestContacts(host: host, interactive: interactive))
            case .asked:
                return Check(
                    id: "contacts", status: "fail", title: title, detail: "macOS didn't show its question, so people appear as phone numbers.",
                    fix: PermissionAdvice.contactsNotAsked(host: host))
            default:
                return Check(
                    id: "contacts", status: "fail", title: title, detail: missing,
                    fix: PermissionAdvice.requestContacts(host: host, interactive: interactive))
            }
        case .denied:
            let detail: String
            switch request {
            case .asked: detail = "Not allowed when macOS asked, so people appear as phone numbers."
            case .alreadyAnswered: detail = "Denied, so people appear as phone numbers. macOS asks only once, so tincan didn't ask again."
            default: detail = "Denied, so people appear as phone numbers."
            }
            return Check(id: "contacts", status: "fail", title: title, detail: detail, fix: PermissionAdvice.allowContacts(host: host))
        }
    }

    /// `state` is nil while tincan reads other data, when sending is off.
    static func automationCheck(_ state: Permissions.State?, host: PermissionHost, interactive: Bool) -> Check {
        let subject = host.sentenceSubject
        switch state {
        case nil:
            return Check(
                id: "automation", status: "skip", title: "Sending", detail: "Sending is off while tincan reads other data.",
                fix: "Preview with `send --dry-run`. tincan sends only while it reads this Mac's own Messages.")
        case .granted:
            return Check(id: "automation", status: "ok", title: "Sending", detail: "\(subject) may control Messages, so tincan can send.", fix: nil)
        case .notDetermined:
            return Check(
                id: "automation", status: "warn", title: "Sending",
                detail: "macOS asks whether \(host.subject) may control Messages the first time tincan sends.",
                fix: interactive
                    ? "Run `tincan doctor --fix` to answer now."
                    : "The person answers on this Mac's screen at the first send, or earlier with `tincan doctor --fix` in \(host.entry).")
        case .denied:
            return Check(
                id: "automation", status: "fail", title: "Sending", detail: "\(subject) isn't allowed to control Messages.",
                fix: PermissionAdvice.grant(.automation, host: host, interactive: interactive))
        case .unknown:
            return Check(
                id: "automation", status: "skip", title: "Sending", detail: "Messages isn't running, so this can't be checked yet.",
                fix: "Open Messages, or run `tincan doctor --fix`.")
        }
    }

    static func accessibilityCheck(_ state: Permissions.State, host: PermissionHost, interactive: Bool) -> Check {
        guard state != .granted else {
            return Check(
                id: "accessibility", status: "ok", title: "Typing indicator",
                detail: "\(host.sentenceSubject) has Accessibility, so tincan can type into Messages and people see you typing.", fix: nil)
        }
        return Check(
            id: "accessibility", status: "warn", title: "Typing indicator",
            detail: "Without Accessibility for \(host.subject), sends are paced but no typing bubble appears.",
            fix: "Optional: " + lowercasingFirst(PermissionAdvice.grant(.accessibility, host: host, interactive: interactive)))
    }

    /// What makes Full Disk Access apply: an app is quit and reopened, a program restarted.
    static func restart(_ host: PermissionHost) -> String {
        host.kind == .program ? "restart \(host.subject)" : "quit and reopen \(host.subject)"
    }

    static func lowercasingFirst(_ text: String) -> String {
        text.prefix(1).lowercased() + text.dropFirst()
    }

    static func capitalizingFirst(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }
}
