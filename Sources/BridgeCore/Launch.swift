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
    /// The plan for `spec` in `project`.
    public static func plan(for spec: TerminalSpec, in project: Project, settings: Settings) -> LaunchPlan {
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
            return failure("SSH sessions arrive in a later version of Bridge v2.", folder: folder)
        }
    }

    /// Wrap a plan in a terminal's sandbox. Returns the new plan and, for Seatbelt, the policy
    /// text to write to `policyFile` (the command reads it from there).
    public static func sandboxed(
        _ plan: LaunchPlan, engine: SandboxEngine, spec: TerminalSpec, pane: ID, project: Project,
        settings: Settings, policyFile: URL, extraReadable: [URL]
    ) -> (plan: LaunchPlan, policy: String?) {
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
            let policy = Sandbox.policy(seatbelt, context: Sandbox.Context(
                root: project.root, extraWritable: [history], extraReadable: extraReadable))
            let inner = plan.command ?? "\(quote(loginShell(settings))) -l"
            // The ssh-agent socket would hand out the user's keys.
            plan.command = "/usr/bin/env -u SSH_AUTH_SOCK /usr/bin/sandbox-exec -f \(quote(policyFile.path)) \(inner)"
            return (plan, policy)
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
            return (plan, nil)
        }
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
