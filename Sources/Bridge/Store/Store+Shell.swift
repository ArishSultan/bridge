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
        // A saved SSH password for the helper, if it has this launch's nonce.
        if fields.first == "askpass", fields.count >= 3 {
            return answerAskpass(nonce: fields[1], host: fields[2])
        }
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
        // Requests carry a sequence number the reply starts with.
        case "suggest" where fields.count >= 5:
            return fields[1] + "\u{1F}" + suggestion(for: session, line: fields[2], cwd: fields[3], path: fields[4])
        case "complete" where fields.count >= 5:
            return fields[1] + "\u{1F}" + complete(for: session, line: fields[2], cwd: fields[3], path: fields[4])
        case "line" where fields.count >= 4:
            lineChanged(for: session, line: fields[1], cwd: fields[2], path: fields[3])
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

        // The wall clock can step back while a command runs (a time sync): never below zero.
        let duration = max(0, Date().timeIntervalSince(running.started))
        record(HistoryEntry(
            command: running.command,
            cwd: running.cwd,
            exitCode: exitCode,
            startedAt: UInt64(max(0, running.started.timeIntervalSince1970)),
            durationMS: timed ? UInt64(min(duration * 1000, Double(UInt64.max / 2))) : nil,
            sandboxed: isSandboxed(session)))

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

    /// At launch: what the last run left behind when it ended without cleaning up (a crash or
    /// force quit): sandboxed terminals' temporary folders, and their Docker containers.
    nonisolated static func cleanUpAfterLastRun() {
        try? FileManager.default.removeItem(at: Paths.paneTemporaryRoot)
        let docker = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let docker else { return }
        let list = Process()
        list.executableURL = URL(fileURLWithPath: docker)
        list.arguments = ["ps", "-aq", "--filter", "label=\(Sandbox.containerLabel)"]
        let output = Pipe()
        list.standardOutput = output
        list.standardError = FileHandle.nullDevice
        guard (try? list.run()) != nil else { return }
        let ids = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").map(String.init)
        list.waitUntilExit()
        guard !ids.isEmpty else { return }
        let remove = Process()
        remove.executableURL = URL(fileURLWithPath: docker)
        remove.arguments = ["rm", "-f"] + ids
        remove.standardOutput = FileHandle.nullDevice
        remove.standardError = FileHandle.nullDevice
        try? remove.run()
        remove.waitUntilExit()
    }

    /// A new agent terminal: a task running the agent's command in the Agents sandbox (made
    /// from the Project sandbox the first time), started right away.
    func newAgentTerminal(_ agent: Agent, in projectID: ID) {
        let sandbox = profiles.agentSandbox()
        addItem(projectID, spec: TerminalSpec(
            name: agent.name,
            kind: .task(command: agent.command, autoStart: true, restartOnExit: false),
            isolation: isGlobal(projectID) ? .open : .sandboxed(profile: sandbox), background: true))
    }
}
