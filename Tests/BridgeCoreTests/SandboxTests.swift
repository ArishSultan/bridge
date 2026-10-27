import Foundation
import Testing
@testable import BridgeCore

struct SandboxTests {
    /// A fake home and project, so the test never touches real files.
    private func fixture() throws -> (home: URL, project: URL, outside: URL) {
        // Not in a temporary folder: those are writable in every sandbox.
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../.build/sandbox-tests/\(UUID())").standardizedFileURL
        let home = base.appendingPathComponent("home")
        let project = home.appendingPathComponent("code/app")
        let fm = FileManager.default
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent(".config/bridge"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent("other"), withIntermediateDirectories: true)
        try "secret".write(to: home.appendingPathComponent(".ssh/id_ed25519"), atomically: true, encoding: .utf8)
        try "{}".write(to: home.appendingPathComponent(".config/bridge/profiles.json"), atomically: true, encoding: .utf8)
        try "private".write(to: home.appendingPathComponent("other/notes.txt"), atomically: true, encoding: .utf8)
        try "{}".write(to: home.appendingPathComponent("code/package.json"), atomically: true, encoding: .utf8)
        try "hello".write(to: project.appendingPathComponent("README"), atomically: true, encoding: .utf8)
        return (home, project, home.appendingPathComponent("other"))
    }

    private func seatbelt(network: Network = .all) -> SandboxEngine.Seatbelt {
        guard case .seatbelt(var s) = SandboxEngine.seatbeltDefaults else { fatalError() }
        s.network = network
        return s
    }

    /// Run a shell command under `policy`; returns its exit status.
    private func run(_ command: String, policy: String) throws -> Int32 {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("policy-\(UUID()).sb")
        try policy.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-f", file.path, "/bin/sh", "-c", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    @Test func confinesReadsAndWrites() throws {
        let (home, project, outside) = try fixture()
        defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
        let policy = Sandbox.policy(seatbelt(), context: .init(root: project, home: home, path: "/usr/bin:/bin", tmpdir: nil))

        // The project: readable and writable.
        #expect(try run("cat \(project.path)/README", policy: policy) == 0)
        #expect(try run("echo x > \(project.path)/new.txt", policy: policy) == 0)
        // System programs still run.
        #expect(try run("/bin/ls /usr/bin >/dev/null", policy: policy) == 0)
        // Outside the project: no reads, no writes.
        #expect(try run("cat \(outside.path)/notes.txt", policy: policy) != 0)
        #expect(try run("echo x > \(outside.path)/x.txt", policy: policy) != 0)
        // Credentials and the app's own files: hidden.
        #expect(try run("cat \(home.path)/.ssh/id_ed25519", policy: policy) != 0)
        #expect(try run("cat \(home.path)/.config/bridge/profiles.json", policy: policy) != 0)
        // Config files in folders above the project stay readable.
        #expect(try run("cat \(home.path)/code/package.json", policy: policy) == 0)
    }

    @Test func blocksPrograms() throws {
        let (home, project, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
        var s = seatbelt()
        s.blocked = ["uname"]
        let policy = Sandbox.policy(s, context: .init(root: project, home: home, path: "/usr/bin:/bin", tmpdir: nil))
        #expect(try run("/usr/bin/uname", policy: policy) != 0)
        #expect(try run("/bin/echo ok", policy: policy) == 0)
    }

    @Test func policyText() throws {
        let (home, project, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
        let policy = Sandbox.policy(seatbelt(network: .none), context: .init(root: project, home: home, path: nil, tmpdir: nil))
        #expect(policy.hasPrefix("(version 1)\n(allow default)\n(deny file-read-data)\n"))
        #expect(policy.contains("(deny network-outbound (remote ip))\n(deny network-bind (local ip))\n"))
        #expect(policy.contains("(deny mach-lookup (global-name \"com.apple.SecurityServer\")"))
        #expect(policy.contains("(deny mach-lookup (global-name \"com.apple.pasteboard.1\"))"))
        #expect(policy.contains("(deny appleevent-send)"))
    }

    @Test func dockerArguments() {
        let args = Sandbox.dockerArguments(
            .init(image: "", network: false, mounts: ["~/data:/data:ro", " "], env: ["TOKEN"]),
            pane: 7, root: URL(fileURLWithPath: "/code/app"), inside: "web", command: nil, home: "/Users/me")
        #expect(args == [
            "run", "--rm", "-it", "--init", "--name", "bridge-7", "--hostname", "sandbox",
            "-v", "/code/app:/workspace", "-w", "/workspace/web", "--network", "none",
            "-v", "/Users/me/data:/data:ro", "-e", "TOKEN", "ubuntu:24.04",
            "/bin/sh", "-c", "if command -v bash >/dev/null 2>&1; then exec bash -l; else exec sh -l; fi",
        ])
        let task = Sandbox.dockerArguments(.init(image: "node:22", network: true, mounts: [], env: []),
                                           pane: 1, root: URL(fileURLWithPath: "/p"), inside: "", command: "npm test")
        #expect(task.suffix(4) == ["node:22", "/bin/sh", "-lc", "npm test"])
    }

