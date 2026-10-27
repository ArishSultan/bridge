import AppKit
import BridgeCore
import BridgeSystem

/// What shells report through the integration: commands, prompts, and requests.
extension Store {
    /// The helper program, bundled in Contents/Helpers (or next to the app when run from a build
    /// folder).
    static var helperPath: String? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/bridge-helper"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("bridge-helper"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }?.path
    }

    /// Handle one message from a shell; the result, if any, is sent back as the reply.
    func shellMessage(_ connection: ShellConnection, _ fields: [String]) -> String? {
        guard let kind = fields.first, let token = connection.paneToken, let pane = paneID(token: token),
              let session = sessions[pane]
        else { return nil }

        switch kind {
        case "cmd" where fields.count >= 3:
            // zsh: a command starts.
            session.atPrompt = false
            session.running = (fields[1], fields[2], Date())
        case "prompt" where fields.count >= 4:
            // A prompt: the command before it (if any) finished.
            finishCommand(session, exitCode: Int(fields[1]), cwd: fields[2], path: fields[3])
        case "done" where fields.count >= 5:
            // bash: the command that ran (without its start time), reported at the next prompt.
            session.running = (fields[2], fields[3], Date())
            finishCommand(session, exitCode: Int(fields[1]), cwd: fields[3], path: fields[4], timed: false)
        case "closed":
            session.atPrompt = false
        default:
            break
        }
        return nil
    }

    func paneID(token: String) -> ID? {
        tokensLookup(token)
    }

    private func finishCommand(_ session: PaneSession, exitCode: Int?, cwd: String, path: String, timed: Bool = true) {
        session.atPrompt = true
        session.path = path
        session.report(directory: cwd)
        guard let running = session.running else { return }
        session.running = nil

        let duration = Date().timeIntervalSince(running.started)
        record(HistoryEntry(
            command: running.command,
            cwd: running.cwd,
            exitCode: exitCode,
            startedAt: UInt64(running.started.timeIntervalSince1970),
            durationMS: timed ? UInt64(duration * 1000) : nil))

        if timed, settings.notifyLongCommands, duration >= Double(settings.notifyAfterSecs) {
            let command = running.command.count > 60 ? String(running.command.prefix(57)) + "…" : running.command
            Attention.shared.raise(session, body: "“\(command)” \(exitCode == 0 ? "finished" : "failed")")
        }
    }

    /// Show a terminal: its window, its item, and focus on it.
    func reveal(project projectID: ID, pane: ID) {
        open(projectID)
        guard let project = project(projectID), let view = project.view(ofPane: pane) else { return }
        if project.active != view.id { activate(projectID, item: view.id) }
        controllers[projectID]?.focus(pane)
        if let session = sessions[pane] { Attention.shared.clear(session) }
    }

    // MARK: - Command history (⌃R)

    /// Put a command on the prompt of a terminal, replacing what is typed there; `run` presses
    /// Return too.
    func insertCommand(_ command: String, into pane: ID, run: Bool) {
        guard let surface = sessions[pane]?.surface else { return }
        // ⌃E ⌃U: to the end of the line, then delete it.
        surface.typeText("\u{05}\u{15}")
        surface.sendText(command)
        if run { surface.typeText("\r") }
        surface.window?.makeFirstResponder(surface)
    }
}

// MARK: - Sandbox

extension Store {
    /// Where sandbox policies are written for `sandbox-exec -f`.
    static var policyDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("bridge-sandbox", isDirectory: true)
    }

    /// What sandboxed shells must be able to read beyond their profile: the integration scripts,
    /// libghostty's terminfo and shell files, and the helper program.
    static var sandboxReadable: [URL] {
        var urls = [ShellIntegration.directory, Bundle.main.bundleURL]
        if let resources = ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"] {
            urls.append(URL(fileURLWithPath: resources).deletingLastPathComponent())
        }
        if let helper = helperPath { urls.append(URL(fileURLWithPath: helper)) }
        return urls
    }

    /// A new Claude terminal: a task running `claude` in the Claude sandbox (made from the
    /// Project sandbox the first time), started right away.
    func newClaudeTerminal(in projectID: ID) {
        let sandbox = profiles.claudeSandbox()
        addItem(projectID, spec: TerminalSpec(
            name: "Claude",
            kind: .task(command: "claude", autoStart: true, restartOnExit: false),
            isolation: isGlobal(projectID) ? .open : .sandboxed(profile: sandbox)))
    }
}
