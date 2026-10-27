import Foundation

/// Saved profiles: SSH hosts with their port forwards, sandbox profiles and the Vaultwarden
/// account, stored in the app's data store (v1's `profiles.json` is read once). Secrets are never
/// stored there: saved SSH passwords live in the Keychain.
public struct Profiles: Equatable, Sendable {
    public var hosts: [SSHHost] = []
    public var sandboxes: [SandboxProfile] = []
    /// The built-in Project sandbox, when edited (otherwise `SandboxEngine.seatbeltDefaults`).
    public var projectSandbox: SandboxEngine?
    public var vault: VaultAccount?
    private var counter: ID = 1

    public init() {}

    /// Profiles as stored.
    public init(hosts: [SSHHost], sandboxes: [SandboxProfile], projectSandbox: SandboxEngine?, vault: VaultAccount?, nextID: ID) {
        self.hosts = hosts
        self.sandboxes = sandboxes
        self.projectSandbox = projectSandbox
        self.vault = vault
        counter = nextID
        normalize()
    }

    /// The next id `nextID()` hands out.
    public var nextFreeID: ID { counter }

    public func host(_ id: ID) -> SSHHost? { hosts.first { $0.id == id } }
    public func sandbox(_ id: ID) -> SandboxProfile? { sandboxes.first { $0.id == id } }

    public mutating func nextID() -> ID {
        let id = max(counter, 1)
        counter = id + 1
        return id
    }

    /// The Project sandbox's settings.
    public var projectEngine: SandboxEngine { projectSandbox ?? .seatbeltDefaults }

    /// The sandbox a terminal runs in: its profile, or the Project sandbox.
    public func engine(for profile: ID?) -> SandboxEngine {
        profile.flatMap { sandbox($0)?.engine } ?? projectEngine
    }

    /// Add a host, or replace the one with the same id (keeping its forwards). Returns its id.
    @discardableResult
    public mutating func upsert(_ host: SSHHost) -> ID {
        var host = host
        if let index = hosts.firstIndex(where: { $0.id == host.id && host.id != 0 }) {
            host.forwards = hosts[index].forwards
            hosts[index] = host
            return host.id
        }
        host.id = nextID()
        hosts.append(host)
        return host.id
    }

    /// Add a forward to a host, or replace the one with the same id (keeping whether it's on).
    @discardableResult
    public mutating func upsert(_ forward: Forward, host: ID) -> ID? {
        guard let hostIndex = hosts.firstIndex(where: { $0.id == host }) else { return nil }
        var forward = forward
        if let index = hosts[hostIndex].forwards.firstIndex(where: { $0.id == forward.id && forward.id != 0 }) {
            forward.enabled = hosts[hostIndex].forwards[index].enabled
            hosts[hostIndex].forwards[index] = forward
            return forward.id
        }
        forward.id = nextID()
        hosts[hostIndex].forwards.append(forward)
        return forward.id
    }

    public mutating func removeHost(_ id: ID) {
        hosts.removeAll { $0.id == id }
    }

    public mutating func removeForward(_ id: ID) {
        for index in hosts.indices { hosts[index].forwards.removeAll { $0.id == id } }
    }

    public mutating func setForward(_ id: ID, enabled: Bool) {
        for h in hosts.indices {
            for f in hosts[h].forwards.indices where hosts[h].forwards[f].id == id {
                hosts[h].forwards[f].enabled = enabled
            }
        }
    }

    /// The forward with this id and its host.
    public func forward(_ id: ID) -> (forward: Forward, host: SSHHost)? {
        for host in hosts {
            if let forward = host.forwards.first(where: { $0.id == id }) { return (forward, host) }
        }
        return nil
    }

    @discardableResult
    public mutating func upsert(_ sandbox: SandboxProfile) -> ID {
        var sandbox = sandbox
        if let index = sandboxes.firstIndex(where: { $0.id == sandbox.id && sandbox.id != 0 }) {
            sandboxes[index] = sandbox
            return sandbox.id
        }
        sandbox.id = nextID()
        sandboxes.append(sandbox)
        return sandbox.id
    }

