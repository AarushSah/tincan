import Foundation

/// Settings from `~/.config/tincan/config.toml`.
public struct Config: Sendable, Equatable {
    /// How a send makes the other person see typing.
    public enum TypingMode: String, Sendable, CaseIterable, Codable {
        /// Type into Messages when Accessibility allows and nobody is using the Mac; otherwise pace.
        case auto
        /// Always type into Messages so the typing indicator shows. Needs Accessibility.
        case keyboard
        /// Wait as long as typing would take, then send each bubble. No typing indicator.
        case paced
        /// Send immediately, one bubble after another.
        case off
    }

    /// Default country for numbers written without a country code, such as `US`.
    public var region: String?
    /// Typing speed used to pace sends, in words per minute.
    public var wordsPerMinute: Double = 80
    public var typing: TypingMode = .auto
    /// Conversations tincan never reads or sends to, by chat GUID. GUIDs survive database
    /// rebuilds and new Macs; `chat:<id>` references from older configs are still honored.
    public var excludedChats: [String] = []

    public init() {}

    /// Where the settings file is, and what put it there.
    public struct Location: Sendable, Equatable {
        /// The file tincan reads and saves.
        public let path: String
        /// `~/.config/tincan/config.toml`, the file used when nothing overrides it.
        public let standardPath: String
        /// `TINCAN_CONFIG` or `XDG_CONFIG_HOME` when one of them chose `path`.
        public let variable: String?
    }

    /// The settings file for `environment`. `TINCAN_CONFIG` names a file, and
    /// `XDG_CONFIG_HOME` moves the directory; `home` is only a parameter for tests.
    public static func location(environment: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory()) -> Location {
        let standard = home + "/.config/tincan/config.toml"
        if let custom = environment["TINCAN_CONFIG"], !custom.isEmpty {
            return Location(path: custom, standardPath: standard, variable: "TINCAN_CONFIG")
        }
        if let base = environment["XDG_CONFIG_HOME"], !base.isEmpty {
            return Location(path: base + "/tincan/config.toml", standardPath: standard, variable: "XDG_CONFIG_HOME")
        }
        return Location(path: standard, standardPath: standard, variable: nil)
    }

    public static var defaultPath: String { location().path }

    /// The region used for numbers without a country code.
    public var effectiveRegion: String? {
        region?.uppercased() ?? PhoneRegions.systemRegion
    }

    // MARK: Loading and saving

