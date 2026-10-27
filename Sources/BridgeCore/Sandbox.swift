import Foundation

/// Sandboxed terminals, for running agents. Two engines, chosen per profile:
/// - **Seatbelt**, macOS's own sandbox (what Claude Code and Codex use): the user's shell and
///   tools, but writes only inside the project and chosen paths, credentials hidden, network
///   optionally cut, and some programs refused. With reads confined, file contents can only be
///   read in the project, system folders and the shell's and toolchains' setup in the home
///   folder; whether a path exists (its metadata) stays visible, since tools look up paths all
///   the time. Profiles start from `(allow default)` and deny on top; later rules override
///   earlier ones.
/// - **Docker**: a Linux container that sees only the project folder (and chosen mounts).
///
/// A port of v1's `bridge-sandbox`, producing the same policy text.
public enum Sandbox {
    /// What the policy needs to know besides the profile.
    public struct Context: Sendable {
        /// The project folder: writable.
        public var root: URL
        /// More writable paths (the session's own history file).
        public var extraWritable: [URL] = []
        /// More readable paths (libghostty's resources, the app's helper).
        public var extraReadable: [URL] = []
        public var home: URL
        public var path: String?
        public var tmpdir: String?

        public init(root: URL, extraWritable: [URL] = [], extraReadable: [URL] = [],
                    home: URL = URL(fileURLWithPath: Paths.home),
                    path: String? = ProcessInfo.processInfo.environment["PATH"],
                    tmpdir: String? = ProcessInfo.processInfo.environment["TMPDIR"]) {
            self.root = root
            self.extraWritable = extraWritable
            self.extraReadable = extraReadable
            self.home = home
            self.path = path
            self.tmpdir = tmpdir
        }
    }

    /// Files in the app's folder that no sandbox may read or change: the SSH hosts and vault
    /// account, every command typed, project paths, and the app's settings.
    static let appPrivate = ["profiles.json", "history.jsonl", "projects.json", "settings.json"]

    /// System locations programs need to read: binaries, libraries, frameworks, Homebrew,
    /// settings like the time zone and DNS resolver, and the shell links in `/var/select`.
    static let systemReadable = [
        "/usr", "/bin", "/sbin", "/System", "/Library", "/opt", "/Applications", "/dev",
        "/private/etc", "/private/var/db", "/private/var/run", "/private/var/select",
    ]

    /// Config files tools look for in the folders above a project (version pins, workspace
    /// roots); only these, not the folders' other contents, are readable there.
    static let ancestorConfig = [
        "package.json", "package-lock.json", "pnpm-workspace.yaml", ".node-version", ".nvmrc", ".tool-versions",
        ".python-version", ".ruby-version", ".go-version", "rust-toolchain", "rust-toolchain.toml", ".editorconfig",
        ".gitignore", ".git", "tsconfig.json", "deno.json", "bunfig.toml", "nx.json", "turbo.json", "lerna.json",
        ".prettierrc", ".prettierrc.json", ".eslintrc.json",
    ]

