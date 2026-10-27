import AppKit
import BridgeCore
import BridgeSystem

/// SSH sessions and saved passwords.
extension Store {
    /// How an SSH terminal's host resolves now.
    func sshTarget(for spec: TerminalSpec) -> Launch.SSHTarget? {
        guard case .ssh(let id) = spec.kind else { return nil }
        guard let host = profiles.host(id) else { return .missing }
        let vault = vaultIdentity(for: host)
        if case .vault = host.auth, vault == nil { return .vaultLocked }
        guard host.hasSafeDestination else { return .invalid }
        let saved = host.auth == .password && Keychain.hasPassword(host: host.id)
        var command = SSHCommand.interactive(host, savedPassword: saved, vault: vault, helper: Self.helperPath)
        if saved { command.environment.merge(askpassEnvironment(host: host.id)) { _, new in new } }
        return .ready(command)
    }

    /// How long ssh has to ask for the password after it starts.
    static let askpassLifetime: TimeInterval = 120

    /// Lets one ssh process ask the app for a host's saved password: the socket and a
    /// single-use nonce, which programs in other terminals never see. Only for hosts that sign in
    /// with a saved password; the nonce expires if ssh doesn't use it soon.
    func askpassEnvironment(host: ID) -> [String: String] {
        guard let socket = shellSocketPath else { return [:] }
        let now = Date()
        askpassNonces = askpassNonces.filter { now.timeIntervalSince($0.value.issued) < Self.askpassLifetime }
        let nonce = UUID().uuidString
        askpassNonces[nonce] = (host, now)
        return ["BRIDGE_ASKPASS_SOCKET": socket, "BRIDGE_ASKPASS_NONCE": nonce]
    }

    func answerAskpass(nonce: String, host: String) -> String {
        guard let expected = askpassNonces.removeValue(forKey: nonce), "\(expected.host)" == host,
              Date().timeIntervalSince(expected.issued) < Self.askpassLifetime,
              profiles.host(expected.host)?.auth == .password
        else { return "" }
        return Keychain.password(host: expected.host) ?? ""
    }

    /// A host's name, for labels.
    func hostName(_ id: ID) -> String? { profiles.host(id)?.displayName }

    /// Open an SSH session to a host as a new terminal in the Global window.
    func connect(_ host: SSHHost) {
        let global = globalID
        openGlobal()
        addItem(global, spec: TerminalSpec(kind: .ssh(host: host.id), isolation: .open))
    }

    /// Delete a host, its forwards and its saved password.
    func deleteHost(_ id: ID) {
        for forward in profiles.host(id)?.forwards ?? [] { forwards.stop(forward.id) }
        Keychain.deletePassword(host: id)
        profiles.removeHost(id)
    }

    func deleteForward(_ id: ID) {
        forwards.stop(id)
        profiles.removeForward(id)
    }

    /// An SSH session dropped (exit 255, not stopped by hand): what its host says to do.
    func sshDropped(_ session: PaneSession, host: SSHHost) {
        switch host.onDisconnect {
        case .nothing:
            break
        case .notify:
            Attention.shared.notify(
                title: "SSH connection to \(host.displayName) closed",
                body: "\(host.address) — press Return in its terminal to reconnect.",
                identifier: "ssh-\(session.id)")
            controllers[session.projectID]?.toast = "SSH connection to \(host.displayName) closed"
        case .reconnect:
            // Count attempts, starting over after a minute without one.
            let now = Date()
            if let last = session.lastReconnect, now.timeIntervalSince(last) > 60 { session.reconnectAttempts = 0 }
            let attempt = session.reconnectAttempts
            session.reconnectAttempts += 1
            session.lastReconnect = now
            session.restartTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(ForwardLog.backoff(attempt)))
                guard !Task.isCancelled, let self, case .exited = session.status else { return }
                self.start(session.id, in: session.projectID)
            }
        }
    }
}