    /// The Agents sandbox's id, making it (from the Project sandbox) the first time. A "Claude"
    /// sandbox made by an earlier version counts.
    public mutating func agentSandbox() -> ID {
        if let existing = sandboxes.first(where: { $0.name == SandboxProfile.agentsName })
            ?? sandboxes.first(where: { $0.name == SandboxProfile.claudeName }) {
            return existing.id
        }
        return upsert(SandboxProfile(id: 0, name: SandboxProfile.agentsName, engine: .forAgents(projectEngine)))
    }

    mutating func normalize() {
        // Drop the writable paths older versions defaulted to, which let a sandbox escape.
        projectSandbox = projectSandbox?.withoutUnsafeWritable()
        for index in sandboxes.indices { sandboxes[index].engine = sandboxes[index].engine.withoutUnsafeWritable() }
        let maxID = (hosts.flatMap { [$0.id] + $0.forwards.map(\.id) } + sandboxes.map(\.id)).max() ?? 0
        counter = max(counter, maxID + 1)
    }
}

/// How an SSH host signs in.
public enum SSHAuth: Equatable, Sendable, Hashable {
    /// Whatever `ssh` would use: the agent, `~/.ssh/config` and default keys.
    case agent
    /// A private key file.
    case key(path: String)
    /// A password, kept in the Keychain when saved (otherwise ssh asks for it).
    case password
    /// An SSH key from Vaultwarden, served by the app's agent while the vault is unlocked.
    case vault(item: String, name: String)
}

/// What to do when a connection drops.
public enum OnDisconnect: String, Codable, Sendable, CaseIterable {
    case nothing, notify, reconnect

    public var label: String {
        switch self {
        case .nothing: "Do nothing"
        case .notify: "Notify"
        case .reconnect: "Reconnect"
        }
    }
}

public enum ForwardKind: String, Codable, Sendable, CaseIterable {
    /// A local port reaches a target through the server (`ssh -L`).
    case local
    /// A port on the server reaches a target on this machine (`ssh -R`).
    case remote
    /// A local SOCKS proxy through the server (`ssh -D`).
    case dynamic

    public var label: String {
        switch self {
        case .local: "Local"
        case .remote: "Remote"
        case .dynamic: "SOCKS"
        }
    }
}

/// A port forward over an SSH host, run as its own connection so each can be switched on and off.
public struct Forward: Equatable, Sendable, Identifiable, Hashable {
    public var id: ID
    public var name = ""
    public var kind: ForwardKind = .local
    /// Where it listens: `8080` or `127.0.0.1:8080` (on the server for remote forwards).
    public var bind: String
    /// Where connections go: `localhost:5432`; unused for SOCKS.
    public var target = ""
    /// Keep its connection log to show.
    public var showLogs = false
    /// Switched on; it reconnects at launch.
    public var enabled = false

    public init(id: ID, name: String = "", kind: ForwardKind = .local, bind: String, target: String = "",
                showLogs: Bool = false, enabled: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.bind = bind
        self.target = target
        self.showLogs = showLogs
        self.enabled = enabled
    }

    /// The `-L` / `-R` / `-D` arguments.
    public var sshFlag: [String] {
        let bind = bind.trimmingCharacters(in: .whitespaces)
        let target = target.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .local: return ["-L", "\(bind):\(target)"]
        case .remote: return ["-R", "\(bind):\(target)"]
        case .dynamic: return ["-D", bind]
        }
    }

    /// `localhost:8080 → db:5432`, for display.
    public var summary: String {
        let trimmed = bind.trimmingCharacters(in: .whitespaces)
        let bind = trimmed.contains(":") ? trimmed : "localhost:\(trimmed)"
        let target = target.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .local: return "\(bind) → \(target)"
        case .remote: return "server \(bind) → \(target)"
        case .dynamic: return "SOCKS on \(bind)"
        }
    }
}

