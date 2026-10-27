import Foundation

/// SSH sessions through the system OpenSSH client, so `~/.ssh/config`, `known_hosts` and agents
/// keep working. Saved passwords come from the Keychain through `bridge-helper` acting as
/// `SSH_ASKPASS`. A port of v1's `bridge-ssh`.
public struct SSHCommand: Equatable, Sendable {
    public var program = "ssh"
    public var arguments: [String]
    public var environment: [String: String]

    /// The variable naming the host whose saved password askpass answers with.
    public static let askpassHost = "BRIDGE_ASKPASS"

    /// Where a host's Vaultwarden key is served while the vault is unlocked.
    public struct VaultIdentity: Equatable, Sendable {
        public let socket: String
        public let publicKey: String

        public init(socket: String, publicKey: String) {
            self.socket = socket
            self.publicKey = publicKey
        }
    }

    /// An interactive session. `savedPassword` says whether the Keychain holds one.
    public static func interactive(_ host: SSHHost, savedPassword: Bool, vault: VaultIdentity?, helper: String?) -> SSHCommand {
        var command = base(host, savedPassword: savedPassword, vault: vault, helper: helper)
        command.arguments += ["--", host.destination]
        return command
    }

    /// A connection that only carries `forward` (`-N`), logging verbosely so its state can be read
    /// from stderr. With no terminal to answer prompts, unknown host keys are accepted the first
    /// time (a changed key is still refused) and, without a saved password, nothing may prompt.
    public static func forwarding(_ host: SSHHost, _ forward: Forward, savedPassword: Bool, vault: VaultIdentity?,
                                  helper: String?) -> SSHCommand {
        var command = base(host, savedPassword: savedPassword, vault: vault, helper: helper)
        let password = savedPassword && host.auth == .password
        for option in ["ExitOnForwardFailure=yes", "StrictHostKeyChecking=accept-new", "ConnectTimeout=15",
                       password ? "BatchMode=no" : "BatchMode=yes"] {
            command.arguments += ["-o", option]
        }
        command.arguments += ["-N", "-T", "-v"] + forward.sshFlag + ["--", host.destination]
        return command
    }

    /// Options shared by every connection to a host: port, keep-alives and how it signs in.
    static func base(_ host: SSHHost, savedPassword: Bool, vault: VaultIdentity?, helper: String?) -> SSHCommand {
        var args: [String] = []
        var env: [String: String] = [:]
        if host.port != 22 { args += ["-p", "\(host.port)"] }
        if host.keepaliveSecs > 0 {
            args += ["-o", "ServerAliveInterval=\(host.keepaliveSecs)", "-o", "ServerAliveCountMax=3"]
        }
        switch host.auth {
        case .agent:
            break
        case .key(let path):
            args += ["-i", Paths.expandHome(path), "-o", "IdentitiesOnly=yes"]
        case .vault:
            // Only the vault key is offered, from the app's agent (none while locked).
            if let vault {
                args += ["-o", "IdentityAgent=\(vault.socket)", "-i", vault.publicKey, "-o", "IdentitiesOnly=yes"]
            }
        case .password:
            args += ["-o", "PreferredAuthentications=keyboard-interactive,password"]
            if savedPassword, let helper {
                // One try: a wrong saved password mustn't be repeated until the server locks us out.
                args += ["-o", "NumberOfPasswordPrompts=1"]
                env["SSH_ASKPASS"] = helper
                env["SSH_ASKPASS_REQUIRE"] = "force"
                env[askpassHost] = "\(host.id)"
            }
        }
        return SSHCommand(arguments: args, environment: env)
    }

    /// The command line, for a terminal.
    public var commandLine: String {
        ([program] + arguments).map(Launch.quote).joined(separator: " ")
    }
}

/// Reading a forward's state from `ssh -v` output, and when to retry.
public enum ForwardLog {
    /// A line saying the forward works.
    public static func isUp(_ line: String) -> Bool {
        line.contains("forwarding listening on") || line.contains("remote forward success")
    }

    /// Why the connection ended: the last line of its final 50 that isn't debug output.
    public static func reason(lastLines: [String], exitCode: Int32?) -> String {
        let meaningful = lastLines.suffix(50).reversed().first { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("debug") && !trimmed.hasPrefix("$") && !trimmed.hasPrefix("ssh exited")
        }
        if let meaningful { return meaningful.trimmingCharacters(in: .whitespaces) }
        return exitCode.map { "exit code \($0)" } ?? "connection closed"
    }

    /// Seconds to wait before attempt `n` (from 0).
    public static func backoff(_ attempt: Int) -> Int {
        let steps = [1, 2, 5, 10, 30]
        return steps[min(attempt, steps.count - 1)]
    }

    /// A forward that stayed up this long starts counting attempts from zero again.
    public static let stableAfter: TimeInterval = 30
}
