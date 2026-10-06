import Foundation
import Testing

@testable import TincanKit

@Suite("Configuration")
struct ConfigTests {
    @Test func parsesEverySetting() throws {
        let config = try Config.parse(
            """
            # comment
            region = "gb"

            [send]
            wpm = 55.5   # fast
            typing = "paced"

            [privacy]
            exclude = ["chat:750", "chat:12"]
            """)
        #expect(config.region == "GB")
        #expect(config.wordsPerMinute == 55.5)
        #expect(config.typing == .paced)
        #expect(config.excludedChats == ["chat:750", "chat:12"])
    }

    @Test func missingSettingsUseDefaults() throws {
        let config = try Config.parse("")
        #expect(config == Config())
        #expect(config.typing == .auto)
    }

    @Test func renderedConfigParsesBackToTheSameValues() throws {
        var config = Config()
        config.region = "JP"
        config.wordsPerMinute = 60
        config.typing = .keyboard
        config.excludedChats = ["chat:1"]
        #expect(try Config.parse(config.render()) == config)
    }

    @Test func entriesWithQuotesBackslashesAndControlCharactersSurviveSaving() throws {
        var config = Config()
        config.excludedChats = ["any;-;\"quoted\"", #"back\slash"#, "line\nbreak\ttab\u{7}bell", "Ava 🌸 Lin", ""]
        #expect(try Config.parse(config.render()) == config)
    }

    @Test(
        "A setting tincan doesn't know is an error that names its line, so a typo never drops exclusions",
        arguments: [
            ("[privacy]\nexlude = [\"chat:1\"]", 2, "privacy.exlude"),
            ("[Privacy]\nexclude = [\"chat:1\"]", 2, "Privacy.exclude"),
            ("exclude = [\"chat:1\"]", 1, "exclude"),
            ("region = \"US\"\n\n[send]\nwpm = 60\nspeed = 2", 5, "send.speed"),
        ])
    func unknownSettingsAreErrors(text: String, line: Int, key: String) {
        #expect(throws: TOMLLite.Error.invalid(line: line, message: "\(key) isn't a setting; the settings are region, send.wpm, send.typing, privacy.exclude"))
        {
            try Config.parse(text)
        }
    }

    @Test func rejectsInvalidValues() {
        #expect(throws: (any Error).self) { try Config.parse("[send]\ntyping = \"telepathy\"") }
        #expect(throws: (any Error).self) { try Config.parse("[send]\nwpm = \"fast\"") }
        #expect(throws: (any Error).self) { try Config.parse("region") }
    }

    @Test(
        "Settings of the wrong type are errors, never ignored",
        arguments: [
            "[privacy]\nexclude = \"any;-;+14155550142\"", // one chat, not a list: must not read it anyway
            "region = 44",
            "[send]\ntyping = true",
        ])
    func wrongTypes(text: String) {
        #expect(throws: (any Error).self) { try Config.parse(text) }
    }

    @Test func unknownRegionsAreErrors() throws {
        #expect(throws: (any Error).self) { try Config.parse("region = \"USA\"") }
        #expect(try Config.parse("region = \"\"").region == nil)
    }

    @Test func listsMaySpanLinesWithComments() throws {
        let config = try Config.parse(
            """
            [privacy]
            exclude = [
              "chat:1",  # the clinic
              "any;-;+14155550177",
            ]

            [send]
            wpm = 50
            """)
        #expect(config.excludedChats == ["chat:1", "any;-;+14155550177"])
        #expect(config.wordsPerMinute == 50)
    }

    @Test func aListThatNeverClosesIsAnError() {
        #expect(throws: (any Error).self) { try Config.parse("[privacy]\nexclude = [\n  \"chat:1\",\n") }
    }

    @Test func hashesInsideStringsAreNotComments() throws {
        let values = try TOMLLite.parse("name = \"a # b\" # real comment")
        #expect(values["name"] == .string("a # b"))
    }

    @Test func theWholeSubsetParses() throws {
        let values = try TOMLLite.parse(
            #"""
            # dotted keys, with or without spaces around the dots
            send.wpm = 1_000
            privacy . exclude = [ "caf\u00E9", "\U0001F9D7", "tab\there", "quote \" and \\", ] # a comma may end the list
            [ extra ]   # a header may have spaces and a comment
            yes = true
            no = false
            small = -1.5e-1
            signed = +4
            forever = inf
            note = "it's # not a comment"
            """#)
        #expect(values["send.wpm"] == .number(1000))
        #expect(values["privacy.exclude"] == .array(["café", "🧗", "tab\there", "quote \" and \\"]))
        #expect(values["extra.yes"] == .bool(true))
        #expect(values["extra.no"] == .bool(false))
        #expect(values["extra.small"] == .number(-0.15))
        #expect(values["extra.signed"] == .number(4))
        #expect(values["extra.forever"] == .number(.infinity))
        #expect(values["extra.note"] == .string("it's # not a comment"))
    }

    @Test func windowsLineEndingsKeepLineNumbers() {
        #expect(throws: TOMLLite.Error.unsupported(line: 3, construct: "inline tables")) {
            try TOMLLite.parse("[send]\r\nwpm = 42\r\ntyping = { mode = \"auto\" }\r\n")
        }
    }

    @Test(
        "Valid TOML outside the subset is named, never misread",
        arguments: [
            (#"[send]\#nwpm = { value = 42 }"#, 2, "inline tables"),
            (#"[[privacy]]\#nexclude = []"#, 1, "arrays of tables"),
            (#"region = 'US'"#, 1, "literal strings in single quotes"),
            (#"[privacy]\#nexclude = ['chat:1']"#, 2, "literal strings in single quotes"),
            (#"note = """\#nhello\#n""""#, 1, "multi-line strings"),
            (#"note = '''hello'''"#, 1, "multi-line strings"),
            (#"[privacy]\#nexclude = [\#n  "chat:1",\#n  42,\#n]"#, 2, "numbers in arrays"),
            (#"flags = [true]"#, 1, "true and false in arrays"),
            (#"[privacy]\#nexclude = [["chat:1"]]"#, 2, "arrays inside arrays"),
            (#"[privacy]\#nexclude = [{ chat = 1 }]"#, 2, "inline tables"),
            (#"since = 2026-09-01"#, 1, "dates and times"),
            (#"at = 1979-05-27T07:32:00Z"#, 1, "dates and times"),
            (#"at = 07:32:00"#, 1, "dates and times"),
            (#"[send]\#nwpm = 0x2A"#, 2, "hexadecimal, octal and binary numbers"),
            (#""region" = "US""#, 1, "quoted keys"),
            (#"["send"]\#nwpm = 42"#, 1, "quoted keys"),
            (#"send.'wpm' = 42"#, 1, "quoted keys"),
        ])
    func unsupportedTOML(text: String, line: Int, construct: String) {
        #expect(throws: TOMLLite.Error.unsupported(line: line, construct: construct), "\(text)") { try Config.parse(text) }
    }

    @Test(
        "Text that isn't TOML is a mistake",
        arguments: [
            (#"region = US"#, 1, #"US isn't a value; text goes in double quotes, as in "US""#),
            (#"region = "US"\#nregion = "GB""#, 2, "region is set twice"),
            (#"[send]\#nwpm = 42\#n[send]"#, 3, "the [send] table appears twice"),
            (#"[privacy]\#nexclude = ["a" "b"]"#, 2, #"expected , or ] after an item in the array, not "b"]"#),
            (#"region = "US" "GB""#, 1, #"unexpected "GB" after the value"#),
            (#"region = "US"#, 1, #"a string is missing its closing ""#),
            (#"region = "\x""#, 1, #"\x isn't an escape TOML knows; write \\ for a backslash"#),
            (#"region ="#, 1, "region has no value"),
            (#"wpm 42"#, 1, "expected key = value"),
            (#"my key = 1"#, 1, "my key isn't a key: keys are letters, digits, - and _"),
        ])
    func notTOML(text: String, line: Int, message: String) {
        #expect(throws: TOMLLite.Error.invalid(line: line, message: message), "\(text)") { try Config.parse(text) }
    }

    @Test func savesWithPrivatePermissions() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("tincan-\(UUID().uuidString)/config.toml").path
        var config = Config()
        config.excludedChats = ["chat:9"]
        try config.save(path: path)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try Config.load(path: path) == config)
    }

    /// A home folder of its own, so no test reads or writes this Mac's settings.
    private func home(withSettings settings: String?) throws -> String {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tincan-home-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: home + "/.config/tincan", withIntermediateDirectories: true)
        if let settings { try settings.write(toFile: home + "/.config/tincan/config.toml", atomically: true, encoding: .utf8) }
        return home
    }

    @Test func overridesMoveTheSettingsFile() throws {
        let home = "/Users/example"
        #expect(
            Config.location(environment: [:], home: home)
                == Config.Location(path: "/Users/example/.config/tincan/config.toml", standardPath: "/Users/example/.config/tincan/config.toml", variable: nil))
        #expect(Config.location(environment: ["XDG_CONFIG_HOME": "/tmp/xdg"], home: home).path == "/tmp/xdg/tincan/config.toml")
        let both = Config.location(environment: ["XDG_CONFIG_HOME": "/tmp/xdg", "TINCAN_CONFIG": "/tmp/other.toml"], home: home)
        #expect(both.path == "/tmp/other.toml")
        #expect(both.variable == "TINCAN_CONFIG")
        #expect(Config.location(environment: ["TINCAN_CONFIG": "", "XDG_CONFIG_HOME": ""], home: home).variable == nil)
    }

    @Test func aFreshInstallUsesDefaults() throws {
        let home = try home(withSettings: nil)
        #expect(try Config.load(environment: [:], home: home) == Config())
        // XDG_CONFIG_HOME is often set for other tools; with no settings anywhere, it is still a fresh install.
        #expect(try Config.load(environment: ["XDG_CONFIG_HOME": home + "/xdg"], home: home) == Config())
    }

    @Test func overridesThatFindSettingsReadThem() throws {
        let home = try home(withSettings: "[privacy]\nexclude = [\"chat:1\"]\n")
        #expect(try Config.load(environment: [:], home: home).excludedChats == ["chat:1"])
        let other = home + "/other.toml"
        try "[privacy]\nexclude = [\"chat:2\"]\n".write(toFile: other, atomically: true, encoding: .utf8)
        #expect(try Config.load(environment: ["TINCAN_CONFIG": other], home: home).excludedChats == ["chat:2"])
        try FileManager.default.createDirectory(atPath: home + "/xdg/tincan", withIntermediateDirectories: true)
        try "[privacy]\nexclude = [\"chat:3\"]\n".write(toFile: home + "/xdg/tincan/config.toml", atomically: true, encoding: .utf8)
        #expect(try Config.load(environment: ["XDG_CONFIG_HOME": home + "/xdg"], home: home).excludedChats == ["chat:3"])
    }

    @Test func overridesThatMissTheSettingsNeverFallBackToDefaults() throws {
        // Defaults here would quietly drop the exclusions in the person's settings.
        let home = try home(withSettings: "[privacy]\nexclude = [\"chat:1\"]\n")
        let standard = home + "/.config/tincan/config.toml"
        #expect(throws: ConfigError.missing(path: home + "/xdg/tincan/config.toml", variable: "XDG_CONFIG_HOME", standardPath: standard)) {
            try Config.load(environment: ["XDG_CONFIG_HOME": home + "/xdg"], home: home)
        }
        #expect(throws: ConfigError.missing(path: home + "/gone.toml", variable: "TINCAN_CONFIG", standardPath: standard)) {
            try Config.load(environment: ["TINCAN_CONFIG": home + "/gone.toml"], home: home)
        }
        // TINCAN_CONFIG names one file on purpose: missing is an error even with no other settings.
        let fresh = try self.home(withSettings: nil)
        #expect(throws: ConfigError.missing(path: fresh + "/gone.toml", variable: "TINCAN_CONFIG", standardPath: nil)) {
            try Config.load(environment: ["TINCAN_CONFIG": fresh + "/gone.toml"], home: fresh)
        }
    }

    @Test func overridesKeepTheStandardExclusionsWhenReadingThisMac() throws {
        let home = try home(withSettings: "[privacy]\nexclude = [\"any;-;+14155550142\", \"chat:1\"]\n")
        let standard = home + "/.config/tincan/config.toml"
        let empty = home + "/empty.toml"
        try "".write(toFile: empty, atomically: true, encoding: .utf8)
        #expect(throws: ConfigError.dropsExclusions(path: empty, variable: "TINCAN_CONFIG", standardPath: standard, count: 2)) {
            try Config.load(environment: ["TINCAN_CONFIG": empty], home: home, keepingStandardExclusions: true)
        }
        try FileManager.default.createDirectory(atPath: home + "/xdg/tincan", withIntermediateDirectories: true)
        try "[privacy]\nexclude = [\"chat:1\"]\n".write(toFile: home + "/xdg/tincan/config.toml", atomically: true, encoding: .utf8)
        #expect(
            throws: ConfigError.dropsExclusions(path: home + "/xdg/tincan/config.toml", variable: "XDG_CONFIG_HOME", standardPath: standard, count: 1)
        ) {
            try Config.load(environment: ["XDG_CONFIG_HOME": home + "/xdg"], home: home, keepingStandardExclusions: true)
        }
        // A file that keeps every exclusion, and may add its own, is read.
        let more = home + "/more.toml"
        try "[privacy]\nexclude = [\"chat:1\", \"chat:9\", \"any;-;+14155550142\"]\n".write(toFile: more, atomically: true, encoding: .utf8)
        #expect(try Config.load(environment: ["TINCAN_CONFIG": more], home: home, keepingStandardExclusions: true).excludedChats.count == 3)
        // Fixture data, which isn't this Mac's, may use any settings.
        #expect(try Config.load(environment: ["TINCAN_CONFIG": empty], home: home).excludedChats.isEmpty)
    }

    @Test func typingSpeedInTheFileMustBeInRange() {
        #expect(throws: (any Error).self) { try Config.parse("[send]\nwpm = 0") }
        #expect(throws: (any Error).self) { try Config.parse("[send]\nwpm = 900") }
        #expect((try? Config.parse("[send]\nwpm = 60"))?.wordsPerMinute == 60)
    }

    @Test func savedSettingsAreReadableOnlyByYou() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tincan-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let directory = base.appendingPathComponent("tincan")
        let path = directory.appendingPathComponent("config.toml").path
        func mode(_ path: String) -> Int? { (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]) as? Int }
        try Config().save(path: path)
        #expect(mode(directory.path) == 0o700)
        #expect(mode(path) == 0o600)
        // Whatever mode the file had, saving makes it private again.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        var config = Config()
        config.wordsPerMinute = 60
        try config.save(path: path)
        #expect(mode(path) == 0o600)
        #expect(try Config.load(path: path).wordsPerMinute == 60)
    }
}
