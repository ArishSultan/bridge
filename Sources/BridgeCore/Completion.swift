import Foundation

/// Completing the word before the cursor: commands, subcommands, git branches and remotes,
/// package scripts, make targets, files and folders, and arguments learned from history. A
/// port of v1's completion engine, with the same sources and ranking.
public enum Completion {
    static let maxCandidates = 50

    public enum Kind: Int, Sendable, Hashable {
        case command, subcommand, branch, script, directory, file, argument

        /// Tie-breaker between kinds with equal match scores.
        var priority: Int {
            switch self {
            case .subcommand, .script, .branch: 30
            case .directory: 20
            case .file: 15
            case .argument: 10
            case .command: 5
            }
        }
    }

    public struct Candidate: Equatable, Sendable, Identifiable {
        /// Text that replaces the word being completed (already shell-escaped).
        public var replacement: String
        /// Text shown in the menu.
        public var display: String
        public var description: String?
        public var kind: Kind
        /// Matched character offsets in `display`.
        public var positions: [Int] = []

        public var id: String { "\(kind.rawValue):\(display)" }

        /// What to type after the replacement: folders keep completing, the rest ends the word.
        public var suffix: String { kind == .directory ? "" : " " }
    }

    /// The partial word being replaced (as typed), and the candidates for it.
    public struct Result: Equatable, Sendable {
        public var word: String
        public var candidates: [Candidate]

        public init(word: String, candidates: [Candidate]) {
            self.word = word
            self.candidates = candidates
        }
    }

    public struct Context {
        /// The command line up to the cursor.
        public var line: String
        public var cwd: URL
        public var executables: [String]
        public var history: History
        /// For a sandboxed terminal: the only folders whose contents may be listed. The app lists
        /// them outside the sandbox, so without this a completion would show what's in folders
        /// the sandbox hides (`~/.ssh/c` → `config`). nil: anywhere.
        public var readableRoots: [String]?

        public init(line: String, cwd: URL, executables: [String], history: History, readableRoots: [String]? = nil) {
            self.line = line
            self.cwd = cwd
            self.executables = executables
            self.history = history
            self.readableRoots = readableRoots
        }
    }