public struct SSHHost: Equatable, Sendable, Identifiable, Hashable {
    public var id: ID
    public var name: String
    public var host: String
    public var port: UInt16 = 22
    /// Empty: ssh's default (from `~/.ssh/config` or the local user name).
    public var user = ""
    public var auth: SSHAuth = .agent
    /// Seconds between keep-alive messages; 0 turns them off.
    public var keepaliveSecs: UInt32 = 30
    public var onDisconnect: OnDisconnect = .nothing
    public var forwards: [Forward] = []

    public init(id: ID, name: String, host: String, port: UInt16 = 22, user: String = "", auth: SSHAuth = .agent,
                keepaliveSecs: UInt32 = 30, onDisconnect: OnDisconnect = .nothing, forwards: [Forward] = []) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.user = user
        self.auth = auth
        self.keepaliveSecs = keepaliveSecs
        self.onDisconnect = onDisconnect
        self.forwards = forwards
    }

    /// `user@host`, or just `host` without a user.
    public var destination: String {
        let user = user.trimmingCharacters(in: .whitespaces)
        let host = host.trimmingCharacters(in: .whitespaces)
        return user.isEmpty ? host : "\(user)@\(host)"
    }

    /// Whether ssh would take the user and address as a destination, never as options (a host of
    /// `-oProxyCommand=…` would run a command).
    public var hasSafeDestination: Bool {
        let user = user.trimmingCharacters(in: .whitespaces)
        let host = host.trimmingCharacters(in: .whitespaces)
        return !host.isEmpty && !host.hasPrefix("-") && !user.hasPrefix("-")
            && !(host + user).contains(where: { $0.isWhitespace || $0.isNewline })
    }

    /// `user@host:port` for display, leaving out the default port.
    public var address: String { port == 22 ? destination : "\(destination):\(port)" }

    public var displayName: String { name.isEmpty ? host : name }
}

/// What a Seatbelt sandbox lets its programs reach on the network.
public enum Network: String, Codable, Sendable, CaseIterable {
    case all, localhost, none

    public var label: String {
        switch self {
        case .all: "Allowed"
        case .localhost: "Localhost only"
        case .none: "Blocked"
        }
    }
}

/// How a sandbox isolates what runs in it.
public enum SandboxEngine: Equatable, Sendable, Hashable {
    /// macOS's own sandbox (`sandbox-exec`), around the user's shell and tools.
    case seatbelt(Seatbelt)
    /// A Linux container that sees only the terminal's folder (and any extra mounts).
    case docker(Docker)

    public struct Seatbelt: Equatable, Sendable, Hashable {
        /// Writable besides the project and temporary folders (`~` allowed).
        public var writable: [String]
        /// Neither readable nor writable.
        public var hidden: [String]
        public var network: Network
        /// Programs that may not be run (names looked up on PATH, or paths).
        public var blocked: [String]
        /// Refuse access to the Keychain through the system service.
        public var blockKeychain: Bool
        /// Only let programs read the project, system folders, what's writable and `readable`.
        public var confineReads = true
        /// Readable (not writable) while reads are confined: shell and toolchain setup.
        public var readable: [String] = SandboxEngine.defaultReadable
        /// Let programs read and set the clipboard (pasting with ⌘V works either way).
        public var allowClipboard = false
        /// Let programs open apps, files and links in other apps.
        public var allowOpen = false

        public init(writable: [String], hidden: [String], network: Network, blocked: [String], blockKeychain: Bool,
                    confineReads: Bool = true, readable: [String] = SandboxEngine.defaultReadable,
                    allowClipboard: Bool = false, allowOpen: Bool = false) {
            self.writable = writable
            self.hidden = hidden
            self.network = network
            self.blocked = blocked
            self.blockKeychain = blockKeychain
            self.confineReads = confineReads
            self.readable = readable
            self.allowClipboard = allowClipboard
            self.allowOpen = allowOpen
        }
    }

