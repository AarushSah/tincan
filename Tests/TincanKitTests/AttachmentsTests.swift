import Foundation
import Testing

@testable import TincanKit

/// `send --file` attaches one ordinary file from outside the places apps keep private data,
/// and staging copies exactly the file that was checked.
@Suite("Attachments")
struct AttachmentsTests {
    let directory: URL
    /// Stands in for `~/Library` in these tests.
    let library: URL

    init() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("tincan-attachments-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        // The real path (/private/var/…), as the checks report it.
        let real = try #require(realpath(temporary.path, nil))
        directory = URL(fileURLWithPath: String(cString: real), isDirectory: true)
        free(real)
        library = directory.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: library.appendingPathComponent("Messages"), withIntermediateDirectories: true)
        try Data("chat database".utf8).write(to: library.appendingPathComponent("Messages/chat.db"))
    }

    func file(_ name: String, bytes: Int = 12) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0x61, count: bytes).write(to: url)
        return url
    }

    func check(_ path: String) throws -> Attachments.File {
        try Attachments.check(path, protected: [library.path])
    }

    @Test func anOrdinaryFileIsAllowedWithItsSize() throws {
        let itinerary = try file("itinerary.pdf", bytes: 2_048)
        #expect(try check(itinerary.path) == Attachments.File(path: itinerary.path, bytes: 2_048))
    }

    @Test func linksAreFollowedAndCheckedWhereTheyLead() throws {
        let photo = try file("photo.jpeg")
        let alias = directory.appendingPathComponent("alias.jpeg")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: photo)
        #expect(try check(alias.path).path == photo.path)

        let sneaky = directory.appendingPathComponent("notes.txt")
        try FileManager.default.createSymbolicLink(at: sneaky, withDestinationURL: library.appendingPathComponent("Messages/chat.db"))
        #expect(throws: Attachments.Refusal.protectedLocation(path: library.appendingPathComponent("Messages/chat.db").path, folder: library.path)) {
            try check(sneaky.path)
        }
        // Another path to the same folder is still that folder.
        let door = directory.appendingPathComponent("door")
        try FileManager.default.createSymbolicLink(at: door, withDestinationURL: library)
        #expect(throws: Attachments.Refusal.self) { try check(door.path + "/Messages/chat.db") }
        #expect(throws: Attachments.Refusal.self) { try check(library.path) }
    }

    @Test func foldersPipesHardLinksAndLargeFilesAreRefused() throws {
        let folder = directory.appendingPathComponent("Trip", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(throws: Attachments.Refusal.notAFile(path: folder.path, isFolder: true)) { try check(folder.path) }

        let pipe = directory.appendingPathComponent("pipe")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        #expect(throws: Attachments.Refusal.notAFile(path: pipe.path, isFolder: false)) { try check(pipe.path) }

        let original = try file("original.txt")
        let second = directory.appendingPathComponent("second-name.txt")
        try FileManager.default.linkItem(at: original, to: second)
        do {
            _ = try check(second.path)
            Issue.record("A file with two names was allowed")
        } catch Attachments.Refusal.hardLinked {
        }

        // Sparse, so the test writes almost nothing.
        let large = try file("movie.mov", bytes: 0)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(Attachments.maximumBytes + 1))
        try handle.close()
        #expect(throws: Attachments.Refusal.tooLarge(path: large.path, bytes: Attachments.maximumBytes + 1)) { try check(large.path) }

        #expect(throws: Attachments.Refusal.unreadable(path: directory.appendingPathComponent("missing.txt").path)) {
            try check(directory.appendingPathComponent("missing.txt").path)
        }
    }

    @Test func hiddenFilesInTheHomeFolderAndSystemFilesAreRefused() throws {
        // A stand-in home folder, with visible and hidden files and folders.
        let home = directory.appendingPathComponent("home", isDirectory: true)
        for folder in ["Documents", ".ssh", "Projects/.git"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for name in ["Documents/plan.pdf", ".ssh/id_ed25519", ".zsh_history", "Projects/.git/config", "Projects/notes.txt"] {
            try Data("x".utf8).write(to: home.appendingPathComponent(name))
        }
        func check(_ path: String) throws -> Attachments.File {
            try Attachments.check(path, protected: [library.path], homes: [home.path], open: ["/Volumes", "/private/tmp"])
        }
        #expect(try check(home.appendingPathComponent("Documents/plan.pdf").path).bytes == 1)
        #expect(try check(home.appendingPathComponent("Projects/notes.txt").path).bytes == 1)
        let key = home.appendingPathComponent(".ssh/id_ed25519").path
        #expect(throws: Attachments.Refusal.hiddenLocation(path: key, item: home.appendingPathComponent(".ssh").path)) { try check(key) }
        let history = home.appendingPathComponent(".zsh_history").path
        #expect(throws: Attachments.Refusal.hiddenLocation(path: history, item: history)) { try check(history) }
        #expect(throws: Attachments.Refusal.self) { try check(home.appendingPathComponent("Projects/.git/config").path) }
        // A link from a visible place to a hidden one is checked where it leads.
        let alias = home.appendingPathComponent("Documents/key.txt")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: URL(fileURLWithPath: key))
        #expect(throws: Attachments.Refusal.hiddenLocation(path: key, item: home.appendingPathComponent(".ssh").path)) { try check(alias.path) }
        // Outside the home folder and the open folders, nothing is attached.
        #expect(throws: Attachments.Refusal.systemLocation(path: directory.appendingPathComponent("elsewhere.txt").path)) {
            try check(try file("elsewhere.txt").path)
        }
        #expect(throws: Attachments.Refusal.systemLocation(path: "/private/etc/hosts")) { try check("/etc/hosts") }
        // Devices say what they are, wherever they are.
        #expect(throws: Attachments.Refusal.device(path: "/dev/zero")) { try Attachments.check("/dev/zero") }
        #expect(throws: Attachments.Refusal.device(path: "/dev/null")) { try Attachments.check("/dev/null") }
    }

    /// A drive or temporary folder can hold a copy of a home folder, such as a backup, so
    /// hidden and Library folders are closed there too.
    @Test func copiesOfPrivateFoldersInOpenFoldersAreRefused() throws {
        let backup = directory.appendingPathComponent("Backup/Users/maya", isDirectory: true)
        for folder in ["Library/Messages", ".ssh", "Pictures"] {
            try FileManager.default.createDirectory(at: backup.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for name in ["Library/Messages/chat.db", ".ssh/id_ed25519", "Pictures/beach.jpg", ".env"] {
            try Data("x".utf8).write(to: backup.appendingPathComponent(name))
        }
        func check(_ path: String) throws -> Attachments.File {
            try Attachments.check(path, protected: [], homes: [], open: [directory.path])
        }
        #expect(try check(backup.appendingPathComponent("Pictures/beach.jpg").path).bytes == 1)
        let database = backup.appendingPathComponent("Library/Messages/chat.db").path
        #expect(throws: Attachments.Refusal.protectedLocation(path: database, folder: backup.appendingPathComponent("Library").path)) {
            try check(database)
        }
        let key = backup.appendingPathComponent(".ssh/id_ed25519").path
        #expect(throws: Attachments.Refusal.hiddenLocation(path: key, item: backup.appendingPathComponent(".ssh").path)) { try check(key) }
        let secrets = backup.appendingPathComponent(".env").path
        #expect(throws: Attachments.Refusal.hiddenLocation(path: secrets, item: secrets)) { try check(secrets) }
    }

    @Test func temporaryFoldersAndVolumesAreOpen() {
        let open = Attachments.openPaths(environment: ["TMPDIR": "/private/var/folders/xy/abc/T/"], userTemporary: "/private/var/folders/xy/abc/T/")
        #expect(open.contains("/Volumes"))
        #expect(open.contains("/tmp"))
        #expect(open.contains("/private/var/folders/xy/abc/T/"))
        // Beside your temporary folder, apps keep caches and other data.
        #expect(!open.contains("/private/var/folders"))
        let elsewhere = Attachments.openPaths(environment: ["TMPDIR": "/private/var/folders/xy/abc/C/"], userTemporary: "/private/var/folders/xy/abc/T/")
        #expect(!elsewhere.contains("/private/var/folders/xy/abc/C/"))
        #expect(Attachments.openPaths(environment: ["TMPDIR": "/Volumes/Scratch/tmp/"], userTemporary: nil).contains("/Volumes/Scratch/tmp/"))
        // TMPDIR opens nothing beyond the temporary folders: not the system, the rest of
        // /private/var or a hidden folder in the home folder.
        let home = String(cString: getpwuid(getuid())!.pointee.pw_dir!)
        for widened in ["/", "/private/var/", "/var", "/etc", home, home + "/.ssh"] {
            #expect(!Attachments.openPaths(environment: ["TMPDIR": widened], userTemporary: nil).contains(widened), "\(widened)")
        }
        #expect(Attachments.accountHomePaths() == [home])
        // The default rules allow this test's temporary folder.
        #expect((try? Attachments.check(directory.appendingPathComponent("missing").path)) == nil)
    }

    @Test func theRealLibraryAndSettingsAreProtected() {
        let paths = Attachments.protectedPaths(environment: [:])
        let home = String(cString: getpwuid(getuid())!.pointee.pw_dir!)
        #expect(paths.contains(home + "/Library"))
        #expect(paths.contains(home + "/.config/tincan"))
        // A settings file of the person's choosing is protected, not the folder it is in.
        let custom = Attachments.protectedPaths(environment: ["TINCAN_CONFIG": "/tmp/tincan-test/config.toml"])
        #expect(!custom.contains("/tmp/tincan-test"))
    }

    @Test func stagingCopiesOnlyOneOrdinaryFile() throws {
        let staging = directory.appendingPathComponent("staging").path
        let photo = try file("photo.jpeg", bytes: 300_000)
        let staged = try MessagesAutomation.stage(photo.path, into: staging, protected: [library.path])
        #expect(staged.hasPrefix(staging + "/"))
        #expect(staged.hasSuffix("/photo.jpeg"))
        #expect(FileManager.default.contentsEqual(atPath: staged, andPath: photo.path))
        #expect((try FileManager.default.attributesOfItem(atPath: staged)[.posixPermissions] as? Int) == 0o600)

        let folder = directory.appendingPathComponent("Trip", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(throws: Attachments.Refusal.self) { try MessagesAutomation.stage(folder.path, into: staging, protected: [library.path]) }
        let alias = directory.appendingPathComponent("alias.jpeg")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: photo)
        #expect(throws: Attachments.Refusal.symbolicLink(path: alias.path)) {
            try MessagesAutomation.stage(alias.path, into: staging, protected: [library.path])
        }
        #expect(throws: Attachments.Refusal.self) {
            try MessagesAutomation.stage(library.appendingPathComponent("Messages/chat.db").path, into: staging, protected: [library.path])
        }
        // Nothing but the one photo was copied.
        let copies = try FileManager.default.subpathsOfDirectory(atPath: staging).filter { !$0.hasSuffix("/") }
        #expect(copies.filter { $0.contains("/") }.count == 1)
    }

    @Test func onlyYourTemporaryFolderIsOpenInVarFolders() throws {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count) > 0, let temporary = Attachments.userTemporaryDirectory() else { return }
        let name = "tincan-test-\(UUID().uuidString).txt"
        let cache = URL(fileURLWithPath: String(nulTerminated: buffer)).appendingPathComponent(name)
        let allowed = URL(fileURLWithPath: temporary).appendingPathComponent(name)
        try Data("x".utf8).write(to: cache)
        try Data("x".utf8).write(to: allowed)
        defer {
            try? FileManager.default.removeItem(at: cache)
            try? FileManager.default.removeItem(at: allowed)
        }
        #expect(throws: Attachments.Refusal.systemLocation(path: Attachments.resolvedPath(cache.path))) { try Attachments.check(cache.path) }
        #expect(try Attachments.check(allowed.path).bytes == 1)
    }
}
