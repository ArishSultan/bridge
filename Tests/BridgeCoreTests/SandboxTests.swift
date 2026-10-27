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
        let policy = Sandbox.policy(seatbelt(), context: .init(root: project, home: home, path: "/usr/bin:/bin"))

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

    @Test func protectsWhatRunsOutsideTheSandbox() throws {
        let (home, project, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
        let fm = FileManager.default
        try fm.createDirectory(at: home.appendingPathComponent(".cargo/bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent("Library/LaunchAgents"), withIntermediateDirectories: true)
        try "".write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        // Even a profile that makes the whole home folder writable…
        var s = seatbelt()
        s.writable = [home.path]
        let policy = Sandbox.policy(s, context: .init(root: project, home: home, path: "/usr/bin:/bin"))
        #expect(try run("echo x > \(home.path)/notes.txt", policy: policy) == 0)
        // …can't change what shells and launchd run later.
        #expect(try run("echo x >> \(home.path)/.zshrc", policy: policy) != 0)
        #expect(try run("echo x > \(home.path)/.zcompdump-host-5.9", policy: policy) != 0)
        #expect(try run("echo x > \(home.path)/.cargo/bin/git", policy: policy) != 0)
        #expect(try run("echo x > \(home.path)/Library/LaunchAgents/x.plist", policy: policy) != 0)
        // Nor read the app's own records.
        #expect(try run("cat \(home.path)/.config/bridge/profiles.json", policy: policy) != 0)
    }

    @Test func ownFilesInsideHiddenFolders() throws {
        let (home, project, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
        let history = home.appendingPathComponent(".config/bridge/sandbox-history/project-1.history")
        let other = home.appendingPathComponent(".config/bridge/sandbox-history/project-2.history")
        try FileManager.default.createDirectory(at: history.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "mine".write(to: history, atomically: true, encoding: .utf8)
        try "theirs".write(to: other, atomically: true, encoding: .utf8)
        let policy = Sandbox.policy(seatbelt(), context: .init(root: project, extraWritable: [history], home: home, path: "/usr/bin:/bin"))
        #expect(try run("cat \(history.path) && echo x >> \(history.path)", policy: policy) == 0)
        #expect(try run("cat \(other.path)", policy: policy) != 0)
    }

    @Test func socketsOnlyWhereAllowed() throws {
        // Socket paths are limited to 104 bytes, so this one lives in the (short) temporary folder,
        // which sandboxes no longer reach.
        let base = Paths.temporaryDirectory.appendingPathComponent("bst-\(UUID().uuidString.prefix(6))")
        let home = base.appendingPathComponent("h"), project = home.appendingPathComponent("p")
        let outside = home.appendingPathComponent("o")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let allowed = project.appendingPathComponent("ok.sock").path
        let app = outside.appendingPathComponent("app.sock").path
        let other = outside.appendingPathComponent("agent.sock").path
        var listeners: [Process] = []
        defer { listeners.forEach { $0.terminate() } }
        for path in [allowed, app, other] {
            let listener = Process()
            listener.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
            listener.arguments = ["-lkU", path]
            try listener.run()
            listeners.append(listener)
        }
        for _ in 0..<50 where ![allowed, app, other].allSatisfy(FileManager.default.fileExists) { usleep(20_000) }
        let policy = Sandbox.policy(seatbelt(), context: .init(root: project, home: home, path: "/usr/bin:/bin", appSocket: app))
        #expect(try run("echo hi | /usr/bin/nc -U \(allowed)", policy: policy) == 0)
        #expect(try run("echo hi | /usr/bin/nc -U \(app)", policy: policy) == 0)
        #expect(try run("echo hi | /usr/bin/nc -U \(other)", policy: policy) != 0)
        // The app socket's folder isn't writable, so it can't be moved aside and replaced.
        #expect(try run("mv \(app) \(project.path)/moved.sock", policy: policy) != 0)
    }

    @Test func blocksPrograms() throws {
        let (home, project, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
        var s = seatbelt()
        s.blocked = ["uname"]
        let policy = Sandbox.policy(s, context: .init(root: project, home: home, path: "/usr/bin:/bin"))
        #expect(try run("/usr/bin/uname", policy: policy) != 0)
        #expect(try run("/bin/echo ok", policy: policy) == 0)
    }

    @Test func policyText() throws {
        let (home, project, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
        let policy = Sandbox.policy(seatbelt(network: .none), context: .init(root: project, home: home, path: nil))
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
            "--label", "dev.bridge.sandbox=1", "--security-opt", "no-new-privileges",
            "--mount", "type=bind,source=/code/app,target=/workspace", "-w", "/workspace/web", "--network", "none",
            "--mount", "type=bind,source=/Users/me/data,target=/data,readonly", "-e", "TOKEN", "ubuntu:24.04",
            "/bin/sh", "-c", "if command -v bash >/dev/null 2>&1; then exec bash -l; else exec sh -l; fi",
        ])
        let task = Sandbox.dockerArguments(.init(image: "node:22", network: true, mounts: [], env: []),
                                           pane: 1, root: URL(fileURLWithPath: "/p"), inside: "", command: "npm test")
        #expect(task.suffix(4) == ["node:22", "/bin/sh", "-lc", "npm test"])
        // A comma in a folder name can't add mount options.
        #expect(Sandbox.mountSpec(source: "/a,readonly=false,src=/", target: "/w", readOnly: false)
            == "type=bind,\"source=/a,readonly=false,src=/\",target=/w")
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
        let wrapped = Launch.sandboxed(
            plan, engine: .seatbeltDefaults, spec: TerminalSpec(), pane: 9, project: project,
            settings: Settings(), appSocket: "/run/app.sock", extraReadable: [],
            environment: ["GITHUB_TOKEN": "x", "HOME": "/h", "MY_API_KEY": "y"])
        let command = try? #require(wrapped.command)
        // The policy is passed inline, never through a file a sandbox could swap.
        #expect(command?.hasPrefix("/usr/bin/env -u SSH_AUTH_SOCK -u GITHUB_TOKEN -u MY_API_KEY /usr/bin/sandbox-exec -p '(version 1)") == true)
        #expect(command?.contains("(literal \"/run/app.sock\")") == true)
        #expect(command?.contains("\n") == false)
        #expect(wrapped.environment["BRIDGE_HISTFILE"]?.hasSuffix("sandbox-history/project-3.history") == true)
        #expect(wrapped.environment["BRIDGE_PROJECT_ROOT"] == "/tmp")
        #expect(wrapped.environment["TMPDIR"] == Paths.paneTemporary(9).path + "/")
        #expect(wrapped.environment["CARGO_HOME"] == Paths.sandboxState(project: 3).appendingPathComponent("cargo").path)
    }

    @Test func dropsUnsafeWritableFromOldProfiles() throws {
        let old = SandboxEngine.seatbelt(.init(writable: ["~/.cargo", "~/.npm", "~/.zcompdump", "~/.cache"], hidden: [],
                                               network: .all, blocked: [], blockKeychain: true))
        guard case .seatbelt(let s) = old.withoutUnsafeWritable() else { Issue.record("not seatbelt"); return }
        #expect(s.writable == ["~/.npm"])
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

/// Writes the command a Project-sandboxed shell starts with, for the real home folder, for
/// trying by hand: `BRIDGE_LIVE_COMMAND=/path/out.sh BRIDGE_LIVE_ROOT=/some/project swift test
/// --filter liveCommand`, then `bash /path/out.sh`.
@Test func liveCommand() throws {
    let env = ProcessInfo.processInfo.environment
    guard let out = env["BRIDGE_LIVE_COMMAND"], let root = env["BRIDGE_LIVE_ROOT"] else { return }
    let project = Project(id: 999, name: "live", dir: root)
    let engine: SandboxEngine = env["BRIDGE_LIVE_AGENTS"] != nil ? .forAgents(.seatbeltDefaults) : .seatbeltDefaults
    let plan = Launch.sandboxed(
        LaunchPlan(folder: project.root, command: env["BRIDGE_LIVE_INNER"]), engine: engine, spec: TerminalSpec(),
        pane: 999, project: project, settings: Settings(), appSocket: nil, extraReadable: [ShellIntegration.directory])
    let exports = plan.environment.sorted { $0.key < $1.key }.map { "export \($0.key)=\(Launch.quote($0.value))" }
    try (exports + ["cd \(Launch.quote(root))", plan.command ?? ""]).joined(separator: "\n")
        .write(toFile: out, atomically: true, encoding: .utf8)
}

struct SandboxDenialTests {
    @Test func parsesKernelMessages() throws {
        let denial = try #require(SandboxDenial.parse("Sandbox: cat(2053) deny(1) file-read-data /Users/me/.ssh/config\nbridge-pane-42"))
        #expect(denial == SandboxDenial(pane: 42, process: "cat", operation: "file-read-data", target: "/Users/me/.ssh/config"))
        #expect(denial.kind == .read && denial.isPath)
        let repeated = try #require(SandboxDenial.parse(
            "4 duplicate reports for Sandbox: node (helper)(77) deny(1) mach-lookup com.apple.pasteboard.1\nbridge-pane-7"))
        #expect(repeated.process == "node (helper)")
        #expect(repeated.count == 5)
        #expect(repeated.kind == .service)
        #expect(SandboxDenial.parse("Sandbox: Safari(1) deny(1) mach-lookup x") == nil)
    }

    @Test func policyMarksDenials() throws {
        guard case .seatbelt(let s) = SandboxEngine.seatbeltDefaults else { return }
        let policy = Sandbox.policy(s, context: .init(root: URL(fileURLWithPath: "/tmp"), path: nil, marker: "bridge-pane-3"))
        #expect(policy.contains(#"(deny file-write* (with message "bridge-pane-3"))"#))
        // Every deny rule carries it.
        let denies = policy.components(separatedBy: "(deny ").count - 1
        #expect(policy.components(separatedBy: #"(with message "bridge-pane-3")"#).count - 1 == denies)
    }
}

@Test func onlyTheSessionsOwnTTY() {
    guard case .seatbelt(let s) = SandboxEngine.seatbeltDefaults else { return }
    let policy = Sandbox.policy(s, context: .init(root: URL(fileURLWithPath: "/tmp"), path: nil, tty: Sandbox.ttyPlaceholder))
    #expect(policy.contains(#"(deny file-read-data file-write* (regex #"^/dev/ttys[0-9]+$"))"#))
    #expect(policy.contains(#"(allow file-read-data file-write* (literal "@BRIDGE_TTY@"))"#))
    let plan = Launch.sandboxed(
        LaunchPlan(folder: URL(fileURLWithPath: "/tmp"), command: nil), engine: .seatbeltDefaults, spec: TerminalSpec(),
        pane: 1, project: Project(id: 1, name: "p", dir: "/tmp"), settings: Settings(), appSocket: nil,
        extraReadable: [], helper: "/Apps/Bridge.app/Contents/Helpers/bridge-helper", environment: [:])
    #expect(plan.command?.hasPrefix("/usr/bin/env -u SSH_AUTH_SOCK /Apps/Bridge.app/Contents/Helpers/bridge-helper sandbox '") == true)
}
