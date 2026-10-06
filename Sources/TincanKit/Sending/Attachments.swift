import Darwin
import Foundation

/// Which files tincan attaches to messages.
///
/// tincan runs with Full Disk Access, which reaches far more than anyone means to share,
/// and an assistant asking it to send can be misled. So a file is attached only when it is
/// one ordinary file, no larger than Messages sends, with no other name (a hard link) that
/// could live elsewhere, and in a place people keep files to share: the home folder's
/// visible files and folders, external volumes (`/Volumes`) and temporary folders. Never
/// from `~/Library` (where Messages, call history, Mail, Safari, keychains and other apps
/// keep private data), tincan's own settings, hidden files and folders in the home folder
/// (`~/.ssh`, `~/.zsh_history`, `~/.aws`, …), devices, or the rest of the system.
/// Symbolic links are followed first, and the checks apply to the file they lead to.
public enum Attachments {
    /// The largest file Messages sends.
    public static let maximumBytes: Int64 = 100_000_000

    /// A file that may be attached: where it really is, and its size.
    public struct File: Sendable, Equatable {
        public let path: String
        public let bytes: Int64
    }

    public enum Refusal: Error, Equatable, Sendable, CustomStringConvertible {
        /// Nothing is there, or tincan can't open it.
        case unreadable(path: String)
        /// Inside `folder`, one of the places tincan never attaches from.
        case protectedLocation(path: String, folder: String)
        /// A hidden file, or one inside the hidden folder `item`.
        case hiddenLocation(path: String, item: String)
        /// Outside the home folder, external volumes and temporary folders.
        case systemLocation(path: String)
        /// A device, such as /dev/zero.
        case device(path: String)
        /// A folder, device, pipe or anything else that isn't one ordinary file.
        case notAFile(path: String, isFolder: Bool)
        /// A symbolic link where tincan expected the file itself.
        case symbolicLink(path: String)
        /// The file has other names, so tincan can't tell where it really lives.
        case hardLinked(path: String)
        case tooLarge(path: String, bytes: Int64)

        public var description: String {
            switch self {
            case .unreadable(let path): return "can't read \(path)"
            case .protectedLocation(let path, let folder): return "\(path) is in \(folder), which tincan never attaches from"
            case .hiddenLocation(let path, let item): return path == item ? "\(path) is a hidden file" : "\(path) is in \(item), a hidden folder"
            case .systemLocation(let path): return "\(path) is outside your home folder, /Volumes and temporary folders"
            case .device(let path): return "\(path) is a device, not a file"
            case .notAFile(let path, let isFolder): return isFolder ? "\(path) is a folder, not a file" : "\(path) isn't an ordinary file"
            case .symbolicLink(let path): return "\(path) is a symbolic link"
            case .hardLinked(let path): return "\(path) has other names on this Mac (hard links)"
            case .tooLarge(let path, let bytes): return "\(path) is \(bytes) bytes; Messages sends files up to \(maximumBytes) bytes"
            }
        }
    }

    /// Checks the file at `path` (`~` is expanded, links are followed) and returns where it
    /// really is and its size. `protected` lists the places to refuse, `homes` the home
    /// folders whose visible files may be attached, and `open` the other folders files may
    /// come from; tests pass their own.
    public static func check(
        _ path: String, protected: [String] = protectedPaths(), homes: [String] = accountHomePaths(), open: [String] = openPaths()
    ) throws -> File {
        let expanded = NSString(string: path).expandingTildeInPath
        guard let real = realpath(expanded, nil) else { throw Refusal.unreadable(path: expanded) }
        let resolved = String(cString: real)
        free(real)
        let rules = Self.rules(protected: protected, homes: homes, open: open)
        // Refuse by place before opening anything there. A device isn't a place, but
        // opening one can block or never end.
        var info = stat()
        if stat(resolved, &info) == 0, isDevice(info.st_mode) { throw Refusal.device(path: resolved) }
        if let refusal = refusal(forPlace: resolved, rules: rules) { throw refusal }
        let descriptor = try self.open(resolved)
        defer { close(descriptor) }
        let bytes = try inspect(descriptor, path: resolved, rules: rules)
        return File(path: resolved, bytes: bytes)
    }

    /// The places `check` refuses: `~/Library` and tincan's settings, for the home folder
    /// in the user database as well as the one the environment names, so changing `HOME`
    /// or `CFFIXED_USER_HOME` moves nothing out of reach. With `TINCAN_CONFIG` naming a
    /// file in a folder of the person's choosing, that file is refused, not its folder.
    public static func protectedPaths(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var paths = homePaths().flatMap { [$0 + "/Library", $0 + "/.config/tincan"] }
        let config = Config.defaultPath
        paths.append(config)
        if environment["TINCAN_CONFIG"].map({ $0.isEmpty }) ?? true {
            paths.append((config as NSString).deletingLastPathComponent)
        }
        return paths
    }

