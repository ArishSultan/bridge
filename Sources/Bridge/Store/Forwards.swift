import AppKit
import BridgeCore
import BridgeSystem
import Observation

/// Runs port forwards: each as its own `ssh -N -v` (under the helper's guard, so it ends with
/// the app), its state read from ssh's log, reconnecting with a growing delay when the host
/// says so. Ported from v1's forward supervisor.
@MainActor
@Observable
final class Forwards {
    enum State: Equatable {
        case off
        case connecting
        case up
        case retrying(attempt: Int)
        case failed(String)

        var text: String {
            switch self {
            case .off: "Off"
            case .connecting: "Connecting…"
            case .up: "Forwarding"
            case .retrying(let attempt): "Reconnecting (attempt \(attempt + 1))…"
            case .failed(let reason): "Failed: \(reason)"
            }
        }
    }

    private(set) var states: [ID: State] = [:]
    private(set) var logs: [ID: [String]] = [:]

    @ObservationIgnored private var processes: [ID: Process] = [:]
    /// Bumped on every start, stop or failure; events from an older run are ignored.
    @ObservationIgnored private var generations: [ID: Int] = [:]
    @ObservationIgnored private var attempts: [ID: Int] = [:]
    @ObservationIgnored private var upSince: [ID: Date] = [:]
    @ObservationIgnored private var partialLines: [ID: String] = [:]

    private static let logLimit = 2000

    func state(_ id: ID) -> State { states[id] ?? .off }

    /// Start every forward that was on when the app last quit.
    func startEnabled() {
        for host in Store.shared.profiles.hosts {
            for forward in host.forwards where forward.enabled { start(forward.id) }
        }
    }

    /// The switch: remember it, and start or stop.
    func setEnabled(_ id: ID, _ enabled: Bool) {
        Store.shared.profiles.setForward(id, enabled: enabled)
        attempts[id] = 0
        enabled ? start(id) : stop(id)
    }

    /// Restart the forwards of hosts that sign in with Vaultwarden (the vault was locked or
    /// unlocked).
    func reloadVaultForwards() {
        for host in Store.shared.profiles.hosts {
            guard case .vault = host.auth else { continue }
            for forward in host.forwards where forward.enabled { start(forward.id) }
        }
    }

    func start(_ id: ID) {
        stopProcess(id)
        let generation = (generations[id] ?? 0) + 1
        generations[id] = generation
        let store = Store.shared
        guard let (forward, host) = store.profiles.forward(id) else { return }

        let vault = store.vaultIdentity(for: host)
        if case .vault = host.auth, vault == nil {
            fail(id, "Vaultwarden is locked")
            return
        }
        let savedPassword = host.auth == .password && Keychain.hasPassword(host: host.id)
        var command = SSHCommand.forwarding(host, forward, savedPassword: savedPassword, vault: vault, helper: Store.helperPath)
        command.environment.merge(store.askpassEnvironment(host: host.id)) { _, new in new }

        let process = Process()
        if let helper = Store.helperPath {
            process.executableURL = URL(fileURLWithPath: helper)
            process.arguments = ["guard", "/usr/bin/ssh"] + command.arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = command.arguments
        }
        process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr

        append(id, "$ ssh " + command.arguments.joined(separator: " "))
        states[id] = .connecting
        partialLines[id] = ""

        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in Store.shared.forwards.received(id, generation: generation, text: text) }
        }
        process.terminationHandler = { process in
            let code = process.terminationReason == .exit ? process.terminationStatus : nil
            Task { @MainActor in Store.shared.forwards.exited(id, generation: generation, code: code) }
        }
        do {
            try process.run()
            processes[id] = process
        } catch {
            fail(id, error.localizedDescription)
        }
    }

    func stop(_ id: ID) {
        generations[id] = (generations[id] ?? 0) + 1
        if processes[id] != nil { append(id, "Stopped.") }
        stopProcess(id)
        states[id] = .off
    }

    func stopAll() {
        for id in Array(processes.keys) { stop(id) }
    }

    private func stopProcess(_ id: ID) {
        guard let process = processes.removeValue(forKey: id) else { return }
        (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    private func fail(_ id: ID, _ reason: String) {
        generations[id] = (generations[id] ?? 0) + 1
        stopProcess(id)
        states[id] = .failed(reason)
        append(id, "ssh exited (\(reason)).")
    }

    private func received(_ id: ID, generation: Int, text: String) {
        guard generations[id] == generation else { return }
        var buffer = (partialLines[id] ?? "") + text
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newline]).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            buffer = String(buffer[buffer.index(after: newline)...])
            append(id, line)
            if ForwardLog.isUp(line), state(id) != .up {
                states[id] = .up
                upSince[id] = Date()
            }
        }
        partialLines[id] = buffer
    }

    private func exited(_ id: ID, generation: Int, code: Int32?) {
        guard generations[id] == generation else { return }
        processes[id] = nil
        let wasUp = state(id) == .up
        if let since = upSince.removeValue(forKey: id), Date().timeIntervalSince(since) >= ForwardLog.stableAfter {
            attempts[id] = 0
        }
        let reason = ForwardLog.reason(lastLines: logs[id] ?? [], exitCode: code)
        append(id, "ssh exited (\(reason)).")

        guard let (forward, host) = Store.shared.profiles.forward(id) else { return }
        if wasUp && host.onDisconnect == .notify {
            Attention.shared.notify(
                title: "Port forward stopped: \(forward.name.isEmpty ? forward.summary : forward.name) (\(host.displayName))",
                body: reason, identifier: "forward-\(id)")
        }
        if host.onDisconnect == .reconnect {
            let attempt = attempts[id] ?? 0
            attempts[id] = attempt + 1
            states[id] = .retrying(attempt: attempt)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(ForwardLog.backoff(attempt)))
                guard let self, self.generations[id] == generation, case .retrying = self.state(id) else { return }
                self.start(id)
            }
        } else {
            states[id] = .failed(reason)
        }
    }

    private func append(_ id: ID, _ line: String) {
        var log = logs[id] ?? []
        log.append(line)
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
        logs[id] = log
    }
}
