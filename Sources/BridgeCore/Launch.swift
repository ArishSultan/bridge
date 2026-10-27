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
