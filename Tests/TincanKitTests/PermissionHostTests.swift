import Foundation
import Testing

@testable import TincanKit

/// macOS gives tincan the permissions of the app that runs it. These tests use invented
/// bundles and a copy of the privacy database's table, never this Mac's own.
@Suite("Permission host")
struct PermissionHostTests {
    @Test func anAppIsItsOutermostBundleWhenItsOwnExecutableRuns() {
        #expect(
            PermissionHost.appBundle(forExecutable: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")
                == "/System/Applications/Utilities/Terminal.app")
        // A helper app inside another app speaks for the app around it.
        #expect(
            PermissionHost.appBundle(forExecutable: "/Applications/Example Editor.app/Contents/Frameworks/Example Helper.app/Contents/MacOS/Example Helper")
                == "/Applications/Example Editor.app")
        #expect(
            PermissionHost.appBundle(forExecutable: "/Users/maya/Library/Application Support/Example/agent.app/Contents/MacOS/agent")
                == "/Users/maya/Library/Application Support/Example/agent.app")
    }

    @Test func programsThatAreNotAppsAreSkipped() {
        // Developer tools inside Xcode run for whoever started them.
        #expect(PermissionHost.appBundle(forExecutable: "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest") == nil)
        #expect(PermissionHost.appBundle(forExecutable: "/Applications/Example.app/Contents/Helpers/launcher") == nil)
        #expect(PermissionHost.appBundle(forExecutable: "/bin/zsh") == nil)
        #expect(PermissionHost.appBundle(forExecutable: "/usr/libexec/sshd-keygen-wrapper") == nil)
        #expect(PermissionHost.appBundle(forExecutable: "MacOS/tool") == nil)
    }

    @Test func anAppThatSaysWhyItUsesContactsCanAsk() throws {
        let asks = try Self.bundle("Example Terminal", identifier: "com.example.terminal", contactsReason: "A program in Example Terminal wants your contacts.")
        let silent = try Self.bundle("Example Agent", identifier: "com.example.agent", contactsReason: nil)
        let renamed = try Self.bundle("Example Code Editor", identifier: "com.example.code", contactsReason: nil, bundleName: "Code")
        defer {
            for bundle in [asks, silent, renamed] { try? FileManager.default.removeItem(atPath: (bundle as NSString).deletingLastPathComponent) }
        }
        let host = PermissionHost.app(at: asks)
        #expect(host.kind == .app)
        #expect(host.name == "Example Terminal")
        #expect(host.bundleID == "com.example.terminal")
        #expect(host.path == asks)
        #expect(host.canAskForContacts == true)
        #expect(host.fileName == "Example Terminal")
        #expect(PermissionHost.app(at: silent).canAskForContacts == false)
        // macOS's questions use the name the app gives itself; Finder shows the file's.
        let code = PermissionHost.app(at: renamed)
        #expect(code.name == "Code")
        #expect(code.fileName == "Example Code Editor")
    }

    @Test func sentencesNameTheHost() {
        let terminal = PermissionHost(kind: .app, name: "Terminal", path: "/System/Applications/Utilities/Terminal.app", canAskForContacts: true)
        #expect(terminal.subject == "Terminal")
        #expect(terminal.titleSuffix == " for Terminal")
        #expect(
            terminal.grantStep(.fullDiskAccess)
                == "Turn on Terminal in System Settings → Privacy & Security → Full Disk Access (click + to add it if it isn't listed), then quit and reopen Terminal."
        )
        #expect(terminal.grantStep(.automation) == "Turn on Messages under Terminal in System Settings → Privacy & Security → Automation.")
        #expect(PermissionHost.ssh.grantStep(.fullDiskAccess).contains("Remote Login and turn on Allow full disk access for remote users"))
        #expect(PermissionHost.ssh.titleSuffix == " for SSH sessions")
        #expect(PermissionHost.unknown.subject == "the app that runs tincan")
        #expect(PermissionHost.unknown.sentenceSubject == "The app that runs tincan")
        #expect(PermissionHost(kind: .app, name: "claude").sentenceSubject == "claude", "an app's own name keeps its case")
        #expect(PermissionHost.unknown.titleSuffix == "")
        #expect(PermissionHost.unknown.grantStep(.fullDiskAccess).hasSuffix("Full Disk Access, then quit and reopen it."))
        for permission in Permission.allCases {
            #expect(!terminal.grantStep(permission).contains("tincan in System Settings"), "grants go to the host, not tincan")
        }
    }

    // MARK: Programs launchd starts

    static let service = "/Applications/Example.app/Contents/Helpers/example-service"
    static var serviceInfo: [String: Any] {
        [
            "CFBundleIdentifier": "com.example.service", "CFBundleName": "Example Service",
            "NSContactsUsageDescription": "Example Service shows who wrote to you.",
        ]
    }
    /// The Info.plist linked into tincan, as `Support/Info.plist` has it.
    static var tincanInfo: [String: Any] {
        [
            "CFBundleIdentifier": "io.github.aarushsah.tincan", "CFBundleName": "tincan", "CFBundleDisplayName": "tincan",
            "NSContactsUsageDescription": "tincan reads your contacts.",
        ]
    }

    /// Invented processes, by pid: each one's parent and executable. `current` is tincan.
    static func processes(_ table: [pid_t: (parent: pid_t, executable: String)], current: pid_t = 300) -> PermissionHost.ProcessTree {
        PermissionHost.ProcessTree(current: current, executable: { table[$0]?.executable }, parent: { table[$0]?.parent })
    }

    @Test func aProgramLaunchdStartedIsAskedAboutItself() {
        // An assistant's background service, which launchd starts from inside its app, runs
        // tincan through a shell.
        let tree = Self.processes([
            300: (250, "/Users/maya/.local/bin/tincan"), 250: (200, "/bin/zsh"), 200: (1, Self.service),
        ])
        var read: [String] = []
        let host = PermissionHost.detect(environment: [:], processes: tree) { path in
            read.append(path)
            return Self.serviceInfo
        }
        #expect(read == [Self.service], "only the program's own Info.plist is read")
        #expect(
            host
                == PermissionHost(
                    kind: .program, name: "Example Service", bundleID: "com.example.service", path: Self.service, canAskForContacts: true))
        #expect(!host.isTincan)
        #expect(host.fileName == nil, "a program isn't an app")
    }

    @Test func aProgramWithoutAnInfoPlistIsNamedByItsFileAndCantAsk() {
        let tree = Self.processes([300: (200, "/Users/maya/.local/bin/tincan"), 200: (1, Self.service)])
        let host = PermissionHost.detect(environment: [:], processes: tree) { _ in nil }
        #expect(host == PermissionHost(kind: .program, name: "example-service", path: Self.service, canAskForContacts: false))
    }

    @Test func anAppBeforeLaunchdStillWins() throws {
        let agent = try Self.bundle("Example Agent", identifier: "com.example.agent", contactsReason: nil)
        defer { try? FileManager.default.removeItem(atPath: (agent as NSString).deletingLastPathComponent) }
        // An app's executable between tincan and the program launchd started is the host.
        let underService = Self.processes([
            300: (250, "/Users/maya/.local/bin/tincan"), 250: (200, "/opt/homebrew/bin/node"),
            200: (150, agent + "/Contents/MacOS/Example Agent"), 150: (1, Self.service),
        ])
        let host = PermissionHost.detect(environment: [:], processes: underService) { _ in Self.serviceInfo }
        #expect(host.kind == .app)
        #expect(host.name == "Example Agent")
        #expect(host.path == agent)
        // So is an app launchd started itself, such as a terminal.
        let terminal = Self.processes([300: (250, "/Users/maya/.local/bin/tincan"), 250: (200, "/bin/zsh"), 200: (1, agent + "/Contents/MacOS/Example Agent")])
        #expect(PermissionHost.detect(environment: [:], processes: terminal) { _ in nil }.path == agent)
        // tincan inside an app, run from a shell, is run by the app above it, not that app.
        let bundled = Self.processes([
            300: (250, "/Applications/Example.app/Contents/MacOS/tincan"), 250: (200, "/bin/zsh"), 200: (1, agent + "/Contents/MacOS/Example Agent"),
        ])
        #expect(PermissionHost.detect(environment: [:], processes: bundled) { _ in nil }.path == agent)
    }

    @Test func tincanStartedByLaunchdIsItsOwnHost() {
        let tree = Self.processes([300: (1, "/Users/maya/.local/bin/tincan")])
        let host = PermissionHost.detect(environment: [:], processes: tree) { _ in Self.tincanInfo }
        #expect(host.kind == .program)
        #expect(host.name == "tincan")
        #expect(host.bundleID == PermissionHost.tincanBundleID)
        #expect(host.path == "/Users/maya/.local/bin/tincan")
        #expect(host.canAskForContacts == true)
        #expect(host.isTincan)
        #expect(
            host.grantStep(.fullDiskAccess)
                == "Turn on tincan in System Settings → Privacy & Security → Full Disk Access (click + and add /Users/maya/.local/bin/tincan if it isn't listed), and it applies from tincan's next run."
        )
    }

    @Test func terminalsAndSSHWinOverAProcessLaunchdAdopted() {
        // A tmux server leaves the shell that started it, so launchd becomes its parent, but
        // macOS still asks about the terminal, which `__CFBundleIdentifier` names.
        let tmux = Self.processes([300: (250, "/Users/maya/.local/bin/tincan"), 250: (200, "/bin/zsh"), 200: (1, "/opt/homebrew/bin/tmux")])
        let terminal = PermissionHost.detect(environment: ["__CFBundleIdentifier": "com.apple.Terminal"], processes: tmux) { _ in nil }
        #expect(terminal.kind == .app)
        #expect(terminal.bundleID == "com.apple.Terminal")
        // SSH logins run under sshd, which launchd starts for each connection.
        let ssh = Self.processes([300: (250, "/Users/maya/.local/bin/tincan"), 250: (200, "/bin/zsh"), 200: (1, "/usr/sbin/sshd")])
        #expect(PermissionHost.detect(environment: ["SSH_CONNECTION": "192.0.2.1 50000 192.0.2.2 22"], processes: ssh) { _ in nil } == .ssh)
    }

    @Test func processesThatCantBeReadLeaveTheHostUnknown() {
        let unreadable = PermissionHost.ProcessTree(current: 300, executable: { _ in nil }, parent: { _ in nil })
        #expect(PermissionHost.detect(environment: [:], processes: unreadable) { _ in nil } == .unknown)
        // A program launchd started whose executable can't be read names nothing.
        let nameless = PermissionHost.ProcessTree(
            current: 300, executable: { $0 == 300 ? "/Users/maya/.local/bin/tincan" : nil }, parent: { $0 == 300 ? 200 : 1 })
        #expect(PermissionHost.detect(environment: [:], processes: nameless) { _ in nil } == .unknown)
    }

    @Test func aProgramInsideAnAppReadsOnlyItsOwnInfoPlist() throws {
        // The app around it says why it uses Contacts; the program, a script, says nothing.
        let app = try Self.bundle("Example", identifier: "com.example.app", contactsReason: "Example shows who wrote to you.")
        defer { try? FileManager.default.removeItem(atPath: (app as NSString).deletingLastPathComponent) }
        let helpers = (app as NSString).appendingPathComponent("Contents/Helpers")
        try FileManager.default.createDirectory(atPath: helpers, withIntermediateDirectories: true)
        let executable = (helpers as NSString).appendingPathComponent("example-service")
        try "#!/bin/sh\nexit 0\n".write(toFile: executable, atomically: true, encoding: .utf8)
        #expect(PermissionHost.embeddedInfo(forExecutable: executable) == nil)
        let host = PermissionHost.program(at: executable)
        #expect(host == PermissionHost(kind: .program, name: "example-service", path: executable, canAskForContacts: false))
    }

    @Test func sentencesNameAProgram() {
        let host = PermissionHost(kind: .program, name: "Example Service", bundleID: "com.example.service", path: Self.service, canAskForContacts: true)
        #expect(host.subject == "Example Service")
        #expect(host.entry == "Example Service")
        #expect(host.titleSuffix == " for Example Service")
        #expect(
            host.grantStep(.fullDiskAccess)
                == "Turn on Example Service in System Settings → Privacy & Security → Full Disk Access (click + and add \(Self.service) if it isn't listed), then restart Example Service."
        )
        #expect(
            host.grantStep(.accessibility)
                == "Turn on Example Service in System Settings → Privacy & Security → Accessibility (click + and add \(Self.service) if it isn't listed).")
        #expect(host.grantStep(.contacts) == "Turn on Example Service in System Settings → Privacy & Security → Contacts.")
        #expect(PermissionHost(kind: .program, name: nil).sentenceSubject == "The program that runs tincan")
    }

    /// An app bundle with only an Info.plist, in its own temporary folder.
    static func bundle(_ name: String, identifier: String, contactsReason: String?, bundleName: String? = nil) throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tincan-host-\(UUID().uuidString)", isDirectory: true)
        let contents = folder.appendingPathComponent("\(name).app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        var info: [String: Any] = [
            "CFBundleIdentifier": identifier, "CFBundleName": bundleName ?? name, "CFBundlePackageType": "APPL", "CFBundleExecutable": name,
        ]
        if let contactsReason { info["NSContactsUsageDescription"] = contactsReason }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return folder.appendingPathComponent("\(name).app").path
    }
}
