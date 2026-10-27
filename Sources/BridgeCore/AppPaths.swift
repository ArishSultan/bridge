import Darwin
import Foundation

/// Where the app keeps what no sandboxed terminal may touch, and the folders sandboxed terminals
/// get of their own.
extension Paths {
    /// `~/Library/Application Support/Bridge`: the app's data store and the vault's ssh-agent.
    /// Hidden from every sandbox, whatever its profile says.
    public static var dataDirectory: URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Bridge", isDirectory: true)
    }

    /// The user's temporary folder as the system reports it, not `$TMPDIR` (which whoever started
    /// the app could have changed).
    public static var temporaryDirectory: URL {
        URL(fileURLWithPath: confstr(_CS_DARWIN_USER_TEMP_DIR) ?? NSTemporaryDirectory(), isDirectory: true)
    }

    /// The user's cache folder in `/var/folders` (compilers keep module caches there).
    public static var userCacheDirectory: String? {
        confstr(_CS_DARWIN_USER_CACHE_DIR).map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
    }

    /// The shells' socket. Sandboxes can't write in this folder, so nothing in one can move the
    /// socket away or put its own in its place.
    public static var runDirectory: URL {
        temporaryDirectory.appendingPathComponent("bridge-run", isDirectory: true)
    }

    /// The folder every sandboxed terminal's own temporary folder is in.
    public static var paneTemporaryRoot: URL {
        temporaryDirectory.appendingPathComponent("bridge-panes", isDirectory: true)
    }

    /// A sandboxed terminal's own temporary folder (its `TMPDIR`), which no other terminal sees.
    public static func paneTemporary(_ pane: ID) -> URL {
        paneTemporaryRoot.appendingPathComponent("pane-\(pane)", isDirectory: true)
    }

    /// The folder every project's sandbox caches are in.
    public static var sandboxStateRoot: URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Caches/Bridge/Sandboxes", isDirectory: true)
    }

    /// Caches for tools in a project's sandboxes (Go, Cargo, pip, uv…), kept apart from the ones
    /// terminals outside the sandbox use, so a sandbox can't plant code that they later run.
    public static func sandboxState(project: ID) -> URL {
        sandboxStateRoot.appendingPathComponent("project-\(project)", isDirectory: true)
    }

    /// Make a folder only this user can use, refusing one that is a link or belongs to someone
    /// else (another user could have made it first in a shared place).
    public static func makePrivateDirectory(_ url: URL) throws {
        let path = url.path
        if mkdir(path, 0o700) != 0 && errno != EEXIST {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else {
            throw POSIXError(.EPERM)
        }
        if info.st_mode & 0o077 != 0 { chmod(path, 0o700) }
    }

    private static func confstr(_ name: Int32) -> String? {
        let size = Darwin.confstr(name, nil, 0)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard Darwin.confstr(name, &buffer, size) > 0 else { return nil }
        let value = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return value.isEmpty ? nil : value
    }
}
