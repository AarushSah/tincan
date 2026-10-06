import AppKit
import ApplicationServices
import Foundation

/// The macOS privacy permissions tincan uses, checked without prompting unless asked. They
/// belong to the app that runs tincan; see `PermissionHost`.
public enum Permissions {
    public enum State: String, Sendable, Codable {
        case granted
        case denied
        /// macOS has not asked yet; the next use will prompt.
        case notDetermined = "not_determined"
        /// Could not be determined right now (for example, Messages is not running).
        case unknown
    }

    public static let messagesBundleID = "com.apple.MobileSMS"

    /// Full Disk Access, tested by reading the protected files themselves.
    public static func fullDiskAccess() -> State {
        do {
            try SQLiteDatabase.checkReadable(MessagesDatabase.defaultPath)
            return .granted
        } catch SQLiteError.accessDenied {
            return .denied
        } catch {
            // Missing Messages database: fall back to another protected location.
            let probe = NSString(string: "~/Library/Safari").expandingTildeInPath
            return (try? FileManager.default.contentsOfDirectory(atPath: probe)) == nil ? .denied : .granted
        }
    }

    public static func contacts(_ provider: ContactsProvider) -> State {
        switch provider.authorization {
        case .authorized, .limited: return .granted
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        }
    }

    /// Apple Events to Messages, needed to send. Pass `prompt` to show the system dialog.
    public static func automation(prompt: Bool = false) -> State {
        if NSRunningApplication.runningApplications(withBundleIdentifier: messagesBundleID).isEmpty {
            if !prompt { return .unknown }
            launchMessagesInBackground()
        }
        var target = AEAddressDesc()
        let created = messagesBundleID.withCString { pointer in
            AECreateDesc(typeApplicationBundleID, pointer, strlen(pointer), &target)
        }
        guard created == noErr else { return .unknown }
        defer { AEDisposeDesc(&target) }
        let status = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, prompt)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return .unknown
        }
    }

    /// Accessibility, needed only to show the typing indicator. `prompt` shows the dialog.
    public static func accessibility(prompt: Bool = false) -> State {
        // The value of `kAXTrustedCheckOptionPrompt`, which Swift 6 can't read safely: the
        // header declares it as a mutable global.
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options) ? .granted : .denied
    }

    public static func launchMessagesInBackground() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: messagesBundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        let semaphore = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 10)
        Thread.sleep(forTimeInterval: 1)
    }

    /// Opens the System Settings list for a permission.
    public static func openSettings(for permission: Permission) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(permission.settingsAnchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Shows a file in Finder, so it can be dragged into a permission list.
    public static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    public static var executablePath: String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        guard let resolved = realpath(buffer, nil) else { return String(nulTerminated: buffer) }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Whether the screen is locked. Messages can't be typed into then.
    public static var isScreenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? ((session["CGSSessionScreenIsLocked"] as? Int) == 1)
    }

    /// Seconds since the last keyboard or mouse input on this Mac.
    public static func idleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}