    public struct Docker: Equatable, Sendable, Hashable {
        public var image: String
        public var network: Bool
        /// Extra `host:container[:ro]` mounts.
        public var mounts: [String]
        /// Environment variables passed in by name.
        public var env: [String]

        public init(image: String, network: Bool, mounts: [String], env: [String]) {
            self.image = image
            self.network = network
            self.mounts = mounts
            self.env = env
        }
    }

    public var isDocker: Bool { if case .docker = self { true } else { false } }

    /// What a shell and common toolchains read from the home folder at startup and while working.
    public static let defaultReadable = [
        "~/.zshenv", "~/.zprofile", "~/.zshrc", "~/.zlogin", "~/.zlogout", "~/.zsh", "~/.oh-my-zsh",
        "~/.bashrc", "~/.bash_profile", "~/.profile", "~/.inputrc", "~/.gitconfig", "~/.gitignore_global",
        "~/.config/git", "~/.config/starship.toml", "~/.config/bridge/shell", "~/.config/bridge/shell-v2",
        "~/.local/bin", "~/.local/share/mise", "~/.nvm", "~/.volta", "~/.bun", "~/.deno", "~/.rustup",
        "~/.pyenv", "~/.rbenv", "~/.asdf", "~/.sdkman", "~/go", "~/Library/pnpm",
    ]

    /// What a new Seatbelt profile starts from: tools keep shared caches that check what they
    /// store (npm's) and the system's own; credentials stay out of reach. Everything that keeps
    /// runnable code (Go and Cargo builds, virtualenvs) gets per-project caches instead (see
    /// `Launch.sandboxCaches`), and what the app always hides or keeps read-only is added on top
    /// (see `Sandbox.policy`).
    public static var seatbeltDefaults: SandboxEngine {
        .seatbelt(Seatbelt(
            writable: ["~/Library/Caches", "~/.npm"],
            hidden: ["~/.ssh", "~/.aws", "~/.gnupg", "~/.kube", "~/.netrc", "~/.docker/config.json", "~/.config/gh",
                     "~/Library/Keychains", "~/.codex", "~/.claude", "~/.claude.json", "~/.gemini"],
            network: .all, blocked: [], blockKeychain: true))
    }

    /// What coding agents keep in the home folder: their settings, sessions and logins.
    public static let agentFolders = ["~/.claude", "~/.claude.json", "~/.codex", "~/.gemini"]

    /// The Project sandbox, opened up for coding agents (Claude Code, Codex, Gemini): they keep
    /// their state in the home folder, Claude Code's login lives in the Keychain, and signing in
    /// needs a browser. Their hooks, commands and settings stay read-only (`Sandbox.neverWritable`),
    /// so an agent can't make itself run something outside the sandbox later.
    public static func forAgents(_ project: SandboxEngine) -> SandboxEngine {
        guard case .seatbelt(var seatbelt) = project else { return forAgents(seatbeltDefaults) }
        let opened = agentFolders + ["~/Library/Keychains"]
        seatbelt.hidden.removeAll { opened.contains($0) }
        for path in opened where !seatbelt.writable.contains(path) {
            seatbelt.writable.append(path)
        }
        seatbelt.blockKeychain = false
        seatbelt.allowOpen = true
        return .seatbelt(seatbelt)
    }

    /// Paths older defaults made writable that let a sandbox plant code run outside it.
    public static let unsafeWritable = ["~/.cargo", "~/.zcompdump", "~/.cache"]

    /// A profile without the unsafe writable paths older versions started from.
    public func withoutUnsafeWritable() -> SandboxEngine {
        guard case .seatbelt(var seatbelt) = self else { return self }
        seatbelt.writable.removeAll { Self.unsafeWritable.contains($0.trimmingCharacters(in: .whitespaces)) }
        return .seatbelt(seatbelt)
    }

    public static var dockerDefaults: SandboxEngine {
        .docker(Docker(image: "ubuntu:24.04", network: true, mounts: [], env: []))
    }
}

