import Foundation
import Testing

/// The shape of a JSON document: every key path with the types found there, one per line.
///
///     data.messages[].edited?: bool
///     data.messages[].id: number
///
/// `[]` stands for array elements and `?` marks a key that only some elements have. Shapes
/// are compared with snapshots in Tests/TincanCLITests/Snapshots, so the agent contract
/// can't drift silently. Set TINCAN_RECORD_SNAPSHOTS=1 to rewrite them after an intended
/// change, and review the diff.
enum JSONShape {
    static func describe(_ value: Any) -> String {
        var types: [String: Set<String>] = [:]
        var objects: [String: Int] = [:]
        var keys: [String: Int] = [:]
        visit(value, path: "", types: &types, objects: &objects, keys: &keys)
        return types.keys.sorted().map { path -> String in
            let parent = path.range(of: ".", options: .backwards).map { String(path[..<$0.lowerBound]) } ?? ""
            let optional = path.isEmpty || path.hasSuffix("[]") ? false : (keys[path] ?? 0) < (objects[parent] ?? 0)
            let name = path.isEmpty ? "(root)" : path
            return "\(name)\(optional ? "?" : ""): \(types[path]!.sorted().joined(separator: " | "))"
        }.joined(separator: "\n") + "\n"
    }

    private static func visit(_ value: Any, path: String, types: inout [String: Set<String>], objects: inout [String: Int], keys: inout [String: Int]) {
        switch value {
        case let object as [String: Any]:
            types[path, default: []].insert("object")
            objects[path, default: 0] += 1
            for (key, child) in object {
                let childPath = path.isEmpty ? key : "\(path).\(key)"
                keys[childPath, default: 0] += 1
                visit(child, path: childPath, types: &types, objects: &objects, keys: &keys)
            }
        case let array as [Any]:
            types[path, default: []].insert(array.isEmpty ? "array (empty)" : "array")
            for element in array { visit(element, path: path + "[]", types: &types, objects: &objects, keys: &keys) }
        case let number as NSNumber:
            types[path, default: []].insert(CFGetTypeID(number) == CFBooleanGetTypeID() ? "bool" : "number")
        case is String:
            types[path, default: []].insert("string")
        case is NSNull:
            types[path, default: []].insert("null")
        default:
            types[path, default: []].insert("unknown")
        }
    }

    /// Compares `value`'s shape with the snapshot `name`, recording a test issue on change.
    static func expect(_ value: Any, matches name: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let actual = describe(value)
        let file = directory.appendingPathComponent(name + ".shape")
        let record = ProcessInfo.processInfo.environment["TINCAN_RECORD_SNAPSHOTS"] == "1"
        guard !record, let expected = try? String(contentsOf: file, encoding: .utf8) else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try actual.write(to: file, atomically: true, encoding: .utf8)
            if !record { Issue.record("Recorded a new snapshot \(name).shape; review it and run again.", sourceLocation: sourceLocation) }
            return
        }
        guard actual != expected else { return }
        let old = Set(expected.split(separator: "\n"))
        let new = Set(actual.split(separator: "\n"))
        let removed = old.subtracting(new).sorted().map { "- \($0)" }
        let added = new.subtracting(old).sorted().map { "+ \($0)" }
        Issue.record(
            """
            The JSON shape of \(name) changed. If that is intended, update the docs and rerun with \
            TINCAN_RECORD_SNAPSHOTS=1.
            \((removed + added).joined(separator: "\n"))
            """, sourceLocation: sourceLocation)
    }

    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Snapshots", isDirectory: true)
}
