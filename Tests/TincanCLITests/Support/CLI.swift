import Foundation
import Testing

/// What one run of the `tincan` binary printed and how it exited.
struct CLIResult {
    let status: Int32
    let stdout: String
    let stderr: String

    /// Standard output parsed as one JSON document.
    var json: [String: Any] {
        get throws {
            guard let object = try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any] else {
                throw FixtureError(description: "stdout is not a JSON object: \(stdout)")
            }
            return object
        }
    }

    /// Standard output as JSON Lines, for `watch --json`.
    var jsonLines: [[String: Any]] {
        get throws {
            try stdout.split(separator: "\n").map { line in
                guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                    throw FixtureError(description: "not a JSON object: \(line)")
                }
                return object
            }
        }
    }

    var dataObject: [String: Any] { get throws { try (json["data"] as? [String: Any]) ?? [:] } }
    var dataArray: [[String: Any]] { get throws { try (json["data"] as? [[String: Any]]) ?? [] } }
    var error: [String: Any]? { get throws { try json["error"] as? [String: Any] } }
    var errorCode: String? { get throws { try error?["code"] as? String } }
    var warningCodes: [String] { get throws { try ((json["warnings"] as? [[String: Any]]) ?? []).compactMap { $0["code"] as? String } } }
    var next: [String: Any]? { get throws { try json["next"] as? [String: Any] } }
}

/// Runs the built `tincan` binary. Every run inherits nothing from the test's environment
/// except what's needed to start a process and has no terminal on stdin. Tests point it at
/// fixtures, so they never touch this Mac's own data.
enum CLI {
    static let binary: URL = {
        if let path = ProcessInfo.processInfo.environment["TINCAN_TEST_BINARY"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            let candidate = bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("tincan")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return package.appendingPathComponent(".build/debug/tincan")
    }()

    static func run(_ arguments: [String], environment: [String: String], stdin: String? = nil, timeout: TimeInterval = 30) throws -> CLIResult {
        let process = try start(arguments, environment: environment, stdin: stdin)
        let deadline = Date().addingTimeInterval(timeout)
        while process.process.isRunning {
            if Date() > deadline {
                process.process.terminate()
                throw FixtureError(description: "tincan \(arguments.joined(separator: " ")) did not finish in \(Int(timeout))s")
            }
            usleep(5_000)
        }
        return process.result()
    }

    /// A running tincan, for streaming commands such as `watch`.
    final class Running {
        let process: Process
        let stdout: URL
        let stderr: URL

        init(process: Process, stdout: URL, stderr: URL) {
            self.process = process
            self.stdout = stdout
            self.stderr = stderr
        }

        /// Stops the process (if it is still running) and collects what it printed.
        func stop() -> CLIResult {
            if process.isRunning {
                process.interrupt()
                let deadline = Date().addingTimeInterval(5)
                while process.isRunning, Date() < deadline { usleep(5_000) }
                if process.isRunning { process.terminate() }
            }
            process.waitUntilExit()
            return result()
        }

        /// What the process has printed so far.
        var output: String { (try? String(contentsOf: stdout, encoding: .utf8)) ?? "" }

        func result() -> CLIResult {
            process.waitUntilExit()
            return CLIResult(
                status: process.terminationStatus,
                stdout: (try? String(contentsOf: stdout, encoding: .utf8)) ?? "",
                stderr: (try? String(contentsOf: stderr, encoding: .utf8)) ?? ""
            )
        }
    }

    static func start(_ arguments: [String], environment: [String: String], stdin: String? = nil) throws -> Running {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw FixtureError(description: "No tincan binary at \(binary.path). Run `swift build` first.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tincan-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stdout = directory.appendingPathComponent("stdout")
        let stderr = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdout.path, contents: nil)
        FileManager.default.createFile(atPath: stderr.path, contents: nil)

        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.environment = baseEnvironment.merging(environment) { $1 }
        process.standardOutput = try FileHandle(forWritingTo: stdout)
        process.standardError = try FileHandle(forWritingTo: stderr)
        if let stdin {
            let input = directory.appendingPathComponent("stdin")
            try stdin.write(to: input, atomically: true, encoding: .utf8)
            process.standardInput = try FileHandle(forReadingFrom: input)
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        try process.run()
        return Running(process: process, stdout: stdout, stderr: stderr)
    }

    /// Only what a process needs to start, so tests never touch this Mac's own data.
    static var baseEnvironment: [String: String] {
        var base = [
            "PATH": "/usr/bin:/bin",
            "TMPDIR": NSTemporaryDirectory(),
            "LANG": "en_US.UTF-8",
        ]
        if let home = ProcessInfo.processInfo.environment["HOME"] { base["HOME"] = home }
        return base
    }

    /// Runs tincan in a pseudo-terminal, the way a person at a terminal would, and types
    /// `answer` once it asks a yes/no question. Everything it printed, to either stream, is
    /// in `stdout`.
    static func runInTerminal(_ arguments: [String], environment: [String: String], answer: String, timeout: TimeInterval = 30) throws -> CLIResult {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw FixtureError(description: "No tincan binary at \(binary.path). Run `swift build` first.")
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("tincan-tty-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let input = Pipe()
        let process = Process()
        // script(1) gives tincan a terminal on stdin and stdout.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", binary.path] + arguments
        process.environment = baseEnvironment.merging(environment) { $1 }
        process.standardInput = input
        process.standardOutput = try FileHandle(forWritingTo: output)
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { try? input.fileHandleForWriting.close() }
        func printed() -> String { (try? String(contentsOf: output, encoding: .utf8)) ?? "" }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, !printed().contains("[y/N]") {
            if Date() > deadline {
                process.terminate()
                throw FixtureError(description: "tincan \(arguments.joined(separator: " ")) never asked: \(printed())")
            }
            usleep(20_000)
        }
        if process.isRunning { input.fileHandleForWriting.write(Data((answer + "\n").utf8)) }
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                throw FixtureError(description: "tincan \(arguments.joined(separator: " ")) did not finish in \(Int(timeout))s")
            }
            usleep(20_000)
        }
        return CLIResult(status: process.terminationStatus, stdout: printed(), stderr: "")
    }
}
