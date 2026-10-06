import AppKit
import Darwin
import Foundation

/// A macOS privacy permission tincan uses.
public enum Permission: String, Sendable, CaseIterable {
    case fullDiskAccess = "full_disk_access"
    case contacts
    case automation
    case accessibility

    /// The list's name under System Settings → Privacy & Security.
    public var pane: String {
        switch self {
        case .fullDiskAccess: "Full Disk Access"
        case .contacts: "Contacts"
        case .automation: "Automation"
        case .accessibility: "Accessibility"
        }
    }

    /// Opens that list: `x-apple.systempreferences:com.apple.preference.security?<anchor>`.
    public var settingsAnchor: String {
        switch self {
        case .fullDiskAccess: "Privacy_AllFiles"
        case .contacts: "Privacy_Contacts"
        case .automation: "Privacy_Automation"
        case .accessibility: "Privacy_Accessibility"
        }
    }
}

/// The app whose privacy permissions tincan runs with.
///
/// macOS judges a command-line tool by its responsible process: the app that started it,
/// such as Terminal, iTerm, an editor or an assistant's app, and for SSH logins the SSH
/// service. A program that launchd starts, such as an assistant's background service, is
/// its own responsible process, and so is tincan when a launchd job runs it directly.
/// Every permission tincan uses belongs to that process, so each one tincan runs from
/// needs its own grants, and the prompts macOS shows name it.
///
/// macOS offers no public way to ask which process that is, so tincan finds the nearest
/// app among the processes that started it, then the app named by `__CFBundleIdentifier`
/// (which apps pass to what they run, and which survives tmux), then an SSH session, then
/// the program launchd started at the top of those processes. The answer only words
/// explanations; nothing is allowed or refused because of it.
public struct PermissionHost: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case app
        /// A program that isn't an app and that launchd started: macOS asks about the
        /// program itself, such as an assistant's background service or tincan run directly
        /// by a launchd job.
        case program
        case ssh
        case unknown
    }

    public let kind: Kind
    /// The name the app gives itself, which macOS's questions use, such as "Terminal". A
    /// program's comes from the Info.plist linked into it, or else its file name.
    public let name: String?
    public let bundleID: String?
    /// The app bundle, the program's executable, or the program SSH logins run under.
    public let path: String?
    /// Whether the app can show macOS's Contacts question: it says why it uses Contacts
    /// (`NSContactsUsageDescription`), or is part of macOS. Nil when that can't be checked.
    public let canAskForContacts: Bool?

    public init(kind: Kind, name: String?, bundleID: String? = nil, path: String? = nil, canAskForContacts: Bool? = nil) {
        self.kind = kind
        self.name = name
        self.bundleID = bundleID
        self.path = path
        self.canAskForContacts = canAskForContacts
    }

    /// The app's name in Finder, which the + button's file picker shows. It can differ from
    /// `name`, as "Visual Studio Code" does from "Code".
    public var fileName: String? {
        guard kind == .app, let path else { return nil }
        let file = (path as NSString).lastPathComponent
        return file.hasSuffix(".app") ? String(file.dropLast(4)) : file
    }

    /// tincan's identifier, from the Info.plist linked into it.
    public static let tincanBundleID = "io.github.aarushsah.tincan"

    /// Whether the host is tincan itself: a launchd job runs tincan directly, so tincan is
    /// its own responsible process and needs the grants itself.
    public var isTincan: Bool { kind == .program && bundleID == Self.tincanBundleID }

    public static let unknown = PermissionHost(kind: .unknown, name: nil)

    /// SSH logins run under `sshd-keygen-wrapper`, whose grants every SSH session shares.
    public static let ssh = PermissionHost(kind: .ssh, name: "sshd-keygen-wrapper", path: "/usr/libexec/sshd-keygen-wrapper")

    /// The host of this process, found once.
    public static let current: PermissionHost = detect()

    static func detect(
        environment: [String: String] = ProcessInfo.processInfo.environment, processes: ProcessTree = .system,
        embeddedInfo: (String) -> [String: Any]? = embeddedInfo(forExecutable:)
    ) -> PermissionHost {
        let origin = origin(in: processes)
        if case .app(let bundle) = origin { return app(at: bundle) }
        if let identifier = environment["__CFBundleIdentifier"], !identifier.isEmpty,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
        {
            return app(at: url.path)
        }
        if ["SSH_CONNECTION", "SSH_CLIENT", "SSH_TTY"].contains(where: { !(environment[$0] ?? "").isEmpty }) { return .ssh }
        // Last, because a process that outlived its parent, such as a tmux server, also has
        // launchd as its parent while macOS still asks about the app that started it.
        if case .program(let executable) = origin { return program(at: executable, info: embeddedInfo(executable)) }
        return .unknown
    }

    /// The app at `bundlePath`, by the name it gives itself, or else its name in Finder.
    public static func app(at bundlePath: String) -> PermissionHost {
        let bundle = Bundle(path: bundlePath)
        let declared = ["CFBundleDisplayName", "CFBundleName"].lazy
            .compactMap { bundle?.object(forInfoDictionaryKey: $0) as? String }
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var name = declared ?? FileManager.default.displayName(atPath: bundlePath)
        if declared == nil, name.hasSuffix(".app") { name.removeLast(4) }
        let declaresContacts = bundle?.object(forInfoDictionaryKey: "NSContactsUsageDescription") != nil
        return PermissionHost(
            kind: .app, name: name, bundleID: bundle?.bundleIdentifier, path: bundlePath,
            canAskForContacts: declaresContacts || bundlePath.hasPrefix("/System/")
        )
    }

    /// The program at `executable`, which isn't an app, described by `info`: the Info.plist
    /// linked into it, if any. Its name is the one that Info.plist gives it, or else its
    /// file name, and it can ask for Contacts only when that Info.plist says why.
    public static func program(at executable: String, info: [String: Any]?) -> PermissionHost {
        let declared = ["CFBundleDisplayName", "CFBundleName"].lazy
            .compactMap { info?[$0] as? String }
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return PermissionHost(
            kind: .program, name: declared ?? (executable as NSString).lastPathComponent, bundleID: info?["CFBundleIdentifier"] as? String,
            path: executable, canAskForContacts: info?["NSContactsUsageDescription"] != nil
        )
    }

    /// The program at `executable`, described by the Info.plist linked into it.
    public static func program(at executable: String) -> PermissionHost {
        program(at: executable, info: embeddedInfo(forExecutable: executable))
    }

    /// The Info.plist linked into a program that isn't in a bundle of its own (its
    /// `__TEXT,__info_plist` section), or nil when it has none. The Info.plist of an app
    /// the program sits in is never read: macOS asks about the program, not the app.
    static func embeddedInfo(forExecutable path: String) -> [String: Any]? {
        CFBundleCopyInfoDictionaryForURL(URL(fileURLWithPath: path) as CFURL) as? [String: Any]
    }

    /// The outermost app bundle of an app's own executable, such as `/Applications/Claude.app`
    /// for `…/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper`.
    /// Other programs inside a bundle, such as Xcode's developer tools, aren't apps: nil.
    static func appBundle(forExecutable path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        let count = components.count
        guard count >= 4, components[count - 2] == "MacOS", components[count - 3] == "Contents", components[count - 4].hasSuffix(".app"),
            let outermost = components.firstIndex(where: { $0.hasSuffix(".app") })
        else { return nil }
        return components[...outermost].joined(separator: "/")
    }

    /// The processes that started this one, as `detect` reads them. Tests pass invented ones.
    struct ProcessTree: Sendable {
        /// This process.
        let current: pid_t
        /// A process's executable, or nil when it can't be read.
        let executable: @Sendable (pid_t) -> String?
        /// A process's parent, or nil when it can't be read.
        let parent: @Sendable (pid_t) -> pid_t?

        static let system = ProcessTree(
            current: getpid(),
            executable: { pid in
                var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
                guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
                return String(nulTerminated: buffer)
            },
            parent: { pid in
                var info = kinfo_proc()
                var size = MemoryLayout<kinfo_proc>.stride
                var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
                guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
                return info.kp_eproc.e_ppid
            }
        )
    }

    /// Where the processes that started this one lead.
    enum Origin: Equatable {
        /// An app's own executable ran one of them: the outermost app bundle.
        case app(String)
        /// launchd started the topmost of them, which isn't an app: its executable.
        case program(String)
    }

    /// The first app among the processes that started this one, or else the program launchd
    /// started at their top. tincan itself counts only when launchd started it directly;
    /// otherwise an app that runs it is found above it. Nil when neither can be found.
    static func origin(in processes: ProcessTree) -> Origin? {
        var pid = processes.current
        for depth in 0..<32 {
            let executable = processes.executable(pid)
            if depth > 0, let executable, let bundle = appBundle(forExecutable: executable) { return .app(bundle) }
            guard let parent = processes.parent(pid), parent != pid, parent > 0 else { return nil }
            if parent == 1 {
                guard let executable else { return nil }
                return appBundle(forExecutable: executable).map(Origin.app) ?? .program(executable)
            }
            pid = parent
        }
        return nil
    }

    // MARK: Wording

    /// How a sentence names the host: "Terminal", "SSH", or "the app that runs tincan".
    public var subject: String {
        switch kind {
        case .app: name ?? "the app that runs tincan"
        case .program: name ?? "the program that runs tincan"
        case .ssh: "SSH"
        case .unknown: "the app that runs tincan"
        }
    }

    /// `subject` to start a sentence with.
    public var sentenceSubject: String {
        subject.hasPrefix("the ") ? "The " + subject.dropFirst(4) : subject
    }

    /// The entry to look for in a System Settings list.
    public var entry: String {
        switch kind {
        case .app, .ssh: name ?? "the app that runs tincan"
        case .program: name ?? "the program that runs tincan"
        case .unknown: "the app that runs tincan"
        }
    }

    /// Ends a check's title: " for Terminal", " for SSH sessions", or nothing.
    public var titleSuffix: String {
        switch kind {
        case .app, .program: name.map { " for \($0)" } ?? ""
        case .ssh: " for SSH sessions"
        case .unknown: ""
        }
    }

    /// What the + button adds: an SSH session's or a program's executable, which the file
    /// picker reaches with ⌘⇧G and this path.
    private var addablePath: String {
        path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? entry
    }

    /// The step that grants `permission`, as one or two sentences.
    public func grantStep(_ permission: Permission) -> String {
        let list = "System Settings → Privacy & Security → \(permission.pane)"
        switch (permission, kind) {
        case (.fullDiskAccess, .ssh):
            return
                "In System Settings → General → Sharing, click ⓘ next to Remote Login and turn on Allow full disk access for remote users, then start a new SSH session."
        case (.fullDiskAccess, .unknown):
            return "Turn on the app that runs tincan (your terminal, editor or assistant app) in \(list), then quit and reopen it."
        case (.fullDiskAccess, .app):
            return "Turn on \(entry) in \(list) (click + to add it if it isn't listed), then quit and reopen \(entry)."
        case (.fullDiskAccess, .program):
            // A launchd job starts tincan anew each time; a service has to start again.
            return "Turn on \(entry) in \(list) (click + and add \(addablePath) if it isn't listed), "
                + (isTincan ? "and it applies from tincan's next run." : "then restart \(entry).")
        case (.contacts, _):
            return "Turn on \(entry) in \(list)."
        case (.automation, _):
            return "Turn on Messages under \(entry) in \(list)."
        case (.accessibility, .ssh), (.accessibility, .program):
            return "Turn on \(entry) in \(list) (click + and add \(addablePath) if it isn't listed)."
        case (.accessibility, _):
            return "Turn on \(entry) in \(list) (click + to add it if it isn't listed)."
        }
    }
}
