import AppKit
import BridgeCore
import BridgeSystem

/// The unlocked vault: its private ssh-agent and where each key's public half is.
final class VaultSession: @unchecked Sendable {
    let agent: VaultAgent
    var publicKeys: [String: String] = [:]

    init(agent: VaultAgent) {
        self.agent = agent
    }
}

/// Vaultwarden: unlocking loads its SSH keys into a private agent, in memory only; locking (by
/// hand, after an idle time, or at quit) ends the agent and its keys.
extension Store {
    var vaultUnlocked: Bool { vaultSession != nil }

    /// Where a host's Vaultwarden key is served, while the vault is unlocked.
    func vaultIdentity(for host: SSHHost) -> SSHCommand.VaultIdentity? {
        guard case .vault(let item, _) = host.auth, let session = vaultSession,
              let publicKey = session.publicKeys[item]
        else { return nil }
        vaultLastUsed = Date()
        return SSHCommand.VaultIdentity(socket: session.agent.socket, publicKey: publicKey)
    }

    struct UnlockResult {
        let loaded: Int
        let skipped: Int
        let failures: [String]
    }

    /// Log in, decrypt the SSH keys and load them into a new agent. Saves the account (never
    /// the password).
    func unlockVault(_ login: VaultClient.Login, lockMinutes: UInt32) async throws -> UnlockResult {
        let unlocked = try await VaultClient.unlock(login)
        return try await load(unlocked, server: login.server, email: login.email, deviceID: login.deviceID, lockMinutes: lockMinutes)
    }

    /// Finish a single sign-on with the master password, and load the keys.
    func unlockVault(sso: VaultClient.SSOSignIn, password: String, deviceID: String, lockMinutes: UInt32,
                     twoFactor: (provider: Int, code: String)?) async throws -> UnlockResult {
        let (unlocked, email) = try await VaultClient.unlock(sso: sso, password: password, deviceID: deviceID, twoFactor: twoFactor)
        return try await load(unlocked, server: sso.server, email: email, deviceID: deviceID, lockMinutes: lockMinutes)
    }

    private func load(_ unlocked: VaultClient.Unlocked, server: String, email: String, deviceID: String,
                      lockMinutes: UInt32) async throws -> UnlockResult {
        let helper = Self.helperPath
        // Starting the agent and ssh-add block, so do it off the main thread.
        let (session, keys, failures) = try await Task.detached {
            let session = VaultSession(agent: try VaultAgent(helper: helper))
            var keys: [VaultKey] = []
            var failures: [String] = []
            for key in unlocked.keys {
                do {
                    session.publicKeys[key.id] = try session.agent.add(id: key.id, privateKey: key.privateKey)
                    keys.append(VaultKey(id: key.id, name: key.name))
                } catch {
                    failures.append("\(key.name): \(error.localizedDescription)")
                }
            }
            return (session, keys, failures)
        }.value

        lockVault(reloadForwards: false)
        vaultSession = session
        vaultKeys = keys
        vaultLastUsed = Date()
        profiles.vault = VaultAccount(
            server: (try? VaultClient.serverURL(server)) ?? server,
            email: email.trimmingCharacters(in: .whitespaces), deviceID: deviceID, lockMinutes: lockMinutes)
        startVaultTimer()
        forwards.reloadVaultForwards()
        return UnlockResult(loaded: keys.count, skipped: unlocked.skipped, failures: failures)
    }

    func lockVault() {
        lockVault(reloadForwards: true)
    }

    func lockVault(reloadForwards: Bool) {
        vaultTimer?.invalidate()
        vaultTimer = nil
        guard let session = vaultSession else { return }
        session.agent.stop()
        vaultSession = nil
        vaultKeys = []
        if reloadForwards { forwards.reloadVaultForwards() }
    }

    /// Lock after the account's idle time (checked every 5 seconds); "used" means an SSH
    /// session or forward took a key.
    private func startVaultTimer() {
        vaultTimer?.invalidate()
        vaultTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated {
                let store = Store.shared
                guard let minutes = store.profiles.vault?.lockMinutes, minutes > 0,
                      Date().timeIntervalSince(store.vaultLastUsed) >= Double(minutes) * 60
                else { return }
                store.lockVault()
            }
        }
    }
}