    /// The SBPL policy for a Seatbelt profile.
    public static func policy(_ s: SandboxEngine.Seatbelt, context: Context) -> String {
        let home = context.home.path
        func expand(_ path: String) -> String {
            path.hasPrefix("~") ? home + path.dropFirst() : path
        }

        var writable = [resolve(context.root.path), "/private/tmp", "/private/var/folders"]
        if let tmp = context.tmpdir { writable.append(resolve(tmp)) }
        writable += s.writable.map { resolve(expand($0.trimmingCharacters(in: .whitespaces))) }
        writable += context.extraWritable.map { resolve($0.path) }

        var hidden = s.hidden.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { resolve(expand($0.trimmingCharacters(in: .whitespaces))) }
        // The app's own records are never readable, whatever the profile says.
        let app = context.home.appendingPathComponent(".config/bridge").path
        hidden += appPrivate.map { resolve(app + "/" + $0) }

        var profile = "(version 1)\n(allow default)\n"
        if s.confineReads {
            // Contents only where allowed; metadata (does it exist, what is it) stays visible.
            profile += "(deny file-read-data)\n(allow file-read-data\n"
            profile += "  (literal \"/\") (literal \"/etc\") (literal \"/var\") (literal \"/tmp\") (literal \"/private\")\n"
            for path in systemReadable {
                profile += "  (subpath \"\(path)\")\n"
            }
            let listed = s.readable.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { resolve(expand($0.trimmingCharacters(in: .whitespaces))) }
            let detected = shellSetupPaths(home: home, path: context.path).map(resolve)
            let extra = context.extraReadable.map { resolve($0.path) }
            for path in writable + listed + detected + extra {
                profile += pathRules(path)
            }
            let names = ancestorConfig.map(regexEscape).joined(separator: "|")
            var ancestor = (resolve(context.root.path) as NSString).deletingLastPathComponent
            while ancestor != "/" && !ancestor.isEmpty {
                profile += "  (regex #\"^\(regexEscape(ancestor))/(\(names))$\")\n"
                ancestor = (ancestor as NSString).deletingLastPathComponent
            }
            profile += ")\n"
        }
        profile += "(deny file-write*)\n(allow file-write*\n"
        for path in writable {
            profile += pathRules(path)
        }
        // The terminal itself and the usual device files.
        profile += "  (literal \"/dev/null\") (literal \"/dev/zero\") (literal \"/dev/tty\") (literal \"/dev/dtracehelper\")\n"
        profile += "  (regex #\"^/dev/ttys[0-9]+$\") (regex #\"^/dev/fd/\"))\n"
        if !hidden.isEmpty {
            // `file-read-data` by name: a deny on `file-read*` loses to the more specific
            // `allow file-read-data` above, whatever the order, which would leave a hidden path
            // inside a readable folder readable.
            profile += "(deny file-read* file-read-data file-write*\n"
            for path in hidden { profile += "  (subpath \(quote(path)))\n" }
            profile += ")\n"
        }
        switch s.network {
        case .all: break
        case .localhost:
            profile += "(deny network-outbound (remote ip))\n(allow network-outbound (remote ip \"localhost:*\"))\n"
        case .none:
            profile += "(deny network-outbound (remote ip))\n(deny network-bind (local ip))\n"
        }
        let blocked = s.blocked.flatMap { programPaths($0.trimmingCharacters(in: .whitespaces), home: home, path: context.path) }
        if !blocked.isEmpty {
            profile += "(deny process-exec\n"
            for path in blocked { profile += "  (literal \(quote(path)))\n" }
            profile += ")\n"
        }
        if s.blockKeychain {
            profile += "(deny mach-lookup (global-name \"com.apple.SecurityServer\") (global-name \"com.apple.securityd\"))\n"
        }
        // Other programs and services aren't sandboxed, so asking them is closed off too: no
        // scripting other apps, no Spotlight (it would list and search files anywhere), and local
        // sockets only in /tmp (local databases and Bridge's own), system ones in /var/run (DNS)
        // and the project, never the user's ssh-agent or a Docker daemon.
        profile += "(deny appleevent-send)\n"
        profile += "(deny mach-lookup (global-name-regex #\"^com\\.apple\\.metadata\\.mds\"))\n"
        profile += "(deny network-outbound (remote unix-socket))\n(allow network-outbound\n"
        profile += "  (remote unix-socket (path-regex #\"^/private/tmp/\"))\n"
        profile += "  (remote unix-socket (path-regex #\"^/private/var/run/\"))\n"
        profile += "  (remote unix-socket (path-regex #\"^\(regexEscape(resolve(context.root.path)))/\")))\n"
        profile += "(deny network-outbound\n"
        profile += "  (remote unix-socket (path-regex #\"^/private/tmp/com\\.apple\\.launchd\\.\"))\n"
        profile += "  (remote unix-socket (path-regex #\"docker\\.sock$\")))\n"
        if !s.allowClipboard {
            profile += "(deny mach-lookup (global-name \"com.apple.pasteboard.1\"))\n"
        }
        if !s.allowOpen {
            // LaunchServices: how `open` (and any app) starts apps and opens files and links.
            profile += "(deny mach-lookup (global-name-regex #\"^com\\.apple\\.lsd\\.\"))\n"
        }
        return profile
    }

