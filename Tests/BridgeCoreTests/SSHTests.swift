import Foundation
import Testing
@testable import BridgeCore

struct SSHTests {
    private func host(_ auth: SSHAuth, port: UInt16 = 22, keepalive: UInt32 = 30) -> SSHHost {
        SSHHost(id: 4, name: "box", host: "example.com", port: port, user: "me", auth: auth, keepaliveSecs: keepalive)
    }

    @Test func interactiveArgumentsLikeV1() {
        let agent = SSHCommand.interactive(host(.agent), savedPassword: false, vault: nil, helper: nil)
        #expect(agent.arguments == ["-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3", "--", "me@example.com"])
        let key = SSHCommand.interactive(host(.key(path: "/k"), port: 2222, keepalive: 0), savedPassword: false, vault: nil, helper: nil)
        #expect(key.arguments == ["-p", "2222", "-i", "/k", "-o", "IdentitiesOnly=yes", "--", "me@example.com"])
    }

    @Test func savedPasswordUsesAskpass() {
        let command = SSHCommand.interactive(host(.password, keepalive: 0), savedPassword: true, vault: nil, helper: "/h")
        #expect(command.arguments == [
            "-o", "PreferredAuthentications=keyboard-interactive,password", "-o", "NumberOfPasswordPrompts=1", "--", "me@example.com",
        ])
        #expect(command.environment == ["SSH_ASKPASS": "/h", "SSH_ASKPASS_REQUIRE": "force", "BRIDGE_ASKPASS": "4"])
        let unsaved = SSHCommand.interactive(host(.password, keepalive: 0), savedPassword: false, vault: nil, helper: "/h")
        #expect(unsaved.environment.isEmpty)
    }

    @Test func vaultKeyOnlyWhileUnlocked() {
        let vault = SSHCommand.VaultIdentity(socket: "/s", publicKey: "/p.pub")
        let unlocked = SSHCommand.interactive(host(.vault(item: "i", name: "n"), keepalive: 0), savedPassword: false, vault: vault, helper: nil)
        #expect(unlocked.arguments == ["-o", "IdentityAgent=/s", "-i", "/p.pub", "-o", "IdentitiesOnly=yes", "--", "me@example.com"])
    }

    @Test func forwardingArguments() {
        let forward = Forward(id: 9, kind: .local, bind: "8080", target: "db:5432")
        let command = SSHCommand.forwarding(host(.agent, keepalive: 0), forward, savedPassword: false, vault: nil, helper: nil)
        #expect(command.arguments == [
            "-o", "ExitOnForwardFailure=yes", "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=15",
            "-o", "BatchMode=yes", "-N", "-T", "-v", "-L", "8080:db:5432", "--", "me@example.com",
        ])
        #expect(Forward(id: 1, kind: .remote, bind: "9000", target: "localhost:3000").sshFlag == ["-R", "9000:localhost:3000"])
        #expect(Forward(id: 1, kind: .remote, bind: "9000", target: "localhost:3000").summary == "server localhost:9000 → localhost:3000")
    }

    @Test func readsForwardLog() {
        #expect(ForwardLog.isUp("debug1: Local connections to LOCALHOST:8080 forwarded to remote address db:5432"
            + " ... forwarding listening on 127.0.0.1 port 8080."))
        #expect(ForwardLog.isUp("debug1: remote forward success for: listen 9000, connect localhost:3000"))
        #expect(!ForwardLog.isUp("debug1: Connecting to example.com"))
        let reason = ForwardLog.reason(
            lastLines: ["$ ssh -v x", "debug1: reading", "ssh: connect to host x port 22: Connection refused", "debug1: exit"],
            exitCode: 255)
        #expect(reason == "ssh: connect to host x port 22: Connection refused")
        #expect(ForwardLog.reason(lastLines: ["debug1: a"], exitCode: 255) == "exit code 255")
        #expect(ForwardLog.reason(lastLines: [], exitCode: nil) == "connection closed")
        #expect((0..<7).map(ForwardLog.backoff) == [1, 2, 5, 10, 30, 30, 30])
    }

    @Test func launchPlansForSSH() {
        let project = Project(id: 1, name: "g", dir: "/tmp")
        let spec = TerminalSpec(kind: .ssh(host: 4), isolation: .open)
        let command = SSHCommand.interactive(host(.agent, keepalive: 0), savedPassword: false, vault: nil, helper: nil)
        #expect(Launch.plan(for: spec, in: project, settings: Settings(), ssh: .ready(command)).command == "ssh -- me@example.com")
        #expect(Launch.plan(for: spec, in: project, settings: Settings(), ssh: .vaultLocked).command?.contains("Vaultwarden is locked") == true)
        #expect(TerminalSpec(kind: .ssh(host: 4), isolation: .sandboxed(profile: nil)).effectiveIsolation == .open)
    }

    @Test func refusesOptionLikeDestinations() {
        #expect(host(.agent).hasSafeDestination)
        #expect(!SSHHost(id: 1, name: "x", host: "-oProxyCommand=sh").hasSafeDestination)
        #expect(!SSHHost(id: 1, name: "x", host: "example.com", user: "-l root").hasSafeDestination)
        #expect(!SSHHost(id: 1, name: "x", host: "a b").hasSafeDestination)
    }
}

/// The real profiles.json, when there is one, decodes and survives a round trip.
@Test func realProfilesRoundTrip() throws {
    guard let text = try? String(contentsOf: Profiles.fileURL, encoding: .utf8) else { return }
    let profiles = try JSONDecoder().decode(Profiles.self, from: Data(text.utf8))
    let raw = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    #expect(profiles.hosts.count == (raw["hosts"] as? [Any])?.count ?? 0)
    let again = try JSONDecoder().decode(Profiles.self, from: JSONEncoder().encode(profiles))
    #expect(again == profiles)
}