    /// Settings as tincan reads them for `environment`. With no settings file anywhere, as
    /// on a fresh install, they are the defaults. An override that leads to no file is an
    /// error instead, because defaults there would silently drop the person's exclusions:
    /// `TINCAN_CONFIG` naming a missing file, or `XDG_CONFIG_HOME` leading to none while
    /// `~/.config/tincan/config.toml` exists.
    ///
    /// With `keepingStandardExclusions`, for reading this Mac's own Messages, an override
    /// must also keep every exclusion in `~/.config/tincan/config.toml`, so pointing tincan
    /// at another file can't let an excluded conversation back in.
    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory(),
        keepingStandardExclusions: Bool = false
    ) throws -> Config {
        let location = location(environment: environment, home: home)
        let files = FileManager.default
        let standardExists = location.standardPath != location.path && files.fileExists(atPath: location.standardPath)
        if let variable = location.variable, !files.fileExists(atPath: location.path) {
            // TINCAN_CONFIG names one file on purpose. XDG_CONFIG_HOME is often set for other
            // tools, so without settings anywhere it is a fresh install.
            if variable == "TINCAN_CONFIG" || standardExists {
                throw ConfigError.missing(path: location.path, variable: variable, standardPath: standardExists ? location.standardPath : nil)
            }
        }
        let config = try load(path: location.path)
        if keepingStandardExclusions, let variable = location.variable, standardExists {
            let dropped = Set(try load(path: location.standardPath).excludedChats).subtracting(config.excludedChats)
            if !dropped.isEmpty {
                throw ConfigError.dropsExclusions(path: location.path, variable: variable, standardPath: location.standardPath, count: dropped.count)
            }
        }
        return config
    }

    /// Settings from the file at `path`, or the defaults when there is none.
    public static func load(path: String) throws -> Config {
        guard FileManager.default.fileExists(atPath: path) else { return Config() }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return try parse(text)
    }

    /// The settings the file can hold, as `table.key`.
    public static let keys = ["region", "send.wpm", "send.typing", "privacy.exclude"]

    /// Parses settings. A setting tincan doesn't know, or a known one with the wrong type or
    /// value, is an error rather than ignored, so a mistyped exclusion can never quietly stop
    /// excluding a conversation.
    public static func parse(_ text: String) throws -> Config {
        let document = try TOMLLite.document(text)
        let table = document.values
        var config = Config()
        for key in table.keys.sorted(by: { (document.lines[$0] ?? 0) < (document.lines[$1] ?? 0) }) where !keys.contains(key) {
            throw TOMLLite.Error.invalid(
                line: document.lines[key] ?? 0,
                message: "\(key) isn't a setting; the settings are \(keys.joined(separator: ", "))")
        }
        func invalid(_ message: String) -> TOMLLite.Error { .invalid(line: 0, message: message) }
        if let value = table["region"] {
            guard case .string(let region) = value, region.isEmpty || PhoneRegions.byRegion[region.uppercased()] != nil else {
                throw invalid("region must be an ISO country code such as \"US\"")
            }
            config.region = region.isEmpty ? nil : region.uppercased()
        }
        if let value = table["send.wpm"] {
            guard case .number(let wpm) = value else { throw invalid("send.wpm must be a number") }
            // The same range `tincan config set` and `send --wpm` accept.
            guard wpm >= 5, wpm <= 250 else { throw invalid("send.wpm must be from 5 to 250") }
            config.wordsPerMinute = wpm
        }
        if let value = table["send.typing"] {
            guard case .string(let mode) = value, let parsed = TypingMode(rawValue: mode) else {
                throw invalid("send.typing must be one of auto, keyboard, paced, off")
            }
            config.typing = parsed
        }
        if let value = table["privacy.exclude"] {
            guard case .array(let chats) = value else { throw invalid("privacy.exclude must be a list such as [\"chat:42\"]") }
            config.excludedChats = chats
        }
        return config
    }

    public func render() -> String {
        var lines = [
            "# tincan settings. Edit by hand or with `tincan config set <key> <value>`.",
            "",
            "# Country for phone numbers written without a country code (ISO code such as \"US\").",
        ]
        lines.append(region.map { "region = \(TOMLLite.quote($0))" } ?? "# region = \"US\"")
        lines += [
            "",
            "[send]",
            "# Typing speed used to pace each bubble, in words per minute.",
            "wpm = \(Self.formatNumber(wordsPerMinute))",
            "# auto: show the typing indicator when possible · keyboard: always · paced: wait, no indicator · off: no pacing",
            "typing = \"\(typing.rawValue)\"",
            "",
            "[privacy]",
            "# Conversations tincan never reads or sends to. Manage with `tincan exclude`.",
            "exclude = [\(excludedChats.map(TOMLLite.quote).joined(separator: ", "))]",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    /// Writes the settings, readable only by you: the file is 0600 and a folder it creates
    /// 0700, whatever the file's mode was before.
    public func save(path: String = defaultPath) throws {
        let files = FileManager.default
        let directory = (path as NSString).deletingLastPathComponent
        if !files.fileExists(atPath: directory) {
            try files.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
        }
        let temporary = path + ".tmp"
        try? files.removeItem(atPath: temporary)
        guard files.createFile(atPath: temporary, contents: Data(render().utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary])
        }
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary)
        // Replacing keeps the old file's attributes, including its mode, so set it again.
        _ = try files.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: temporary))
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    public static func formatNumber(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }
}

