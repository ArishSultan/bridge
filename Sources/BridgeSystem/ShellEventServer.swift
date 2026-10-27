import BridgeCore
import Darwin
import Foundation

/// The unix socket shells report to: prompts, commands, and (zsh) requests for suggestions.
///
/// A message is fields separated by U+001F and ended by a NUL byte. The first message on a
/// connection is `hello <pane token> <shell>`. A request that expects an answer gets one reply,
/// in the same format; requests carry a sequence number the reply starts with, so a late reply is
/// never taken for the answer to the next request.
///
/// The socket is in `Paths.runDirectory`, which sandboxes can't write: a sandboxed program can
/// connect (its shell reports here) but can't move the socket and listen in its place.
public final class ShellEventServer: @unchecked Sendable {
    public let path: String
    private let listener: Int32
    private let queue = DispatchQueue(label: "dev.arish.bridge.shell-events")
    private var acceptSource: DispatchSourceRead?
    private var connections: [Int32: ShellConnection] = [:]
    private let handler: @Sendable (ShellConnection, [String]) async -> String?

    /// A message longer than this ends its connection: nothing a shell sends comes close.
    static let maxRecord = 256 * 1024
    /// More connections than this are refused (each shell keeps one).
    static let maxConnections = 512

    /// Listen at a socket in a private folder for this user and app instance. `handler` runs on
    /// the main actor; what it returns is sent back as the reply.
    public init(handler: @escaping @MainActor @Sendable (ShellConnection, [String]) -> String?) throws {
        let dir = Paths.runDirectory
        try Paths.makePrivateDirectory(dir)
        Self.removeStaleSockets(in: dir)
        path = dir.appendingPathComponent("app-\(getpid()).sock").path
        unlink(path)
        self.handler = { connection, fields in await handler(connection, fields) }

        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, size) }
        }
        guard bound == 0, listen(listener, 64) == 0 else {
            close(listener)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        chmod(path, 0o600)
        _ = fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnections() }
        source.resume()
        acceptSource = source
    }

    deinit {
        acceptSource?.cancel()
        close(listener)
        unlink(path)
    }

    /// Remove the socket file (at quit).
    public func shutdown() {
        unlink(path)
    }

    /// Sockets left by app instances that are gone (after a crash).
    private static func removeStaleSockets(in dir: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where name.hasPrefix("app-") && name.hasSuffix(".sock") {
            guard let pid = Int32(name.dropFirst(4).dropLast(5)), pid != getpid() else { continue }
            if kill(pid, 0) != 0 && errno == ESRCH { unlink(dir.appendingPathComponent(name).path) }
        }
    }

    private func acceptConnections() {
        while true {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            guard connections.count < Self.maxConnections else {
                close(fd)
                continue
            }
            // Accepted sockets inherit the listener's non-blocking mode; replies are written
            // whole, so block (with a time limit, for a shell that stops reading).
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            var limit = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let connection = ShellConnection(fd: fd)
            connections[fd] = connection
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.read(connection) }
            source.setCancelHandler { close(fd) }
            connection.source = source
            source.resume()
        }
    }

    private func read(_ connection: ShellConnection) {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        let count = Darwin.read(connection.fd, &chunk, chunk.count)
        guard count > 0 else {
            connections[connection.fd] = nil
            connection.source?.cancel()
            let handler = handler
            Task { _ = await handler(connection, ["closed"]) }
            return
        }
        connection.buffer.append(contentsOf: chunk[0..<count])
        if connection.buffer.count > Self.maxRecord, !connection.buffer.contains(0) {
            connections[connection.fd] = nil
            connection.source?.cancel()
            return
        }
        while let end = connection.buffer.firstIndex(of: 0) {
            let record = connection.buffer[connection.buffer.startIndex..<end]
            connection.buffer.removeSubrange(connection.buffer.startIndex...end)
            let fields = String(decoding: record, as: UTF8.self).split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            if fields.first == "hello", fields.count >= 3 {
                connection.paneToken = fields[1]
                connection.shell = fields[2]
            }
            // Messages are handled in order: wait for each before the next, and reply if asked.
            let handler = handler
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                if let reply = await handler(connection, fields) {
                    connection.send(reply)
                }
                semaphore.signal()
            }
            semaphore.wait()
        }
    }
}

/// One shell's connection.
public final class ShellConnection: @unchecked Sendable {
    let fd: Int32
    var buffer: [UInt8] = []
    var source: DispatchSourceRead?
    /// The pane the shell runs in, from its hello.
    public internal(set) var paneToken: String?
    public internal(set) var shell: String?

    init(fd: Int32) {
        self.fd = fd
    }

    /// Write a reply whole (a short write would leave the shell waiting for the rest).
    func send(_ text: String) {
        var bytes = Array(text.utf8)
        bytes.append(0)
        bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }
}

/// The message fields, joined for the wire.
public enum ShellMessage {
    public static func encode(_ fields: [String]) -> [UInt8] {
        Array(fields.joined(separator: "\u{1F}").utf8) + [0]
    }
}
