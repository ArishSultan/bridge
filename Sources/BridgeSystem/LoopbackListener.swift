import Darwin
import Foundation

/// A one-time HTTP listener on `localhost`, for a sign-in in the browser to come back to: the
/// browser is sent to `http://localhost:<port>/?code=…&state=…`, this answers with a page saying
/// it can be closed, and hands over the query. Listens on 127.0.0.1 and ::1 (browsers try either
/// for `localhost`), on the first free port of a range.
final class LoopbackListener: @unchecked Sendable {
    let port: UInt16
    private var sockets: [Int32] = []

    init(ports: ClosedRange<UInt16>) throws {
        for port in ports {
            guard let v4 = Self.listen(port: port, v6: false) else { continue }
            sockets = [v4]
            if let v6 = Self.listen(port: port, v6: true) { sockets.append(v6) }
            self.port = port
            return
        }
        throw VaultClient.Failure.rejected(
            "Ports \(ports.lowerBound)–\(ports.upperBound) on this Mac are all in use, so single sign-on can't come back to Bridge. Close the Bitwarden CLI or other sign-ins and try again.")
    }

    deinit { close() }

    func close() {
        for fd in sockets { Darwin.close(fd) }
        sockets = []
    }

    /// Wait for the browser to come back with a query that has a `code` or an `error`; other
    /// requests (a favicon) get a 404.
    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        let sockets = sockets
        return try await withTaskCancellationHandler {
            try await Task.detached {
                let deadline = Date().addingTimeInterval(timeout)
                while Date() < deadline {
                    try Task.checkCancellation()
                    var fds = sockets.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
                    guard poll(&fds, nfds_t(fds.count), 500) > 0 else { continue }
                    for entry in fds where entry.revents & Int16(POLLIN) != 0 {
                        let client = accept(entry.fd, nil, nil)
                        guard client >= 0 else { continue }
                        defer { Darwin.close(client) }
                        if let query = Self.serve(client) { return query }
                    }
                }
                throw VaultClient.Failure.rejected("Single sign-on didn't come back within five minutes. Try again.")
            }.value
        } onCancel: {
            for fd in sockets { shutdown(fd, SHUT_RDWR) }
        }
    }

    /// Read one request; answer it, and return its query when it's the sign-in coming back.
    private static func serve(_ client: Int32) -> [String: String]? {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while request.count < 64 * 1024, !request.contains(Data("\r\n\r\n".utf8)) {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { break }
            request.append(contentsOf: buffer[0..<count])
        }
        let line = String(decoding: request.prefix { $0 != UInt8(ascii: "\r") }, as: UTF8.self)
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let components = URLComponents(string: "http://localhost" + parts[1])
        else {
            respond(client, status: "400 Bad Request", body: "")
            return nil
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        guard query["code"] != nil || query["error"] != nil else {
            respond(client, status: "404 Not Found", body: "")
            return nil
        }
        let failed = query["error"] != nil
        respond(client, status: "200 OK", body: """
            <!doctype html><meta charset="utf-8"><title>Bridge</title>
            <style>body{font:16px -apple-system,sans-serif;display:grid;place-items:center;height:90vh;color:#333}
            @media(prefers-color-scheme:dark){body{background:#1e1e1e;color:#ddd}}</style>
            <div><h2>\(failed ? "Single sign-on failed" : "Signed in")</h2>
            <p>\(failed ? "Go back to Bridge to see why." : "You can close this tab and go back to Bridge.")</p></div>
            """)
        return query
    }

    private static func respond(_ client: Int32, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n" + body
        _ = response.withCString { write(client, $0, strlen($0)) }
    }

    /// A listening socket on the loopback address, or nil when the port is taken.
    private static func listen(port: UInt16, v6: Bool) -> Int32? {
        let fd = socket(v6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        let bound: Int32
        if v6 {
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            address.sin6_addr = in6addr_loopback
            bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }
}