    /// Whether `path` is inside one of `roots` (after resolving links and `..`).
    static func isReadable(_ path: String, roots: [String]?) -> Bool {
        guard let roots else { return true }
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        return roots.contains { root in
            let root = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
            return real == root || real.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }

    /// Words that run the command after them.
    static let prefixCommands: Set<String> = ["sudo", "time", "nohup", "exec", "command", "builtin"]

    public static func complete(_ context: Context) -> Result {
        // A folder outside what the terminal may read gives nothing from its contents.
        guard isReadable(context.cwd.path, roots: context.readableRoots) else {
            var context = context
            context.cwd = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
            return complete(context)
        }
        let (words, word) = splitWords(context.line)
        var raw: [Candidate] = []
        let commandIndex = words.firstIndex { !prefixCommands.contains($0) } ?? words.count
        let args = Array(words[min(commandIndex, words.count)...])

        if args.isEmpty {
            raw += isPathLike(word) ? paths(context.cwd, word, directoriesOnly: false, roots: context.readableRoots) : commands(context)
        } else {
            let command = args[0]
            let position = args.count
            if isPathLike(word) {
                raw += paths(context.cwd, word, directoriesOnly: command == "cd" || command == "pushd", roots: context.readableRoots)
            } else {
                let sub = args.count > 1 ? args[1] : nil
                switch (command, sub) {
                case ("cd", _), ("pushd", _), ("rmdir", _):
                    raw += paths(context.cwd, word, directoriesOnly: true, roots: context.readableRoots)
                case ("git", nil):
                    raw += spec(git)
                case ("git", let sub?) where ["checkout", "switch", "merge", "rebase", "branch", "cherry-pick", "log", "diff"].contains(sub) && position == 2:
                    raw += gitBranches(context.cwd)
                    if ["checkout", "diff", "log"].contains(sub) { raw += paths(context.cwd, word, directoriesOnly: false, roots: context.readableRoots) }
                case ("git", let sub?) where ["push", "pull", "fetch"].contains(sub) && position == 2:
                    raw += gitRemotes(context.cwd)
                case ("git", let sub?) where ["push", "pull"].contains(sub) && position == 3:
                    raw += gitBranches(context.cwd)
                case ("cargo", nil):
                    raw += spec(cargo)
                case (let tool, nil) where ["npm", "pnpm", "yarn", "bun"].contains(tool):
                    raw += spec(npm)
                    if tool != "npm" { raw += packageScripts(context.cwd) }
                case (let tool, let sub?) where ["npm", "pnpm", "yarn", "bun"].contains(tool) && ["run", "run-script"].contains(sub) && position == 2:
                    raw += packageScripts(context.cwd)
                case ("docker", nil):
                    raw += spec(docker)
                case ("brew", nil):
                    raw += spec(brew)
                case ("make", _):
                    raw += makeTargets(context.cwd)
                default:
                    break
                }
                if raw.isEmpty || word.hasPrefix("-") {
                    raw += historyArguments(context.history, args: args, word: word)
                }
                if raw.isEmpty {
                    raw += paths(context.cwd, word, directoriesOnly: false, roots: context.readableRoots)
                }
            }
        }
        return Result(word: word, candidates: rank(raw, word: word))
    }

    /// Whether a command from history still makes sense in `cwd`, so it may be suggested there:
    /// a `cd` must lead to a folder that exists, and arguments written as explicit paths must
    /// exist. Arguments with variables or globs aren't checked.
    public static func valid(_ command: String, in cwd: URL, home: String = Paths.home) -> Bool {
        func resolve(_ arg: String) -> String {
            if arg.hasPrefix("~") { return home + "/" + arg.dropFirst().drop { $0 == "/" } }
            if arg.hasPrefix("/") { return arg }
            return cwd.appendingPathComponent(arg).path
        }
        let checkable = { (arg: String) in !arg.contains(where: { "$*?`".contains($0) }) }
        return segments(command).allSatisfy { words in
            guard let index = words.firstIndex(where: { !prefixCommands.contains($0) }) else { return true }
            let command = words[index]
            let args = words[(index + 1)...]
            var isDir: ObjCBool = false
            if command == "cd" || command == "pushd" {
                guard let dir = args.first(where: { !$0.hasPrefix("-") }), checkable(dir) else { return true }
                return FileManager.default.fileExists(atPath: resolve(dir), isDirectory: &isDir) && isDir.boolValue
            }
            return args.filter(checkable)
                .filter { arg in ["./", "../", "~/", "/"].contains { arg.hasPrefix($0) } }
                .allSatisfy { FileManager.default.fileExists(atPath: resolve($0)) }
        }
    }

    /// Whether the menu should open as soon as a space follows `line`: right after a command
    /// whose next word comes from a known list.
    public static func opensAfterSpace(_ line: String) -> Bool {
        let (words, word) = splitWords(line)
        let rest = Array(words.drop { prefixCommands.contains($0) })
        guard word.isEmpty else { return false }
        switch rest.count {
        case 1:
            return ["cd", "pushd", "rmdir", "git", "cargo", "npm", "pnpm", "yarn", "bun", "docker", "brew", "make"].contains(rest[0])
        case 2:
            if rest[0] == "git" {
                return ["checkout", "switch", "merge", "rebase", "cherry-pick", "push", "pull", "fetch"].contains(rest[1])
            }
            return ["npm", "pnpm", "yarn", "bun"].contains(rest[0]) && ["run", "run-script"].contains(rest[1])
        default:
            return false
        }
    }

    /// The words of each command in a full command line, split at pipes and separators.
    static func segments(_ line: String) -> [[String]] {
        var out: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for ch in line {
            if escaped {
                escaped = false
                current.append(ch)
                continue
            }
            switch (quote, ch) {
            case (let q, "\\") where q != "'":
                escaped = true
                current.append(ch)
            case (let open?, let ch) where ch == open:
                quote = nil
                current.append(ch)
            case (.some, _):
                current.append(ch)
            case (nil, "'"), (nil, "\""):
                quote = ch
                current.append(ch)
            case (nil, "|"), (nil, ";"), (nil, "&"), (nil, "("), (nil, ")"):
                out.append(current)
                current = ""
            default:
                current.append(ch)
            }
        }
        out.append(current)
        return out.map { segment in
            var (words, last) = splitWords(segment)
            if !last.isEmpty { words.append(unescape(last)) }
            return words
        }.filter { !$0.isEmpty }
    }

    /// Split a command line into finished words of the current pipeline segment and the
    /// partial word at the end (empty after a space). Quotes and backslashes are understood.
    static func splitWords(_ line: String) -> (words: [String], word: String) {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for ch in line {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }
            switch (quote, ch) {
            case (let q, "\\") where q != "'":
                escaped = true
                current.append(ch)
            case (let open?, let ch) where ch == open:
                quote = nil
                current.append(ch)
            case (.some, _):
                current.append(ch)
            case (nil, "'"), (nil, "\""):
                quote = ch
                current.append(ch)
            case (nil, " "), (nil, "\t"):
                if !current.isEmpty {
                    words.append(current)
                    current = ""
                }
            case (nil, "|"), (nil, ";"), (nil, "&"), (nil, "("), (nil, ")"):
                // A new command starts after a pipe or separator.
                words.removeAll()
                current = ""
            default:
                current.append(ch)
            }
        }
        return (words.map(unescape), current)
    }