/// Settings tincan can't use as they are.
public enum ConfigError: Error, Equatable, CustomStringConvertible {
    /// `variable` points tincan at `path`, which doesn't exist. `standardPath` is the
    /// settings file it would otherwise read, when that one exists.
    case missing(path: String, variable: String, standardPath: String?)
    /// `variable` points tincan at `path`, which leaves out `count` exclusions that the
    /// settings file at `standardPath` has.
    case dropsExclusions(path: String, variable: String, standardPath: String, count: Int)

    public var description: String {
        switch self {
        case .missing(let path, let variable, _): return "\(variable) points at \(path), which doesn't exist"
        case .dropsExclusions(let path, let variable, let standardPath, let count):
            return "\(variable) points at \(path), which leaves out \(count) exclusions in \(standardPath)"
        }
    }
}

/// The subset of TOML that tincan's settings file uses, and nothing more:
///
/// - `#` comments, and blank lines.
/// - Table headers such as `[send]`, each once, named with bare keys.
/// - `key = value` lines, one per line, each key once. Keys are bare: letters, digits, `_`
///   and `-`, optionally dotted, as in `send.wpm = 42`.
/// - Values: a string in double quotes on one line, with TOML's escapes; a decimal number
///   such as `42`, `-1.5`, `1_000` or `5e2`; `true` or `false`; or an array of such strings,
///   which may span lines and end with a comma.
///
/// Valid TOML outside it fails with `Error.unsupported`, naming the construct, rather than
/// being misread. Keys come back flattened as `table.key`.
public enum TOMLLite {
    public enum Value: Equatable, Sendable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case array([String])
    }

    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        /// Not TOML, or a setting tincan can't use. `line` is 0 when no line is to blame.
        case invalid(line: Int, message: String)
        /// Valid TOML that tincan's settings file doesn't support, such as `inline tables`.
        case unsupported(line: Int, construct: String)

        public var description: String {
            switch self {
            case .invalid(let line, let message): return line > 0 ? "config line \(line): \(message)" : "config: \(message)"
            case .unsupported(let line, let construct): return "config line \(line): \(construct) aren't supported"
            }
        }
    }

    /// What the settings file supports, for people fixing it.
    public static let subset =
        "[tables], and key = value lines whose value is a string in double quotes, a decimal number, true, false, or a list of strings in double quotes"

    public static func parse(_ text: String) throws -> [String: Value] {
        try document(text).values
    }

    /// The values, and the line each key is on, for errors that name it.
    public static func document(_ text: String) throws -> (values: [String: Value], lines: [String: Int]) {
        var result: [String: Value] = [:]
        var keyLines: [String: Int] = [:]
        var tables: Set<String> = []
        var table = ""
        // An array whose closing bracket is on a later line.
        var open: (key: String, text: String, line: Int)?
        func store(_ key: String, _ text: String, line: Int) throws {
            guard result[key] == nil else { throw Error.invalid(line: line, message: "\(key) is set twice") }
            result[key] = try parseValue(text, line: line)
            keyLines[key] = line
        }
        let lines = text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }
        for (offset, rawLine) in lines.enumerated() {
            let number = offset + 1
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if var array = open {
                array.text += " " + line
                open = array
                if depth(array.text) <= 0 {
                    try store(array.key, array.text, line: array.line)
                    open = nil
                }
                continue
            }
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                if line.hasPrefix("[[") { throw Error.unsupported(line: number, construct: "arrays of tables") }
                guard line.hasSuffix("]") else { throw Error.invalid(line: number, message: "a table header ends with ], as in [send]") }
                table = try key(String(line.dropFirst().dropLast()), line: number)
                guard tables.insert(table).inserted else { throw Error.invalid(line: number, message: "the [\(table)] table appears twice") }
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { throw Error.invalid(line: number, message: "expected key = value") }
            let name = try key(String(line[..<equals]), line: number)
            let valueText = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !valueText.isEmpty else { throw Error.invalid(line: number, message: "\(name) has no value") }
            let fullKey = table.isEmpty ? name : "\(table).\(name)"
            if valueText.hasPrefix("["), depth(valueText) > 0 {
                open = (fullKey, valueText, number)
                continue
            }
            try store(fullKey, valueText, line: number)
        }
        if let open { throw Error.invalid(line: open.line, message: "the array starting here never ends with ]") }
        return (result, keyLines)
    }

    /// `text` as a string in double quotes that `parse` reads back as `text`.
    public static func quote(_ text: String) -> String {
        var quoted = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": quoted += "\\\""
            case "\\": quoted += "\\\\"
            case "\n": quoted += "\\n"
            case "\t": quoted += "\\t"
            case "\r": quoted += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    quoted += String(format: "\\u%04X", scalar.value)
                } else {
                    quoted.unicodeScalars.append(scalar)
                }
            }
        }
        return quoted + "\""
    }

    /// A bare key, dotted or not, without the spaces around its dots.
    static func key(_ text: String, line: Int) throws -> String {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.contains(where: { $0.hasPrefix("\"") || $0.hasPrefix("'") }) { throw Error.unsupported(line: line, construct: "quoted keys") }
        let bare = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        for part in parts where part.isEmpty || !part.unicodeScalars.allSatisfy(bare.contains) {
            throw Error.invalid(line: line, message: part.isEmpty ? "a key is missing" : "\(part) isn't a key: keys are letters, digits, - and _")
        }
        return parts.joined(separator: ".")
    }

    static func parseValue(_ text: String, line: Int) throws -> Value {
        var scanner = ValueScanner(text: text, line: line)
        let value = try scanner.value(inArray: false)
        scanner.skipSpaces()
        guard scanner.atEnd else { throw Error.invalid(line: line, message: "unexpected \(scanner.rest) after the value") }
        return value
    }

    /// How many brackets and braces `text` leaves open, outside strings.
    static func depth(_ text: String) -> Int {
        var depth = 0
        var quote: Unicode.Scalar?
        var escaped = false
        for scalar in text.unicodeScalars {
            if let open = quote {
                if escaped { escaped = false } else if scalar == "\\" && open == "\"" { escaped = true } else if scalar == open { quote = nil }
                continue
            }
            switch scalar {
            case "\"", "'": quote = scalar
            case "[", "{": depth += 1
            case "]", "}": depth -= 1
            default: break
            }
        }
        return depth
    }

    /// `line` without its `#` comment, keeping a `#` inside a string.
    static func stripComment(_ line: String) -> String {
        var quote: Unicode.Scalar?
        var escaped = false
        for index in line.unicodeScalars.indices {
            let scalar = line.unicodeScalars[index]
            if let open = quote {
                if escaped { escaped = false } else if scalar == "\\" && open == "\"" { escaped = true } else if scalar == open { quote = nil }
                continue
            }
            if scalar == "\"" || scalar == "'" { quote = scalar }
            if scalar == "#" { return String(line.unicodeScalars[..<index]) }
        }
        return line
    }

    /// Reads one value; an array that spans lines arrives joined into one.
    struct ValueScanner {
        let scalars: [Unicode.Scalar]
        let line: Int
        var index = 0

        init(text: String, line: Int) {
            scalars = Array(text.unicodeScalars)
            self.line = line
        }

        var atEnd: Bool { index >= scalars.count }
        var rest: String { String(String.UnicodeScalarView(scalars[index...])) }

        func peek(_ offset: Int = 0) -> Unicode.Scalar? {
            index + offset < scalars.count ? scalars[index + offset] : nil
        }

        func starts(with prefix: String) -> Bool {
            prefix.unicodeScalars.enumerated().allSatisfy { peek($0.offset) == $0.element }
        }

        mutating func skipSpaces() {
            while let scalar = peek(), scalar == " " || scalar == "\t" { index += 1 }
        }

        func unsupported(_ construct: String) -> Error { .unsupported(line: line, construct: construct) }
        func invalid(_ message: String) -> Error { .invalid(line: line, message: message) }

        mutating func value(inArray: Bool) throws -> Value {
            if starts(with: "\"\"\"") || starts(with: "'''") { throw unsupported("multi-line strings") }
            switch peek() {
            case "\"": return .string(try string())
            case "'": throw unsupported("literal strings in single quotes")
            case "{": throw unsupported("inline tables")
            case "[":
                if inArray { throw unsupported("arrays inside arrays") }
                return .array(try array())
            default:
                let value = try scalar()
                if inArray {
                    if case .bool = value { throw unsupported("true and false in arrays") }
                    throw unsupported("numbers in arrays")
                }
                return value
            }
        }

        /// A list of strings: values between brackets, separated by commas, with an
        /// optional comma after the last.
        mutating func array() throws -> [String] {
            index += 1
            var items: [String] = []
            while true {
                skipSpaces()
                if peek() == "]" {
                    index += 1
                    return items
                }
                guard !atEnd else { throw invalid("arrays must end with ]") }
                guard case .string(let item) = try value(inArray: true) else { throw unsupported("numbers in arrays") }
                items.append(item)
                skipSpaces()
                switch peek() {
                case ",": index += 1
                case "]":
                    index += 1
                    return items
                case nil: throw invalid("arrays must end with ]")
                default: throw invalid("expected , or ] after an item in the array, not \(rest)")
                }
            }
        }

        /// A string in double quotes, with TOML's escapes.
        mutating func string() throws -> String {
            index += 1
            var result = String.UnicodeScalarView()
            while let scalar = peek() {
                index += 1
                switch scalar {
                case "\"":
                    return String(result)
                case "\\":
                    guard let escape = peek() else { throw invalid("a string is missing its closing \"") }
                    index += 1
                    switch escape {
                    case "b": result.append("\u{8}")
                    case "t": result.append("\t")
                    case "n": result.append("\n")
                    case "f": result.append("\u{C}")
                    case "r": result.append("\r")
                    case "e": result.append("\u{1B}")
                    case "\"": result.append("\"")
                    case "\\": result.append("\\")
                    case "u", "U":
                        let count = escape == "u" ? 4 : 8
                        let digits = String(String.UnicodeScalarView(scalars[index..<min(index + count, scalars.count)]))
                        guard digits.unicodeScalars.count == count, digits.allSatisfy(\.isHexDigit),
                            let value = UInt32(digits, radix: 16), let character = Unicode.Scalar(value)
                        else {
                            throw invalid("\\\(escape)\(digits) isn't a character")
                        }
                        result.append(character)
                        index += count
                    default:
                        throw invalid("\\\(escape) isn't an escape TOML knows; write \\\\ for a backslash")
                    }
                default:
                    if (scalar.value < 0x20 && scalar != "\t") || scalar.value == 0x7F {
                        throw invalid("a string can't hold control characters; use an escape such as \\n")
                    }
                    result.append(scalar)
                }
            }
            throw invalid("a string is missing its closing \"")
        }

        /// `true`, `false` or a decimal number. Dates and other forms of numbers are TOML,
        /// but not tincan's.
        mutating func scalar() throws -> Value {
            let start = index
            while let scalar = peek(), !" \t,]".unicodeScalars.contains(scalar) { index += 1 }
            let token = String(String.UnicodeScalarView(scalars[start..<index]))
            if token == "true" { return .bool(true) }
            if token == "false" { return .bool(false) }
            if token.wholeMatch(of: /[0-9]{4}-[0-9]{2}-[0-9]{2}.*|[0-9]{2}:[0-9]{2}(:[0-9]{2}.*)?/) != nil {
                throw unsupported("dates and times")
            }
            if token.wholeMatch(of: /0[xob][0-9A-Fa-f_]+/) != nil { throw unsupported("hexadecimal, octal and binary numbers") }
            let decimal = /[+-]?(0|[1-9](_?[0-9])*)(\.[0-9](_?[0-9])*)?([eE][+-]?[0-9](_?[0-9])*)?|[+-]?(inf|nan)/
            if token.wholeMatch(of: decimal) != nil, let number = Double(token.replacingOccurrences(of: "_", with: "")) {
                return .number(number)
            }
            if token.isEmpty { throw invalid("expected a value, not \(rest)") }
            throw invalid("\(token) isn't a value; text goes in double quotes, as in \"\(token)\"")
        }
    }
}
