// Copied from Tests/TincanKitTests/MessageBodyTests.swift; see FixtureDatabase.swift.

import Foundation

/// `attributedBody` blobs in the `NSArchiver` typedstream format Messages writes.
enum AttributedBodyFixture {
    /// `NSArchiver` is deprecated, but it is the only writer of the format Messages stores.
    /// Calling it through the Objective-C runtime keeps its deprecation out of every build.
    static func archive(_ attributed: NSAttributedString) -> Data {
        let archiver: AnyObject = NSClassFromString("NSArchiver")!
        let archived = archiver.perform(NSSelectorFromString("archivedDataWithRootObject:"), with: attributed)
        return archived!.takeUnretainedValue() as! Data
    }

    static func plain(_ text: String, part: Int = 0) -> Data {
        archive(
            NSAttributedString(
                string: text,
                attributes: [
                    NSAttributedString.Key("__kIMMessagePartAttributeName"): NSNumber(value: part)
                ]))
    }
}
