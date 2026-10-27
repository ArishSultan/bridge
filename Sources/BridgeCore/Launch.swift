import Foundation

/// What a terminal runs: the program line, its folder and environment. Decides between the
/// login shell, a task's command and an SSH session, and (later) wraps it in its sandbox.
public struct LaunchPlan: Equatable, Sendable {
    /// Where the program starts.
    public var folder: URL
    /// A shell command line, or nil for the user's login shell.
    public var command: String?
    public var environment: [String: String] = [:]

    public init(folder: URL, command: String?, environment: [String: String] = [:]) {
        self.folder = folder
        self.command = command
        self.environment = environment
    }
}

public enum Launch {
    /// How an SSH terminal's host resolved.
    public enum SSHTarget: Sendable {
        case ready(SSHCommand)
        /// The host was deleted.
        case missing
        /// The host signs in with Vaultwarden, which is locked.
        case vaultLocked
        /// The host's address or user would be read by ssh as an option.
        case invalid
    }

    /// The plan for `spec` in `project`. `ssh` is the resolved host, for SSH terminals.
    public static func plan(for spec: TerminalSpec, in project: Project, settings: Settings, ssh: SSHTarget? = nil) -> LaunchPlan {
        var folder = project.folder(spec.folder)
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir) || !isDir.boolValue {
            folder = project.root
        }