    /// `docker run` arguments: the project mounted at /workspace, starting in `inside` (relative
    /// to it). `command` runs instead of a login shell (a task).
    public static func dockerArguments(_ d: SandboxEngine.Docker, pane: ID, root: URL, inside: String, command: String?,
                                       home: String = Paths.home) -> [String] {
        var args = ["run", "--rm", "-it", "--init", "--name", containerName(pane), "--hostname", "sandbox"]
        let workdir = inside.isEmpty || inside == "." ? "/workspace" : "/workspace/\(inside)"
        args += ["-v", "\(root.path):/workspace", "-w", workdir]
        if !d.network { args += ["--network", "none"] }
        for mount in d.mounts.map({ $0.trimmingCharacters(in: .whitespaces) }) where !mount.isEmpty {
            if let colon = mount.firstIndex(of: ":") {
                let host = String(mount[..<colon])
                let expanded = host.hasPrefix("~") ? home + host.dropFirst() : host
                args += ["-v", expanded + mount[colon...]]
            } else {
                args += ["-v", mount]
            }
        }
        for name in d.env.map({ $0.trimmingCharacters(in: .whitespaces) }) where !name.isEmpty {
            args += ["-e", name]
        }
        let image = d.image.trimmingCharacters(in: .whitespaces)
        args.append(image.isEmpty ? "ubuntu:24.04" : image)
        if let command {
            args += ["/bin/sh", "-lc", command]
        } else {
            args += ["/bin/sh", "-c", "if command -v bash >/dev/null 2>&1; then exec bash -l; else exec sh -l; fi"]
        }
        return args
    }

    /// The container a Docker pane runs in.
    public static func containerName(_ pane: ID) -> String { "bridge-\(pane)" }

    // MARK: - Helpers

    /// The real path, so `/tmp` matches as `/private/tmp` and symlinked folders as their target.
    /// A path that doesn't exist yet keeps its resolved parent.
    static func resolve(_ path: String) -> String {
        if let real = realpath(path) { return real }
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        if !parent.isEmpty, !name.isEmpty, let real = realpath(parent) {
            return (real as NSString).appendingPathComponent(name)
        }
        return path
    }

    private static func realpath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Filters matching `path`: the folder and what is in it; or the file, with the lock,
    /// temporary and per-host files written beside it under its name plus a `.` or `-` suffix.
    static func pathRules(_ path: String) -> String {
        var rules = "  (subpath \(quote(path)))\n"
        var isDir: ObjCBool = false
        if !(FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue) {
            // An alternation, not `[.-]`: Seatbelt's regex engine misreads that bracket as a range.
            rules += "  (regex #\"^\(regexEscape(path))((\\.|-)[^/]*)?$\")\n"
        }
        return rules
    }

    /// Every path a blocked program could be run from: each match on PATH, and what it links to.
    static func programPaths(_ program: String, home: String, path: String?) -> [String] {
        guard !program.isEmpty else { return [] }
        let candidates: [String]
        if program.contains("/") {
            candidates = [program.hasPrefix("~") ? home + program.dropFirst() : program]
        } else {
            candidates = (path ?? "").split(separator: ":").map { "\($0)/\(program)" }
                .filter { FileManager.default.isExecutableFile(atPath: $0) }
        }
        var paths: [String] = []
        for candidate in candidates {
            for path in [candidate, resolve(candidate)] where !paths.contains(path) {
                paths.append(path)
            }
        }
        return paths
    }

