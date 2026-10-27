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
        /// More writable paths: the session's own history file, temporary folder and caches.
        public var extraWritable: [URL] = []
        /// More readable paths (libghostty's resources, the app's helper, the shell scripts).
        public var extraReadable: [URL] = []
        public var home: URL
        public var path: String?
        /// The app's shell socket: the one socket outside the project and `/tmp` the sandbox may
        /// connect to.
        public var appSocket: String?
        /// The user's cache folder in `/var/folders`, writable for compilers' module caches.
        public var userCache: String?
        /// The user's temporary folder (not writable; its `xcrun_db` is readable).
        public var temporary: String?
        /// Added to every logged denial (`bridge-pane-<id>`).
        public var marker: String?
        /// The session's own terminal device (or `ttyPlaceholder`, filled in by `bridge-helper
        /// sandbox` once the terminal exists): the only tty it may read or write by name.
        public var tty: String?

        public init(root: URL, extraWritable: [URL] = [], extraReadable: [URL] = [],
                    home: URL = URL(fileURLWithPath: Paths.home),
                    path: String? = ProcessInfo.processInfo.environment["PATH"],
                    appSocket: String? = nil, userCache: String? = Paths.userCacheDirectory,
                    temporary: String? = Paths.temporaryDirectory.path, marker: String? = nil, tty: String? = nil) {
            self.root = root
            self.extraWritable = extraWritable
            self.extraReadable = extraReadable
            self.home = home
            self.path = path
            self.appSocket = appSocket
            self.userCache = userCache
            self.temporary = temporary
            self.marker = marker
            self.tty = tty
        }
    }

    /// Never readable or writable, whatever the profile says: the app's own records (SSH hosts,
    /// the vault account, every command typed, project paths, settings), other projects'
    /// sandbox caches, shell histories, and where tools keep credentials.
    public static func alwaysHidden(home: String) -> [String] {
        [
            Paths.dataDirectory.path, home + "/.config/bridge", Paths.sandboxStateRoot.path,
            home + "/.zsh_history", home + "/.bash_history", home + "/.local/share/fish/fish_history",
            home + "/.ssh", home + "/.aws", home + "/.gnupg", home + "/.netrc", home + "/.git-credentials",
            home + "/.config/gh", home + "/.docker/config.json", home + "/.kube",
            home + "/.cargo/credentials", home + "/.cargo/credentials.toml",
        ]
    }

    /// Never writable, whatever the profile says: what shells and other programs outside the
    /// sandbox run or load later. Writing there would let a sandboxed program run code outside
    /// it (a line in `~/.zshrc`, a binary first on PATH, a LaunchAgent, an agent's hook).
    public static func neverWritable(home: String) -> [String] {
        [
            ".zshenv", ".zprofile", ".zshrc", ".zlogin", ".zlogout", ".zsh", ".oh-my-zsh", ".bashrc",
            ".bash_profile", ".bash_login", ".profile", ".inputrc", ".config/fish", ".config/zsh",
            ".config/starship.toml", ".gitconfig", ".config/git", ".npmrc", ".yarnrc", ".yarnrc.yml",
            "Library/LaunchAgents", ".local/bin", "bin", ".cargo/bin", ".cargo/env", ".cargo/config",
            ".cargo/config.toml", ".claude/settings.json", ".claude/settings.local.json", ".claude/hooks",
            ".claude/commands", ".claude/agents", ".claude/plugins", ".claude/skills", ".claude/CLAUDE.md",
            ".codex/config.toml", ".codex/AGENTS.md", ".gemini/settings.json", ".vimrc", ".config/nvim",
            ".tmux.conf", ".config/tmux", ".config/direnv",
        ].map { home + "/" + $0 }
    }

    /// Folders in `/tmp` other programs keep their control sockets in (launchd's ssh-agent, tmux,
    /// X11): not writable, so their sockets can't be moved, and not connectable.
    static let protectedTemporary = #"^/private/tmp/(com\.apple\.launchd\.|tmux-|\.X11-unix|uscreens|screens)"#

    /// Where the git repository of a worktree folder lives when it isn't inside it (`git worktree
    /// add`): its `.git` file points at `<repo>/.git/worktrees/<name>`, and git also needs the
    /// repository's shared objects and refs. Readable and writable, like the project's own `.git`.
    static func gitDirectories(of root: URL) -> [String] {
        let dotGit = root.appendingPathComponent(".git")
        guard let text = try? String(contentsOf: dotGit, encoding: .utf8), text.hasPrefix("gitdir: ") else { return [] }
        let target = text.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespacesAndNewlines)
        let gitDir = target.hasPrefix("/") ? URL(fileURLWithPath: target) : root.appendingPathComponent(target)
        var dirs = [resolve(gitDir.standardizedFileURL.path)]
        let common = (try? String(contentsOf: gitDir.appendingPathComponent("commondir"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let common, !common.isEmpty {
            let url = common.hasPrefix("/") ? URL(fileURLWithPath: common) : gitDir.appendingPathComponent(common)
            dirs.append(resolve(url.standardizedFileURL.path))
        }
        return dirs
    }

    /// The parts of the project's git repository that make git run programs, or point it at
    /// another repository that would: hooks, configs (an fsmonitor, a pager, aliases, filters),
    /// and the links between a worktree and its repository. Never writable, since git outside
    /// the sandbox would follow them.
    static func gitControl(of root: URL) -> [String] {
        let dotGit = resolve(root.appendingPathComponent(".git").path)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir)
        // A worktree's `.git` is a file naming its repository.
        var paths = exists && !isDir.boolValue ? [dotGit] : []
        let dirs = (exists && isDir.boolValue ? [dotGit] : []) + gitDirectories(of: root)
        for dir in dirs {
            paths += ["hooks", "config", "config.worktree", "commondir", "gitdir"].map { dir + "/" + $0 }
        }
        return paths
    }

    /// Other worktrees' links to their repository, inside a git folder: never writable either.
    static func gitWorktreeLinks(of root: URL) -> [String] {
        let dotGit = resolve(root.appendingPathComponent(".git").path)
        return ([dotGit] + gitDirectories(of: root)).map {
            "^\(regexEscape($0))/worktrees/[^/]+/(commondir|gitdir|config\\.worktree)$"
        }
    }

    /// Stands for the session's terminal device in a policy, until `bridge-helper sandbox` puts
    /// the real one in (the terminal doesn't exist yet when the policy is made).
    public static let ttyPlaceholder = "@BRIDGE_TTY@"

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
    ///
    /// Rules later in the policy win over earlier ones, so it is built in layers: what may be read
    /// and written; then what is hidden and what is never writable, whatever came before; then the
    /// few paths inside hidden folders the session needs back (its own history file, the shell
    /// scripts); then services and sockets.
    public static func policy(_ s: SandboxEngine.Seatbelt, context: Context) -> String {
        let home = context.home.path
        func expand(_ path: String) -> String {
            path.hasPrefix("~") ? home + path.dropFirst() : path
        }
        func clean(_ paths: [String]) -> [String] {
            paths.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { resolve(expand($0)) }
        }

        // Temporary files go in /tmp and the session's own folders; the rest of /var/folders (other
        // programs' temporary files and sockets, the app's own) stays out of reach.
        var writable = [resolve(context.root.path), "/private/tmp"]
        if let cache = context.userCache { writable.append(resolve(cache)) }
        writable += clean(s.writable) + gitDirectories(of: context.root)
        let own = context.extraWritable.map { resolve($0.path) }
        writable += own

        let hidden = clean(s.hidden) + alwaysHidden(home: home).map(resolve)

        // Denials are logged with the session's marker, so the app can tell which terminal a
        // refusal came from and show it there.
        let tag = context.marker.map { " (with message \(quote($0)))" } ?? ""
        var profile = "(version 1)\n(allow default)\n"
        if s.confineReads {
            // Contents only where allowed; metadata (does it exist, what is it) stays visible.
            profile += "(deny file-read-data\(tag))\n(allow file-read-data\n"
            profile += "  (literal \"/\") (literal \"/etc\") (literal \"/var\") (literal \"/tmp\") (literal \"/private\")\n"
            for path in systemReadable {
                profile += "  (subpath \"\(path)\")\n"
            }
            let detected = shellSetupPaths(home: home, path: context.path).map(resolve)
            let extra = context.extraReadable.map { resolve($0.path) }
            for path in writable + clean(s.readable) + detected + extra {
                profile += pathRules(path)
            }
            // The lookup cache of Apple's command-line tool shims (`/usr/bin/git` and friends):
            // readable, so they find their tools, but never writable (a changed cache would point
            // `git` outside the sandbox elsewhere).
            if let temporary = context.temporary {
                profile += "  (literal \(quote(resolve(temporary) + "/xcrun_db")))\n"
            }
            let names = ancestorConfig.map(regexEscape).joined(separator: "|")
            var ancestor = (resolve(context.root.path) as NSString).deletingLastPathComponent
            while ancestor != "/" && !ancestor.isEmpty {
                profile += "  (regex #\"^\(regexEscape(ancestor))/(\(names))$\")\n"
                ancestor = (ancestor as NSString).deletingLastPathComponent
            }
            profile += ")\n"
        }
        profile += "(deny file-write*\(tag))\n(allow file-write*\n"
        for path in writable {
            profile += pathRules(path)
        }
        // The terminal itself (already open; `/dev/tty` reaches it by name) and the usual device
        // files. Other terminals' ttys are not writable: that would type into them.
        profile += "  (literal \"/dev/null\") (literal \"/dev/zero\") (literal \"/dev/tty\") (literal \"/dev/dtracehelper\")\n"
        if let tty = context.tty { profile += "  (literal \(quote(tty)))\n" }
        profile += "  (regex #\"^/dev/fd/\"))\n"

        // `file-read-data` by name: a deny on `file-read*` loses to the more specific
        // `allow file-read-data` above, whatever the order, which would leave a hidden path
        // inside a readable folder readable.
        profile += "(deny file-read* file-read-data file-write*\n"
        for path in hidden { profile += "  (subpath \(quote(path)))\n" }
        profile += "\(tag))\n"
        profile += "(deny file-write*\n"
        for path in neverWritable(home: home).map(resolve) + gitControl(of: context.root) { profile += pathRules(path) }
        profile += "  (regex #\"^\(regexEscape(resolve(home)))/\\.zcompdump\")\n"
        for pattern in gitWorktreeLinks(of: context.root) { profile += "  (regex #\"\(pattern)\")\n" }
        profile += "  (regex #\"\(protectedTemporary)\")\(tag))\n"
        // Other terminals' devices: reading one would take its keystrokes, writing would type into
        // its screen. Only the session's own.
        if let tty = context.tty {
            profile += "(deny file-read-data file-write* (regex #\"^/dev/ttys[0-9]+$\")\(tag))\n"
            profile += "(allow file-read-data file-write* (literal \(quote(tty))))\n"
        }
        // Back inside the hidden folders: the session's own files, and the scripts its shell loads.
        let reread = context.extraReadable.map { resolve($0.path) }
        if !reread.isEmpty {
            profile += "(allow file-read* file-read-data\n"
            for path in reread { profile += pathRules(path) }
            profile += ")\n"
        }
        if !own.isEmpty {
            profile += "(allow file-read* file-read-data file-write*\n"
            for path in own { profile += pathRules(path) }
            profile += ")\n"
        }

        switch s.network {
        case .all: break
        case .localhost:
            profile += "(deny network-outbound (remote ip)\(tag))\n(allow network-outbound (remote ip \"localhost:*\"))\n"
        case .none:
            profile += "(deny network-outbound (remote ip)\(tag))\n(deny network-bind (local ip)\(tag))\n"
        }
        let blocked = s.blocked.flatMap { programPaths($0.trimmingCharacters(in: .whitespaces), home: home, path: context.path) }
        if !blocked.isEmpty {
            profile += "(deny process-exec\n"
            for path in blocked { profile += "  (literal \(quote(path)))\n" }
            profile += "\(tag))\n"
        }
        if s.blockKeychain {
            profile += "(deny mach-lookup (global-name \"com.apple.SecurityServer\") (global-name \"com.apple.securityd\")\(tag))\n"
        }
        // Other programs and services aren't sandboxed, so asking them is closed off too: no
        // scripting other apps, no Spotlight (it would list and search files anywhere), and local
        // sockets only in the project, the session's own folders, /tmp (local databases) and
        // /var/run (DNS), never the user's ssh-agent, tmux, a Docker daemon or the vault's agent.
        // The app's own socket is reachable by its exact path only; its folder isn't writable, so
        // it can't be swapped for another.
        profile += "(deny appleevent-send\(tag))\n"
        profile += "(deny mach-lookup (global-name-regex #\"^com\\.apple\\.metadata\\.mds\")\(tag))\n"
        profile += "(deny network-outbound (remote unix-socket)\(tag))\n(allow network-outbound\n"
        profile += "  (remote unix-socket (path-regex #\"^/private/tmp/\"))\n"
        profile += "  (remote unix-socket (path-regex #\"^/private/var/run/\"))\n"
        for path in [resolve(context.root.path)] + own {
            profile += "  (remote unix-socket (subpath \(quote(path))))\n"
        }
        if let socket = context.appSocket {
            profile += "  (remote unix-socket (literal \(quote(resolve(socket)))))\n"
        }
        profile += ")\n(deny network-outbound\n"
        profile += "  (remote unix-socket (path-regex #\"\(protectedTemporary)\"))\n"
        profile += "  (remote unix-socket (path-regex #\"^/private/var/run/com\\.apple\\.launchd\\.\"))\n"
        profile += "  (remote unix-socket (path-regex #\"docker\\.sock$\"))\(tag))\n"
        if !s.allowClipboard {
            profile += "(deny mach-lookup (global-name \"com.apple.pasteboard.1\")\(tag))\n"
        }
        if !s.allowOpen {
            // LaunchServices: how `open` (and any app) starts apps and opens files and links.
            profile += "(deny mach-lookup (global-name-regex #\"^com\\.apple\\.lsd\\.\")\(tag))\n"
        }
        return profile
    }

    /// `docker run` arguments: the project mounted at /workspace, starting in `inside` (relative
    /// to it). `command` runs instead of a login shell (a task).
    public static func dockerArguments(_ d: SandboxEngine.Docker, pane: ID, root: URL, inside: String, command: String?,
                                       home: String = Paths.home) -> [String] {
        // Labelled, so containers a crash left behind can be found and removed; no gaining
        // privileges inside (setuid programs).
        var args = ["run", "--rm", "-it", "--init", "--name", containerName(pane), "--hostname", "sandbox",
                    "--label", containerLabel, "--security-opt", "no-new-privileges"]
        let workdir = inside.isEmpty || inside == "." ? "/workspace" : "/workspace/\(inside)"
        // `--mount` rather than `-v`, so a folder with a `:` or `,` in its name can't add options.
        args += ["--mount", mountSpec(source: root.path, target: "/workspace", readOnly: false), "-w", workdir]
        if !d.network { args += ["--network", "none"] }
        for mount in d.mounts.map({ $0.trimmingCharacters(in: .whitespaces) }) where !mount.isEmpty {
            // `host:container[:ro]`.
            var parts = mount.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            let readOnly = parts.count > 2 && parts.last == "ro"
            if readOnly { parts.removeLast() }
            guard parts.count == 2, !parts[0].isEmpty, parts[1].hasPrefix("/") else { continue }
            let host = parts[0].hasPrefix("~") ? home + parts[0].dropFirst() : parts[0]
            args += ["--mount", mountSpec(source: host, target: parts[1], readOnly: readOnly)]
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

    /// The label on every container Bridge starts.
    public static let containerLabel = "dev.bridge.sandbox=1"

    /// A bind mount for `--mount`, its fields quoted the way Docker reads them (CSV).
    static func mountSpec(source: String, target: String, readOnly: Bool) -> String {
        func field(_ key: String, _ value: String) -> String {
            let pair = "\(key)=\(value)"
            return value.contains(where: { ",\"".contains($0) }) ? "\"" + pair.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : pair
        }
        return "type=bind," + field("source", source) + "," + field("target", target) + (readOnly ? ",readonly" : "")
    }

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