        switch spec.kind {
        case .shell:
            let shell = settings.shell.trimmingCharacters(in: .whitespaces)
            return LaunchPlan(folder: folder, command: shell.isEmpty ? nil : shell)
        case .task(let command, _, _):
            // A login shell, so the task sees the same PATH and tools as an interactive one.
            return LaunchPlan(folder: folder, command: "\(quote(loginShell(settings))) -lc \(quote(command))")
        case .ssh:
            switch ssh {
            case .ready(let command):
                return LaunchPlan(folder: folder, command: command.commandLine, environment: command.environment)
            case .vaultLocked:
                return failure("Vaultwarden is locked. Unlock it in Global (the lock next to SSH hosts), then press Return.", folder: folder)
            case .invalid:
                return failure("This terminal's SSH host has an address or user ssh would read as an option. Fix it in Settings → Hosts.", folder: folder)
            case .missing, nil:
                return failure("This terminal's SSH host was deleted. Choose another in Edit Terminal.", folder: folder)
            }
        }
    }

    /// Wrap a plan in a terminal's sandbox. A Seatbelt policy goes on the command line itself
    /// (`sandbox-exec -p`), never in a file a sandboxed program could replace before the next
    /// start. `appSocket` is the shells' socket, the one the sandbox may reach outside the project.
    public static func sandboxed(
        _ plan: LaunchPlan, engine: SandboxEngine, spec: TerminalSpec, pane: ID, project: Project,
        settings: Settings, appSocket: String?, extraReadable: [URL],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LaunchPlan {
        var plan = plan
        switch engine {
        case .seatbelt(let seatbelt):
            let history = Settings.configDirectory
                .appendingPathComponent("sandbox-history/project-\(project.id).history")
            try? FileManager.default.createDirectory(at: history.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !spec.kind.isTask {
                // The shell keeps its own history (the user's isn't readable in the sandbox), and
                // the project folder stands in for ~.
                plan.environment["BRIDGE_HISTFILE"] = history.path
                if settings.projectIsHome { plan.environment["BRIDGE_PROJECT_ROOT"] = project.root.path }
            }
            // Its own temporary folder, and caches of its own for tools that keep runnable code in
            // theirs (build outputs, downloaded packages, virtualenvs).
            let temporary = Paths.paneTemporary(pane)
            let state = Paths.sandboxState(project: project.id)
            try? Paths.makePrivateDirectory(Paths.paneTemporaryRoot)
            try? Paths.makePrivateDirectory(temporary)
            try? FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            plan.environment["TMPDIR"] = temporary.path + "/"
            plan.environment["BRIDGE_ZCOMPDUMP"] = state.appendingPathComponent("zcompdump").path
            plan.environment.merge(sandboxCaches(state)) { _, new in new }

            let policy = Sandbox.policy(seatbelt, context: Sandbox.Context(
                root: project.root, extraWritable: [history, temporary, state], extraReadable: extraReadable,
                appSocket: appSocket))
            let inner = plan.command ?? "\(quote(loginShell(settings))) -l"
            // The ssh-agent socket would hand out the user's keys, and the app's own environment
            // may hold tokens (when it was started from a terminal).
            let unset = (["SSH_AUTH_SOCK"] + secretVariables(environment)).map { "-u \(quote($0))" }.joined(separator: " ")
            let flat = policy.replacingOccurrences(of: "\n", with: " ")
            plan.command = "/usr/bin/env \(unset) /usr/bin/sandbox-exec -p \(quote(flat)) \(inner)"
            return plan
        case .docker(let docker):
            let root = project.root.standardizedFileURL.path
            let folder = plan.folder.standardizedFileURL.path
            let inside = folder.hasPrefix(root + "/") ? String(folder.dropFirst(root.count + 1)) : ""
            var command: String?
            if case .task(let task, _, _) = spec.kind { command = task }
            let args = Sandbox.dockerArguments(docker, pane: pane, root: project.root, inside: inside, command: command)
            plan.command = (["docker"] + args).map(quote).joined(separator: " ")
            // Shell integration doesn't reach into the container.
            plan.environment = [:]
            return plan
        }
    }

    /// Where tools in a project's sandboxes keep their caches, under `state`.
    static func sandboxCaches(_ state: URL) -> [String: String] {
        func at(_ name: String) -> String { state.appendingPathComponent(name).path }
        return [
            "XDG_CACHE_HOME": at("cache"), "GOPATH": at("go"), "GOCACHE": at("go-build"),
            "CARGO_HOME": at("cargo"), "PIP_CACHE_DIR": at("pip"), "UV_CACHE_DIR": at("uv"),
            "PRE_COMMIT_HOME": at("pre-commit"), "npm_config_store_dir": at("pnpm-store"),
            "BUN_INSTALL_CACHE_DIR": at("bun"), "YARN_CACHE_FOLDER": at("yarn"),
        ]
    }

    /// Variables in the app's environment that look like credentials.
    static func secretVariables(_ environment: [String: String]) -> [String] {
        let markers = ["TOKEN", "SECRET", "PASSWORD", "PASSWD", "API_KEY", "APIKEY", "ACCESS_KEY", "CREDENTIAL", "PRIVATE_KEY"]
        let prefixes = ["AWS_", "GITHUB_", "GH_", "GITLAB_", "OPENAI_", "ANTHROPIC_", "AZURE_", "GOOGLE_APPLICATION"]
        return environment.keys.filter { name in
            let upper = name.uppercased()
            return markers.contains { upper.contains($0) } || prefixes.contains { upper.hasPrefix($0) }
        }.sorted()
    }

    /// A plan that only prints `message` and exits with a failure.
    public static func failure(_ message: String, folder: URL) -> LaunchPlan {
        LaunchPlan(folder: folder, command: "/bin/sh -c \(quote("echo \(quote(message)); exit 1"))")
    }

    /// The first word of the shell setting, else `$SHELL`, else zsh.
    public static func loginShell(_ settings: Settings) -> String {
        if let first = settings.shell.split(separator: " ").first { return String(first) }
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty { return shell }
        return "/bin/zsh"
    }

    /// Quote a word for a POSIX shell: single quotes, with embedded ones closed and reopened.
    public static func quote(_ word: String) -> String {
        if !word.isEmpty, word.allSatisfy({ $0.isLetter || $0.isNumber || "/._-+=:,@%".contains($0) }), word.allSatisfy(\.isASCII) {
            return word
        }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// What a terminal is called when it has no name of its own: the task's command, the SSH
    /// host's name, the program's title, or its folder.
    public static func label(for spec: TerminalSpec, title: String, hostName: (ID) -> String?) -> String {
        if !spec.name.isEmpty { return spec.name }
        switch spec.kind {
        case .task(let command, _, _): return command
        case .ssh(let host): if let name = hostName(host) { return name }
        case .shell: break
        }
        if !title.isEmpty { return title }
        return spec.folder == "." || spec.folder.isEmpty ? "Shell" : (spec.folder as NSString).lastPathComponent
    }
}
