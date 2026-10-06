import Foundation
import Testing
import TincanKit

@testable import TincanCLI

/// macOS gives tincan the permissions of the app that runs it, so doctor and every
/// permission error name that app. These tests pass invented hosts, so they don't depend
/// on which app runs them.
@Suite("Doctor names the app that holds permissions")
struct DoctorHostTests {
    static let terminal = PermissionHost(
        kind: .app, name: "Terminal", bundleID: "com.apple.Terminal", path: "/System/Applications/Utilities/Terminal.app", canAskForContacts: true)
    static let editor = PermissionHost(
        kind: .app, name: "Example Editor", bundleID: "com.example.editor", path: "/Applications/Example Editor.app", canAskForContacts: true)
    /// An assistant's app that doesn't say why it would use Contacts, installed outside
    /// the Applications folders.
    static let agent = PermissionHost(
        kind: .app, name: "agent", bundleID: "com.example.agent", path: NSHomeDirectory() + "/Library/Application Support/Example/agent.app",
        canAskForContacts: false)

    @Test func theFirstCheckNamesTheHost() {
        let terminal = Doctor.hostCheck(Self.terminal)
        #expect(terminal.id == "host")
        #expect(terminal.status == "ok")
        #expect(terminal.title == "Permissions come from Terminal")
        #expect(terminal.detail?.contains("the checks below are Terminal's") == true)
        #expect(terminal.detail?.contains("/System/") == false, "an app in an Applications folder needs no directions")
        // An app elsewhere comes with where to find it.
        #expect(Doctor.hostCheck(Self.agent).detail?.hasSuffix("agent is at ~/Library/Application Support/Example/agent.app.") == true)
        // So does one whose file has another name than the app gives itself.
        let renamed = PermissionHost(kind: .app, name: "Code", path: "/Applications/Example Code Editor.app")
        #expect(Doctor.hostCheck(renamed).detail?.hasSuffix("Code is at /Applications/Example Code Editor.app.") == true)
        let ssh = Doctor.hostCheck(.ssh)
        #expect(ssh.title == "Permissions come from SSH")
        #expect(ssh.detail?.contains("sshd-keygen-wrapper") == true)
        let unknown = Doctor.hostCheck(.unknown)
        #expect(unknown.status == "warn")
        #expect(unknown.fix?.contains("terminal, editor or assistant app") == true)
    }

    /// An assistant's background service that launchd starts from inside its app.
    static let service = PermissionHost(
        kind: .program, name: "Example Service", bundleID: "com.example.service",
        path: NSHomeDirectory() + "/Applications/Example.app/Contents/Helpers/example-service", canAskForContacts: true)
    /// tincan run directly by a launchd job.
    static let tincan = PermissionHost(
        kind: .program, name: "tincan", bundleID: PermissionHost.tincanBundleID, path: NSHomeDirectory() + "/.local/bin/tincan", canAskForContacts: true)

