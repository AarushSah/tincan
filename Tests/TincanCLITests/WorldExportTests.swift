import Foundation
import Testing

/// `TINCAN_EXPORT_WORLD=<dir> swift test --filter WorldExport` copies the fixture world to
/// `<dir>` with an `env.sh` to source, for trying the CLI by hand on invented data.
@Suite("Fixture world")
struct WorldExportTests {
    @Test func exportsTheWorldWhenAsked() throws {
        let world = try World()
        #expect(FileManager.default.fileExists(atPath: world.data.messages))
        guard let target = ProcessInfo.processInfo.environment["TINCAN_EXPORT_WORLD"], !target.isEmpty else { return }
        let directory = URL(fileURLWithPath: target, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var lines: [String] = []
        for (variable, source) in world.environment {
            let destination = directory.appendingPathComponent((source as NSString).lastPathComponent)
            try FileManager.default.copyItem(atPath: source, toPath: destination.path)
            lines.append("export \(variable)='\(destination.path)'")
        }
        try FileManager.default.copyItem(
            at: world.data.directory.appendingPathComponent("IMG_0042.jpeg"), to: directory.appendingPathComponent("IMG_0042.jpeg"))
        try (lines.sorted().joined(separator: "\n") + "\n").write(to: directory.appendingPathComponent("env.sh"), atomically: true, encoding: .utf8)
    }
}
