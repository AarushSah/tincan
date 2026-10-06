import Testing

@testable import TincanKit

@Test func versionIsNotEmpty() {
    #expect(!TincanVersion.current.isEmpty)
}