    @Test func aProgramLaunchdStartedHoldsThePermissions() {
        let service = Doctor.hostCheck(Self.service)
        #expect(service.status == "ok")
        #expect(service.title == "Permissions come from Example Service")
        #expect(
            service.detail
                == "macOS gives tincan the permissions of Example Service, the program launchd started to run it, so the checks below are Example Service's. Example Service is the program at ~/Applications/Example.app/Contents/Helpers/example-service, not the app around it."
        )
        let own = Doctor.hostCheck(Self.tincan)
        #expect(own.title == "Permissions come from tincan")
        #expect(
            own.detail
                == "A launchd job runs tincan directly, so macOS gives tincan its own permissions, and the checks below are tincan's. tincan is at ~/.local/bin/tincan."
        )
        let access = Doctor.fullDiskAccessCheck(.denied, detail: nil, host: Self.service, interactive: false)
        #expect(access.title == "Full Disk Access for Example Service")
        #expect(access.fix?.contains("click + and add ~/Applications/Example.app/Contents/Helpers/example-service if it isn't listed") == true)
        #expect(access.fix?.hasSuffix("then restart Example Service.") == true)
        #expect(Doctor.restart(Self.service) == "restart Example Service")
        #expect(Doctor.restart(Self.terminal) == "quit and reopen Terminal")
    }

    /// Reads the Info.plist the linker put into the tincan binary, as it would for any
    /// program launchd starts.
    @Test func aProgramIsNamedByTheInfoPlistLinkedIntoIt() {
        let host = PermissionHost.program(at: CLI.binary.path)
        #expect(host.kind == .program)
        #expect(host.name == "tincan")
        #expect(host.bundleID == PermissionHost.tincanBundleID)
        #expect(host.path == CLI.binary.path)
        #expect(host.canAskForContacts == true)
        #expect(host.isTincan)
    }

    @Test func theHostIsReportedAsAProgram() throws {
        let data = try Output.encoder.encode(Doctor.Host(Self.service))
        #expect(
            String(decoding: data, as: UTF8.self)
                == #"{"bundle_id":"com.example.service","kind":"program","name":"Example Service","path":"\#(NSHomeDirectory())/Applications/Example.app/Contents/Helpers/example-service"}"#
        )
        #expect(PermissionHost.Kind.allCases.map(\.rawValue) == ["app", "program", "ssh", "unknown"])
    }

    @Test func fullDiskAccessGoesToTheHostAndNeedsARestart() {
        let missing = Doctor.fullDiskAccessCheck(.denied, detail: nil, host: Self.terminal, interactive: false)
        #expect(missing.status == "fail")
        #expect(missing.title == "Full Disk Access for Terminal")
        #expect(
            missing.fix
                == "Turn on Terminal in System Settings → Privacy & Security → Full Disk Access (click + to add it if it isn't listed), then quit and reopen Terminal."
        )
        // In a terminal, --fix grants the same app, so it is offered.
        #expect(
            Doctor.fullDiskAccessCheck(.denied, detail: nil, host: Self.terminal, interactive: true).fix?.hasSuffix("`tincan doctor --fix` walks through it.")
                == true)
        let ok = Doctor.fullDiskAccessCheck(.granted, detail: nil, host: Self.editor, interactive: false)
        #expect(ok.status == "ok")
        #expect(ok.title == "Full Disk Access for Example Editor")
        let ssh = Doctor.fullDiskAccessCheck(.denied, detail: nil, host: .ssh, interactive: false)
        #expect(ssh.title == "Full Disk Access for SSH sessions")
        #expect(ssh.fix?.contains("General → Sharing, click ⓘ next to Remote Login and turn on Allow full disk access for remote users") == true)
        let unknown = Doctor.fullDiskAccessCheck(.denied, detail: nil, host: .unknown, interactive: false)
        #expect(unknown.title == "Full Disk Access")
        #expect(unknown.fix?.hasPrefix("Turn on the app that runs tincan (your terminal, editor or assistant app)") == true)
    }

    @Test func contactsSaysWhoCanAsk() throws {
        let terminal = try #require(Doctor.contactsCheck(.notDetermined, detail: nil, host: Self.terminal, interactive: true))
        #expect(terminal.title == "Contacts for Terminal")
        #expect(terminal.fix == "Run `tincan doctor --fix` and allow access when macOS asks.")
        // Without a terminal, an assistant asks the person first; macOS then asks on screen.
        let editor = try #require(Doctor.contactsCheck(.notDetermined, detail: nil, host: Self.editor, interactive: false))
        #expect(
            editor.fix
                == "Ask the person whether Example Editor may use Contacts. If they agree, run `tincan doctor --request contacts`: macOS asks on this Mac's screen, and the person answers there."
        )
        let agent = try #require(Doctor.contactsCheck(.notDetermined, detail: nil, host: Self.agent, interactive: false))
        #expect(agent.fix?.hasPrefix("agent doesn't say why it would use Contacts, so macOS may refuse it without asking.") == true)
        let denied = try #require(Doctor.contactsCheck(.denied, detail: nil, host: Self.terminal, interactive: false))
        #expect(denied.fix == "Turn on Terminal in System Settings → Privacy & Security → Contacts.")
        #expect(
            Doctor.contactsCheck(.denied, detail: nil, host: Self.agent, interactive: false)?.fix?.contains("If agent isn't listed, it can't ask for Contacts")
                == true)
        #expect(Doctor.contactsCheck(.notDetermined, detail: nil, host: .ssh, interactive: true)?.fix?.contains("can't ask an SSH session") == true)
        #expect(Doctor.contactsCheck(.unknown, detail: nil, host: Self.terminal, interactive: false) == nil)
    }

    @Test func sendingAndTypingNameTheHost() {
        let denied = Doctor.automationCheck(.denied, host: Self.editor, interactive: false)
        #expect(denied.status == "fail")
        #expect(denied.detail == "Example Editor isn't allowed to control Messages.")
        #expect(denied.fix == "Turn on Messages under Example Editor in System Settings → Privacy & Security → Automation.")
        #expect(Doctor.automationCheck(.granted, host: Self.terminal, interactive: false).detail == "Terminal may control Messages, so tincan can send.")
        #expect(
            Doctor.automationCheck(.notDetermined, host: .unknown, interactive: false).detail
                == "macOS asks whether the app that runs tincan may control Messages the first time tincan sends.")
        #expect(Doctor.automationCheck(nil, host: Self.terminal, interactive: true).status == "skip")
        let typing = Doctor.accessibilityCheck(.denied, host: Self.terminal, interactive: false)
        #expect(typing.status == "warn")
        #expect(typing.detail == "Without Accessibility for Terminal, sends are paced but no typing bubble appears.")
        #expect(typing.fix == "Optional: turn on Terminal in System Settings → Privacy & Security → Accessibility (click + to add it if it isn't listed).")
        #expect(Doctor.accessibilityCheck(.granted, host: .unknown, interactive: false).detail?.hasPrefix("The app that runs tincan has Accessibility") == true)
    }

    @Test func permissionErrorsNameTheHost() {
        let access = TincanError.fullDiskAccess("your messages", host: Self.terminal)
        #expect(access.code == "full_disk_access_required")
        #expect(access.exit == .permission)
        #expect(access.message == "tincan can't read your messages: Terminal doesn't have Full Disk Access.")
        #expect(access.hint.hasPrefix("Turn on Terminal in System Settings → Privacy & Security → Full Disk Access"))
        #expect(
            TincanError.fullDiskAccess("your call history", host: .unknown).message
                == "tincan can't read your call history: the app that runs tincan doesn't have Full Disk Access.")
        let contacts = TincanError.contactsAccess(.notDetermined, host: Self.editor)
        #expect(contacts.message == "Example Editor hasn't been allowed to read Contacts yet.")
        #expect(TincanError.contactsAccess(.notDetermined, host: .unknown).message == "The app that runs tincan hasn't been allowed to read Contacts yet.")
        let denied = TincanError.contactsAccess(.denied, host: Self.terminal)
        #expect(denied.message == "Contacts access is denied for Terminal.")
        #expect(denied.hint == "Turn on Terminal in System Settings → Privacy & Security → Contacts.")
    }

    /// An installed tincan has no resource bundle beside it, so the phone number metadata
    /// must be linked into the binary.
    @Test func theBinaryCarriesThePhoneNumberMetadata() throws {
        let binary = try Data(contentsOf: CLI.binary)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Support/PhoneNumberMetadata.json")
        let metadata = try Data(contentsOf: source.standardizedFileURL)
        #expect(binary.range(of: metadata.prefix(4096)) != nil)
    }

    /// tincan runs with the permissions of the app that starts it and never uses macOS's
    /// private interface for holding its own.
    @Test func theBinaryNeverDisclaimsResponsibility() throws {
        let binary = try Data(contentsOf: CLI.binary)
        #expect(binary.range(of: Data("responsibility_spawnattrs_setdisclaim".utf8)) == nil)
    }
}