    /// What the user's shell setup needs to read in the home folder, found by reading it: the
    /// files the startup files source (two levels deep) and the home toolchains they and `path`
    /// put on PATH (`~/.bun/bin` stands for `~/.bun`).
    static func shellSetupPaths(home: String, path: String?) -> [String] {
        let startup = [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".bashrc", ".bash_profile", ".profile"]
        var found: [String] = []
        func add(_ path: String) {
            if path.hasPrefix(home + "/"), path != home, !found.contains(path) { found.append(path) }
        }
        var queue = startup.map { (home + "/" + $0, 0) }
        while let (file, depth) = queue.popLast() {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            for raw in text.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("#") else { continue }
                // `source FILE` / `. FILE`
                var sourced: Substring?
                if line.hasPrefix("source ") { sourced = line.dropFirst(7) }
                else if line.hasPrefix(". ") { sourced = line.dropFirst(2) }
                if let word = sourced?.split(separator: " ").first, let target = homePath(String(word), home: home) {
                    var isDir: ObjCBool = false
                    if depth < 2, FileManager.default.fileExists(atPath: target, isDirectory: &isDir), !isDir.boolValue {
                        queue.append((target, depth + 1))
                    }
                    // A tool's file comes with the tool's folder (`~/.config/vite-plus/env`).
                    let folder = (target as NSString).deletingLastPathComponent
                    if folder != home && folder != home + "/.config" { add(folder) }
                    add(target)
                }
                if line.contains("PATH") {
                    for entry in line.split(whereSeparator: { ":\"'= ()".contains($0) }) {
                        if let dir = homePath(String(entry), home: home) { add(toolRoot(dir, home: home)) }
                    }
                }
            }
        }
        for dir in (path ?? "").split(separator: ":").map(String.init) where dir.hasPrefix(home + "/") {
            add(toolRoot(dir, home: home))
        }
        // A tool found under one standard folder keeps its state under the others too.
        let xdg = [".config", ".local/share", ".local/state", ".cache"]
        let tools = found.compactMap { path -> String? in
            let relative = String(path.dropFirst(home.count + 1))
            let parent = (relative as NSString).deletingLastPathComponent
            return xdg.contains(parent) ? (relative as NSString).lastPathComponent : nil
        }
        for tool in tools {
            for base in xdg {
                let dir = "\(home)/\(base)/\(tool)"
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue { add(dir) }
            }
        }
        return found
    }

    /// A word of a shell file as a path in the home folder (`~/x`, `$HOME/x`, `${HOME}/x`, absolute).
    static func homePath(_ word: String, home: String) -> String? {
        let word = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"';"))
        var path: String
        if word.hasPrefix("~/") { path = home + "/" + word.dropFirst(2) }
        else if word.hasPrefix("$HOME/") { path = home + "/" + word.dropFirst(6) }
        else if word.hasPrefix("${HOME}/") { path = home + "/" + word.dropFirst(8) }
        else if word.hasPrefix("/"), !word.contains("$") { path = word }
        else { return nil }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path.hasPrefix(home + "/") ? path : nil
    }

    /// The folder a toolchain lives in, from a `bin` folder on PATH; `~/.local/bin` stays itself.
    static func toolRoot(_ dir: String, home: String) -> String {
        let name = (dir as NSString).lastPathComponent
        let parent = (dir as NSString).deletingLastPathComponent
        if (name == "bin" || name.hasSuffix("-bin")) && parent != home && parent != home + "/.local" {
            return parent
        }
        return dir
    }

    /// A path as the start of an SBPL regex, its metacharacters escaped.
    static func regexEscape(_ path: String) -> String {
        var out = ""
        for ch in path {
            if #".^$|()[]{}*+?\""#.contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// A path as an SBPL string literal.
    static func quote(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