    @Test func findsToolchains() throws {
        let (home, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".bun/bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".config/tool"), withIntermediateDirectories: true)
        try "export PATH=\"$HOME/.bun/bin:$PATH\"\nsource ~/.config/tool/env\n"
            .write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        try "".write(to: home.appendingPathComponent(".config/tool/env"), atomically: true, encoding: .utf8)
        let found = Sandbox.shellSetupPaths(home: home.path, path: "\(home.path)/.local/bin:/usr/bin")
        #expect(found.contains(home.path + "/.bun"))
        #expect(found.contains(home.path + "/.config/tool"))
        #expect(found.contains(home.path + "/.config/tool/env"))
        #expect(found.contains(home.path + "/.local/bin"))
    }

    @Test func wrapsLaunchPlans() {
        let project = Project(id: 3, name: "p", dir: "/tmp")
        let plan = LaunchPlan(folder: project.root, command: nil)
        let (wrapped, policy) = Launch.sandboxed(
            plan, engine: .seatbeltDefaults, spec: TerminalSpec(), pane: 9, project: project,
            settings: Settings(), policyFile: URL(fileURLWithPath: "/tmp/p.sb"), extraReadable: [])
        #expect(policy != nil)
        #expect(wrapped.command?.hasPrefix("/usr/bin/env -u SSH_AUTH_SOCK /usr/bin/sandbox-exec -f /tmp/p.sb ") == true)
        #expect(wrapped.environment["BRIDGE_HISTFILE"]?.hasSuffix("sandbox-history/project-3.history") == true)
        #expect(wrapped.environment["BRIDGE_PROJECT_ROOT"] == "/tmp")
    }

    @Test func profilesJSONMatchesV1() throws {
        let json = """
        {"hosts":[{"id":2,"name":"db","host":"db.example.com","auth":{"type":"vault","item":"abc","name":"key"},
          "forwards":[{"id":3,"kind":"dynamic","bind":"1080","enabled":true}]}],
         "sandboxes":[{"id":4,"name":"Agents","engine":{"type":"seatbelt","writable":[],"hidden":[],"network":"localhost","blocked":["docker"],"block_keychain":true}}],
         "vault":{"server":"https://vault.example.com","email":"me@example.com","device_id":"d"},
         "next_id":1}
        """
        var profiles = try JSONDecoder().decode(Profiles.self, from: Data(json.utf8))
        profiles.normalize()
        let host = try #require(profiles.host(2))
        #expect(host.port == 22)
        #expect(host.keepaliveSecs == 30)
        #expect(host.auth == .vault(item: "abc", name: "key"))
        #expect(host.forwards.first?.sshFlag == ["-D", "1080"])
        #expect(host.forwards.first?.summary == "SOCKS on localhost:1080")
        guard case .seatbelt(let s) = profiles.sandbox(4)?.engine else { Issue.record("not seatbelt"); return }
        #expect(s.confineReads)
        #expect(s.readable == SandboxEngine.defaultReadable)
        #expect(profiles.vault?.lockMinutes == 60)
        #expect(profiles.nextID() == 5)
        let again = try JSONDecoder().decode(Profiles.self, from: JSONEncoder().encode(profiles))
        #expect(again.hosts == profiles.hosts)
        #expect(again.sandboxes == profiles.sandboxes)
    }
}

/// Writes the Project sandbox's policy for the real home folder, for trying by hand:
/// `BRIDGE_LIVE_POLICY=/path/out.sb BRIDGE_LIVE_ROOT=/some/project swift test --filter livePolicy`.
@Test func livePolicy() throws {
    let env = ProcessInfo.processInfo.environment
    guard let out = env["BRIDGE_LIVE_POLICY"], let root = env["BRIDGE_LIVE_ROOT"],
          case .seatbelt(let seatbelt) = SandboxEngine.seatbeltDefaults
    else { return }
    let policy = Sandbox.policy(seatbelt, context: .init(
        root: URL(fileURLWithPath: root), extraReadable: [ShellIntegration.directory]))
    try policy.write(toFile: out, atomically: true, encoding: .utf8)
}