    static func unescape(_ word: String) -> String {
        var out = ""
        var iterator = word.makeIterator()
        while let ch = iterator.next() {
            switch ch {
            case "\\": if let next = iterator.next() { out.append(next) }
            case "'", "\"": break
            default: out.append(ch)
            }
        }
        return out
    }

    /// Escape a file name for the shell.
    static func escape(_ text: String) -> String {
        let special: Set<Character> = [" ", "\t", "'", "\"", "\\", "$", "`", "!", "&", ";", "|", "(", ")", "<", ">", "*", "?", "[", "]", "#", "{", "}"]
        var out = ""
        for ch in text {
            if special.contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    static func isPathLike(_ word: String) -> Bool {
        word.contains("/") || word.hasPrefix(".") || word.hasPrefix("~")
    }

    static func candidate(_ kind: Kind, _ text: String, _ description: String? = nil) -> Candidate {
        Candidate(replacement: escape(text), display: text, description: description, kind: kind)
    }

    /// Fuzzy-filter by the partial word, then order by score, kind and name.
    static func rank(_ candidates: [Candidate], word: String) -> [Candidate] {
        // For paths, match only the last component.
        let query = unescape(word).split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        var seen = Set<String>()
        var scored: [(Int, Candidate)] = []
        for var candidate in candidates where seen.insert(candidate.id).inserted {
            var nameStart = 0
            if candidate.kind == .directory || candidate.kind == .file {
                var trimmed = candidate.display
                while trimmed.hasSuffix("/") { trimmed.removeLast() }
                if let slash = trimmed.lastIndex(of: "/") {
                    nameStart = trimmed.distance(from: trimmed.startIndex, to: slash) + 1
                }
            }
            let name = String(candidate.display.dropFirst(nameStart))
            guard let found = Fuzzy.match(query, name) else { continue }
            candidate.positions = found.positions.map { $0 + nameStart }
            scored.append((found.score * 10 + candidate.kind.priority, candidate))
        }
        scored.sort { a, b in
            if a.0 != b.0 { return a.0 > b.0 }
            if a.1.display.count != b.1.display.count { return a.1.display.count < b.1.display.count }
            return a.1.display < b.1.display
        }
        return scored.prefix(maxCandidates).map(\.1)
    }

    static func commands(_ context: Context) -> [Candidate] {
        var frequency: [String: Int] = [:]
        for entry in context.history.entries.reversed().prefix(5000) {
            if let first = entry.command.split(whereSeparator: \.isWhitespace).first {
                frequency[String(first), default: 0] += 1
            }
        }
        var out = builtins.map { candidate(.command, $0.0, $0.1) }
        out += frequency.sorted { $0.value > $1.value }.prefix(200).map { candidate(.command, $0.key, usedLabel($0.value)) }
        out += context.executables.map { candidate(.command, $0) }
        return out
    }

    /// Executable names on `PATH` (no duplicates, sorted).
    public static func executables(path: String) -> [String] {
        var names = Set<String>()
        for dir in path.split(separator: ":") {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: String(dir))) ?? [] where !name.hasPrefix(".") {
                names.insert(name)
            }
        }
        return names.sorted()
    }

