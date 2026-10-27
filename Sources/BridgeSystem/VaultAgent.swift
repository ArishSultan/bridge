import Foundation

/// A private `ssh-agent` holding the vault's SSH keys in memory, for as long as the vault is
/// unlocked. Hosts that sign in with a vault key point ssh at its socket (`IdentityAgent`) and
/// at the key's public half (`-i`). Ported from v1.
public final class VaultAgent: @unchecked Sendable {
    public let directory: URL
    public let socket: String
    private let process: Process

    /// Start the agent (under the helper's guard, so it ends with the app).
    public init(helper: String?) throws {
        let name = "bridge-vault-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        socket = directory.appendingPathComponent("agent.sock").path

        process = Process()
        if let helper {
            process.executableURL = URL(fileURLWithPath: helper)
            process.arguments = ["guard", "/usr/bin/ssh-agent", "-D", "-a", socket]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-agent")
            process.arguments = ["-D", "-a", socket]
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        for _ in 0..<50 where !FileManager.default.fileExists(atPath: socket) {
            usleep(40_000)
        }
        guard FileManager.default.fileExists(atPath: socket) else {
            stop()
            throw VaultClient.Failure.rejected("ssh-agent did not start")
        }
    }

    deinit { stop() }

    /// Load a private key; returns the path of its public half.
    public func add(id: String, privateKey: String) throws -> String {
        let before = Set(publicKeys())
        var key = Data(privateKey.utf8)
        if key.last != UInt8(ascii: "\n") { key.append(UInt8(ascii: "\n")) }
        defer { key.resetBytes(in: 0..<key.count) }

        let add = Process()
        add.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
        add.arguments = ["-q", "-"]
        add.environment = ["SSH_AUTH_SOCK": socket, "PATH": "/usr/bin:/bin"]
        let input = Pipe()
        let errors = Pipe()
        add.standardInput = input
        add.standardOutput = FileHandle.nullDevice
        add.standardError = errors
        try add.run()
        input.fileHandleForWriting.write(key)
        try input.fileHandleForWriting.close()
        add.waitUntilExit()
        guard add.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw VaultClient.Failure.rejected(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "ssh-add refused the key" : message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // The new line in the agent's list is this key's public half.
        guard let line = publicKeys().first(where: { !before.contains($0) }) else {
            throw VaultClient.Failure.rejected("the key is already loaded")
        }
        let safe = String(id.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
        let path = directory.appendingPathComponent("\(safe).pub").path
        try (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func publicKeys() -> [String] {
        let list = Process()
        list.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
        list.arguments = ["-L"]
        list.environment = ["SSH_AUTH_SOCK": socket, "PATH": "/usr/bin:/bin"]
        let output = Pipe()
        list.standardOutput = output
        list.standardError = FileHandle.nullDevice
        guard (try? list.run()) != nil else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        list.waitUntilExit()
        guard list.terminationStatus == 0 else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// End the agent (its keys go with it) and remove its folder.
    public func stop() {
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: directory)
    }
}