public struct SandboxProfile: Equatable, Sendable, Identifiable, Hashable, Codable {
    public var id: ID
    public var name: String
    public var engine: SandboxEngine

    public static let projectName = "Project"
    public static let agentsName = "Agents"
    /// What the Agents sandbox was called before it covered more than Claude Code.
    public static let claudeName = "Claude"

    public init(id: ID, name: String, engine: SandboxEngine) {
        self.id = id
        self.name = name
        self.engine = engine
    }
}

/// The linked Vaultwarden account (never the password or keys).
public struct VaultAccount: Equatable, Sendable, Codable {
    public var server: String
    public var email: String
    public var deviceID: String
    /// Lock after this many idle minutes; 0 never.
    public var lockMinutes: UInt32 = 60

    public init(server: String, email: String, deviceID: String, lockMinutes: UInt32 = 60) {
        self.server = server
        self.email = email
        self.deviceID = deviceID
        self.lockMinutes = lockMinutes
    }

    private enum Keys: String, CodingKey { case server, email, deviceID = "device_id", lockMinutes = "lock_minutes" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        server = try c.decode(String.self, forKey: .server)
        email = try c.decode(String.self, forKey: .email)
        deviceID = try c.decode(String.self, forKey: .deviceID)
        lockMinutes = try c.decodeIfPresent(UInt32.self, forKey: .lockMinutes) ?? 60
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(server, forKey: .server)
        try c.encode(email, forKey: .email)
        try c.encode(deviceID, forKey: .deviceID)
        try c.encode(lockMinutes, forKey: .lockMinutes)
    }
}

// MARK: - v1's file

extension Profiles {
    /// v1's file, read once into the data store.
    public static var fileURL: URL { Settings.configDirectory.appendingPathComponent("profiles.json") }

    /// v1's `profiles.json`. Throws when it can't be read, so it is never taken for no profiles.
    public static func decodeV1(_ data: Data) throws -> Profiles {
        // Paths saved before the app's folder was renamed.
        let migrated = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "~/.config/gpu-terminal/", with: "~/.config/bridge/")
        var profiles = try JSONDecoder().decode(Profiles.self, from: Data(migrated.utf8))
        profiles.normalize()
        return profiles
    }
}

// MARK: - JSON (v1's serde format)

extension Profiles: Codable {
    private enum Keys: String, CodingKey { case hosts, sandboxes, projectSandbox = "project_sandbox", vault, nextID = "next_id" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        hosts = try c.decodeIfPresent([SSHHost].self, forKey: .hosts) ?? []
        sandboxes = try c.decodeIfPresent([SandboxProfile].self, forKey: .sandboxes) ?? []
        projectSandbox = try c.decodeIfPresent(SandboxEngine.self, forKey: .projectSandbox)
        vault = try c.decodeIfPresent(VaultAccount.self, forKey: .vault)
        counter = try c.decodeIfPresent(ID.self, forKey: .nextID) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(hosts, forKey: .hosts)
        try c.encode(sandboxes, forKey: .sandboxes)
        try c.encodeIfPresent(projectSandbox, forKey: .projectSandbox)
        try c.encode(vault, forKey: .vault)
        try c.encode(counter, forKey: .nextID)
    }
}

extension SSHAuth: Codable {
    private enum Keys: String, CodingKey { case type, path, item, name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "key": self = .key(path: try c.decode(String.self, forKey: .path))
        case "password": self = .password
        case "vault": self = .vault(item: try c.decode(String.self, forKey: .item), name: try c.decode(String.self, forKey: .name))
        default: self = .agent
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .agent: try c.encode("agent", forKey: .type)
        case .key(let path):
            try c.encode("key", forKey: .type)
            try c.encode(path, forKey: .path)
        case .password: try c.encode("password", forKey: .type)
        case .vault(let item, let name):
            try c.encode("vault", forKey: .type)
            try c.encode(item, forKey: .item)
            try c.encode(name, forKey: .name)
        }
    }
}