    static func paths(_ cwd: URL, _ word: String, directoriesOnly: Bool, roots: [String]? = nil,
                      home: String = Paths.home) -> [Candidate] {
        let typed = unescape(word)
        let dirPart: String
        let namePart: String
        if let slash = typed.lastIndex(of: "/") {
            dirPart = String(typed[...slash])
            namePart = String(typed[typed.index(after: slash)...])
        } else {
            dirPart = ""
            namePart = typed
        }
        let base: String
        if dirPart.hasPrefix("~") {
            base = home + "/" + dirPart.dropFirst().drop { $0 == "/" }
        } else if dirPart.hasPrefix("/") {
            base = dirPart
        } else {
            base = cwd.appendingPathComponent(dirPart).path
        }
        guard isReadable(base, roots: roots),
              let entries = try? FileManager.default.contentsOfDirectory(atPath: base) else { return [] }
        let showHidden = namePart.hasPrefix(".")
        var out: [Candidate] = []
        for name in entries.prefix(2000) where showHidden || !name.hasPrefix(".") {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: (base as NSString).appendingPathComponent(name), isDirectory: &isDir)
            if directoriesOnly && !isDir.boolValue { continue }
            let display = dirPart + name + (isDir.boolValue ? "/" : "")
            // Keep `~` unescaped so the shell still expands it.
            let replacement = display.hasPrefix("~") ? "~" + escape(String(display.dropFirst())) : escape(display)
            out.append(Candidate(replacement: replacement, display: display, kind: isDir.boolValue ? .directory : .file))
        }
        return out
    }

    /// Arguments that followed the same words in past commands (flags, host names).
    static func historyArguments(_ history: History, args: [String], word: String) -> [Candidate] {
        var counts: [String: Int] = [:]
        for index in history.recentUnique.prefix(5000) {
            var (words, last) = splitWords(history.entries[index].command)
            if !last.isEmpty { words.append(unescape(last)) }
            guard words.count > args.count, Array(words[..<args.count]) == args else { continue }
            let next = words[args.count]
            if word.hasPrefix("-") == next.hasPrefix("-") { counts[next, default: 0] += 1 }
        }
        return counts.map { candidate(.argument, $0.key, usedLabel($0.value)) }
    }

    static func usedLabel(_ count: Int) -> String {
        count == 1 ? "used once" : "used \(count) times"
    }

    static func gitDirectory(_ cwd: URL) -> URL? {
        var dir = cwd.standardizedFileURL
        while true {
            let git = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: git.path, isDirectory: &isDir) {
                if isDir.boolValue { return git }
                guard let text = try? String(contentsOf: git, encoding: .utf8),
                      text.hasPrefix("gitdir: ")
                else { return nil }
                let target = String(text.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
                return target.hasPrefix("/") ? URL(fileURLWithPath: target) : dir.appendingPathComponent(target)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
    }

    static func gitBranches(_ cwd: URL) -> [Candidate] {
        guard let git = gitDirectory(cwd) else { return [] }
        // Worktrees keep refs in the common directory.
        let common = (try? String(contentsOf: git.appendingPathComponent("commondir"), encoding: .utf8))
            .map { git.appendingPathComponent($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? git
        var branches = Set<String>()
        collectRefs(common.appendingPathComponent("refs/heads"), prefix: "", into: &branches)
        if let packed = try? String(contentsOf: common.appendingPathComponent("packed-refs"), encoding: .utf8) {
            for line in packed.split(separator: "\n") {
                let parts = line.split(separator: " ")
                if parts.count > 1, parts[1].hasPrefix("refs/heads/") {
                    branches.insert(String(parts[1].dropFirst("refs/heads/".count)))
                }
            }
        }
        return branches.map { candidate(.branch, $0, "branch") }
    }

    static func collectRefs(_ dir: URL, prefix: String, into out: inout Set<String>) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
            let url = dir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                collectRefs(url, prefix: "\(prefix)\(name)/", into: &out)
            } else {
                out.insert(prefix + name)
            }
        }
    }

    static func gitRemotes(_ cwd: URL) -> [Candidate] {
        guard let config = gitDirectory(cwd).flatMap({ try? String(contentsOf: $0.appendingPathComponent("config"), encoding: .utf8) }) else {
            return []
        }
        return config.split(separator: "\n").compactMap { line -> Candidate? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("[remote \""), trimmed.hasSuffix("\"]") else { return nil }
            return candidate(.argument, String(trimmed.dropFirst(9).dropLast(2)), "remote")
        }
    }

    static func packageScripts(_ cwd: URL) -> [Candidate] {
        var dir = cwd.standardizedFileURL
        while true {
            let package = dir.appendingPathComponent("package.json")
            if FileManager.default.fileExists(atPath: package.path) {
                guard let data = try? Data(contentsOf: package),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let scripts = json["scripts"] as? [String: Any]
                else { return [] }
                return scripts.map { candidate(.script, $0.key, $0.value as? String) }
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return [] }
            dir = parent
        }
    }

    static func makeTargets(_ cwd: URL) -> [Candidate] {
        guard let text = ["Makefile", "makefile", "GNUmakefile"].lazy
            .compactMap({ try? String(contentsOf: cwd.appendingPathComponent($0), encoding: .utf8) }).first
        else { return [] }
        return text.split(separator: "\n").compactMap { line -> Candidate? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let target = line[..<colon]
            let rest = line[line.index(after: colon)...]
            guard !target.isEmpty, !rest.hasPrefix("="), !target.hasPrefix("."),
                  target.allSatisfy({ $0.isLetter || $0.isNumber || "_-./".contains($0) })
            else { return nil }
            return candidate(.script, String(target), "make target")
        }
    }

    static func spec(_ entries: [(String, String)]) -> [Candidate] {
        entries.map { candidate(.subcommand, $0.0, $0.1) }
    }

    static let builtins = [
        ("cd", "Change directory"), ("ls", "List directory contents"), ("echo", "Print text"),
        ("export", "Set an environment variable"), ("source", "Run a script in this shell"),
        ("alias", "Define a command alias"), ("history", "Show command history"), ("exit", "Exit the shell"),
        ("clear", "Clear the screen"), ("pwd", "Print the working directory"),
    ]

    static let git = [
        ("status", "Show the working tree status"), ("add", "Add file contents to the index"),
        ("commit", "Record changes to the repository"), ("push", "Update remote refs"),
        ("pull", "Fetch and integrate remote changes"), ("fetch", "Download objects and refs"),
        ("checkout", "Switch branches or restore files"), ("switch", "Switch branches"),
        ("branch", "List, create or delete branches"), ("merge", "Join two histories together"),
        ("rebase", "Reapply commits on top of another base"), ("log", "Show commit logs"), ("diff", "Show changes"),
        ("stash", "Stash away changes"), ("restore", "Restore working tree files"), ("reset", "Reset HEAD to a state"),
        ("clone", "Clone a repository"), ("init", "Create an empty repository"), ("remote", "Manage remotes"),
        ("tag", "Create, list or delete tags"), ("show", "Show objects"), ("cherry-pick", "Apply changes from commits"),
        ("revert", "Revert commits"), ("blame", "Show who changed each line"),
    ]

    static let cargo = [
        ("build", "Compile the package"), ("run", "Build and run a binary"), ("test", "Run tests"),
        ("check", "Check for errors without building"), ("clippy", "Run lints"), ("fmt", "Format the code"),
        ("add", "Add a dependency"), ("remove", "Remove a dependency"), ("new", "Create a new package"),
        ("init", "Create a package in this directory"), ("update", "Update dependencies"), ("doc", "Build documentation"),
        ("bench", "Run benchmarks"), ("install", "Install a binary"), ("clean", "Remove build artifacts"),
        ("publish", "Publish to crates.io"),
    ]

    static let npm = [
        ("install", "Install dependencies"), ("run", "Run a package script"), ("test", "Run tests"),
        ("start", "Run the start script"), ("build", "Run the build script"), ("add", "Add a dependency"),
        ("remove", "Remove a dependency"), ("update", "Update dependencies"), ("init", "Create a package.json"),
        ("publish", "Publish the package"), ("outdated", "Check for outdated packages"), ("audit", "Audit dependencies"),
    ]

    static let docker = [
        ("ps", "List containers"), ("run", "Run a container"), ("build", "Build an image"),
        ("exec", "Run a command in a container"), ("images", "List images"), ("pull", "Download an image"),
        ("push", "Upload an image"), ("logs", "Show container logs"), ("stop", "Stop containers"),
        ("start", "Start containers"), ("rm", "Remove containers"), ("rmi", "Remove images"),
        ("compose", "Multi-container apps"),
    ]

    static let brew = [
        ("install", "Install a formula or cask"), ("uninstall", "Uninstall a formula or cask"),
        ("upgrade", "Upgrade outdated packages"), ("update", "Update Homebrew"), ("search", "Search for packages"),
        ("info", "Show package information"), ("list", "List installed packages"),
        ("outdated", "List outdated packages"), ("services", "Manage background services"),
        ("cleanup", "Remove old versions"), ("doctor", "Check for problems"),
    ]

    /// The gray suggestion after what's typed: a history command extending the whole line
    /// (preferring ones run in this folder), else the rest of the best completion of the last
    /// word. Empty when there's nothing to add.
    public static func suggestion(line: String, cwd: URL, history: History, executables: [String],
                                  readableRoots: [String]? = nil) -> String {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        if let command = history.suggest(line, cwd: cwd.path, valid: { valid($0, in: cwd) }) {
            return String(command.dropFirst(line.count))
        }
        let result = complete(Context(line: line, cwd: cwd, executables: executables, history: history,
                                      readableRoots: readableRoots))
        guard !result.word.isEmpty,
              let best = result.candidates.first(where: { $0.kind != .argument && $0.replacement.hasPrefix(result.word) }),
              best.replacement.count > result.word.count
        else { return "" }
        return String(best.replacement.dropFirst(result.word.count))
    }
}
