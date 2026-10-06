import Foundation

public enum TincanVersion {
    /// The version from the Info.plist embedded in the tincan binary.
    public static var current: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0-dev"
    }
}