extension Forward: Codable {
    private enum Keys: String, CodingKey { case id, name, kind, bind, target, showLogs = "show_logs", enabled }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(ID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try c.decodeIfPresent(ForwardKind.self, forKey: .kind) ?? .local
        bind = try c.decode(String.self, forKey: .bind)
        target = try c.decodeIfPresent(String.self, forKey: .target) ?? ""
        showLogs = try c.decodeIfPresent(Bool.self, forKey: .showLogs) ?? false
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encode(bind, forKey: .bind)
        try c.encode(target, forKey: .target)
        try c.encode(showLogs, forKey: .showLogs)
        try c.encode(enabled, forKey: .enabled)
    }
}

extension SSHHost: Codable {
    private enum Keys: String, CodingKey {
        case id, name, host, port, user, auth, keepaliveSecs = "keepalive_secs", onDisconnect = "on_disconnect", forwards
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(ID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? 22
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        auth = try c.decodeIfPresent(SSHAuth.self, forKey: .auth) ?? .agent
        keepaliveSecs = try c.decodeIfPresent(UInt32.self, forKey: .keepaliveSecs) ?? 30
        onDisconnect = try c.decodeIfPresent(OnDisconnect.self, forKey: .onDisconnect) ?? .nothing
        forwards = try c.decodeIfPresent([Forward].self, forKey: .forwards) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encode(user, forKey: .user)
        try c.encode(auth, forKey: .auth)
        try c.encode(keepaliveSecs, forKey: .keepaliveSecs)
        try c.encode(onDisconnect, forKey: .onDisconnect)
        try c.encode(forwards, forKey: .forwards)
    }
}

extension SandboxEngine: Codable {
    private enum Keys: String, CodingKey {
        case type, writable, hidden, network, blocked, blockKeychain = "block_keychain", confineReads = "confine_reads",
             readable, allowClipboard = "allow_clipboard", allowOpen = "allow_open", image, mounts, env
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "docker":
            self = .docker(Docker(
                image: try c.decode(String.self, forKey: .image),
                network: try c.decode(Bool.self, forKey: .network),
                mounts: try c.decode([String].self, forKey: .mounts),
                env: try c.decode([String].self, forKey: .env)))
        default:
            self = .seatbelt(Seatbelt(
                writable: try c.decode([String].self, forKey: .writable),
                hidden: try c.decode([String].self, forKey: .hidden),
                network: try c.decode(Network.self, forKey: .network),
                blocked: try c.decode([String].self, forKey: .blocked),
                blockKeychain: try c.decode(Bool.self, forKey: .blockKeychain),
                confineReads: try c.decodeIfPresent(Bool.self, forKey: .confineReads) ?? true,
                readable: try c.decodeIfPresent([String].self, forKey: .readable) ?? SandboxEngine.defaultReadable,
                allowClipboard: try c.decodeIfPresent(Bool.self, forKey: .allowClipboard) ?? false,
                allowOpen: try c.decodeIfPresent(Bool.self, forKey: .allowOpen) ?? false))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .seatbelt(let s):
            try c.encode("seatbelt", forKey: .type)
            try c.encode(s.writable, forKey: .writable)
            try c.encode(s.hidden, forKey: .hidden)
            try c.encode(s.network, forKey: .network)
            try c.encode(s.blocked, forKey: .blocked)
            try c.encode(s.blockKeychain, forKey: .blockKeychain)
            try c.encode(s.confineReads, forKey: .confineReads)
            try c.encode(s.readable, forKey: .readable)
            try c.encode(s.allowClipboard, forKey: .allowClipboard)
            try c.encode(s.allowOpen, forKey: .allowOpen)
        case .docker(let d):
            try c.encode("docker", forKey: .type)
            try c.encode(d.image, forKey: .image)
            try c.encode(d.network, forKey: .network)
            try c.encode(d.mounts, forKey: .mounts)
            try c.encode(d.env, forKey: .env)
        }
    }
}