    /// The home folder in the user database, and the one the environment names.
    public static func homePaths() -> [String] {
        var homes = [NSHomeDirectory()]
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            homes.insert(String(cString: directory), at: 0)
        }
        return homes
    }

    /// The home folder whose visible files may be attached: only the one in the user
    /// database, so `CFFIXED_USER_HOME` can't open the rest of the system.
    public static func accountHomePaths() -> [String] {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return [] }
        return [String(cString: directory)]
    }

    /// Folders besides the home folder that files may be attached from: external volumes
    /// and temporary folders. Under `/private/var/folders`, only your temporary folder (its
    /// `T` folder): apps keep caches and other data beside it. `TMPDIR` adds a folder only
    /// when it is that one or inside `/Volumes` or `/tmp`, so it can't open `/`, `/private/var`
    /// or a hidden folder in the home folder.
    public static func openPaths(
        environment: [String: String] = ProcessInfo.processInfo.environment, userTemporary: String? = userTemporaryDirectory()
    ) -> [String] {
        var paths = ["/Volumes", "/tmp", "/private/tmp"]
        if let userTemporary { paths.append(userTemporary) }
        for temporary in [NSTemporaryDirectory(), environment["TMPDIR"] ?? ""] where !temporary.isEmpty {
            let real = resolvedPath(temporary)
            let inOpen = ["/Volumes", "/private/tmp"].contains { real == $0 || real.hasPrefix($0 + "/") }
            let isUserTemporary = userTemporary.map { real == resolvedPath($0) } ?? false
            if inOpen || isUserTemporary { paths.append(temporary) }
        }
        return paths
    }

    /// Your temporary folder, `getconf DARWIN_USER_TEMP_DIR`, whatever `TMPDIR` says.
    public static func userTemporaryDirectory() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 else { return nil }
        let path = String(nulTerminated: buffer)
        return path.isEmpty ? nil : path
    }

    /// `path` with links resolved and no trailing slash.
    static func resolvedPath(_ path: String) -> String {
        guard let pointer = Darwin.realpath(path, nil) else { return (path as NSString).standardizingPath }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    /// Where files may come from, by identity: see `Place`.
    struct Rules {
        let protected: [Place]
        let homes: [Place]
        let open: [Place]
    }

    static func rules(protected: [String] = protectedPaths(), homes: [String] = accountHomePaths(), open: [String] = openPaths()) -> Rules {
        Rules(protected: identities(protected), homes: identities(homes), open: identities(open))
    }

    // MARK: Checks

    /// Opens `path` for reading without following a symbolic link at its end, or waiting on
    /// a pipe.
    static func open(_ path: String) throws -> Int32 {
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw errno == ELOOP ? Refusal.symbolicLink(path: path) : Refusal.unreadable(path: path)
        }
        return descriptor
    }

    /// Checks the file `descriptor` has open and returns its size. The location is checked
    /// again from the open file itself, so nothing swapped in after `check` gets through.
    static func inspect(_ descriptor: Int32, path: String, rules: Rules) throws -> Int64 {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { throw Refusal.unreadable(path: path) }
        let opened = String(nulTerminated: buffer)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw Refusal.unreadable(path: path) }
        if isDevice(info.st_mode) { throw Refusal.device(path: opened) }
        if let refusal = refusal(forPlace: opened, rules: rules) { throw refusal }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw Refusal.notAFile(path: opened, isFolder: info.st_mode & S_IFMT == S_IFDIR)
        }
        guard info.st_nlink <= 1 else { throw Refusal.hardLinked(path: opened) }
        guard Int64(info.st_size) <= maximumBytes else { throw Refusal.tooLarge(path: opened, bytes: Int64(info.st_size)) }
        return Int64(info.st_size)
    }

    /// A protected file or folder, by device and inode, so another spelling of its path
    /// (letter case, `/System/Volumes/Data`, a linked folder) still matches.
    struct Place {
        let path: String
        let device: dev_t
        let inode: ino_t
    }

    static func identities(_ paths: [String]) -> [Place] {
        paths.compactMap { path in
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            return Place(path: path, device: info.st_dev, inode: info.st_ino)
        }
    }

    static func isDevice(_ mode: mode_t) -> Bool {
        mode & S_IFMT == S_IFCHR || mode & S_IFMT == S_IFBLK
    }

    /// Why nothing at `path` may be attached, or nil when its place allows it: not in a
    /// protected place, and in a home folder without a hidden file or folder on the way, or
    /// in an open folder without a hidden file or folder or a `Library` folder on the way.
    /// The deepest of those folders decides.
    static func refusal(forPlace path: String, rules: Rules) -> Refusal? {
        if let folder = protectedFolder(containing: path, places: rules.protected) {
            return .protectedLocation(path: path, folder: folder)
        }
        var current = path
        // The names from `current` down to `path`, deepest first.
        var below: [String] = []
        while true {
            var info = stat()
            if lstat(current, &info) == 0 {
                func matches(_ place: Place) -> Bool { place.device == info.st_dev && place.inode == info.st_ino }
                if rules.homes.contains(where: matches) {
                    var item = current
                    for name in below.reversed() {
                        item += "/" + name
                        if name.hasPrefix(".") { return .hiddenLocation(path: path, item: item) }
                    }
                    return nil
                }
                if rules.open.contains(where: matches) {
                    // An open folder can hold a copy of a home folder, such as a backup or a
                    // clone on another drive, so its private folders stay closed there too.
                    var item = current
                    for name in below.reversed() {
                        item += "/" + name
                        if name.hasPrefix(".") { return .hiddenLocation(path: path, item: item) }
                        if name.caseInsensitiveCompare("Library") == .orderedSame { return .protectedLocation(path: path, folder: item) }
                    }
                    return nil
                }
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { return .systemLocation(path: path) }
            below.append((current as NSString).lastPathComponent)
            current = parent
        }
    }

    /// The protected place that is `path` or one of its folders.
    static func protectedFolder(containing path: String, places: [Place]) -> String? {
        guard !places.isEmpty else { return nil }
        var current = path
        while true {
            var info = stat()
            if lstat(current, &info) == 0, let place = places.first(where: { $0.device == info.st_dev && $0.inode == info.st_ino }) {
                return place.path
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { return nil }
            current = parent
        }
    }
}
