import Darwin
import Foundation

// bridge-helper: small jobs Bridge runs as separate processes.
//
//   bridge-helper send <socket> <fields…> [-- <fields…>]…
//       Deliver messages to the app's shell socket (for bash, which has no unix sockets).

let arguments = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("bridge-helper: \(message)\n".utf8))
    exit(1)
}

/// Connect to a unix socket and write each message (fields joined by U+001F, ended by NUL).
func send(socketPath: String, messages: [[String]]) {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { exit(1) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(socketPath.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { exit(1) }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { exit(1) }
    for message in messages {
        var data = Array(message.joined(separator: "\u{1F}").utf8)
        data.append(0)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }
    close(fd)
}

switch arguments.first {
case "send":
    guard arguments.count >= 3 else { fail("usage: send <socket> <fields…> [-- <fields…>]") }
    var messages: [[String]] = [[]]
    for argument in arguments.dropFirst(2) {
        if argument == "--" {
            messages.append([])
        } else {
            messages[messages.count - 1].append(argument)
        }
    }
    send(socketPath: arguments[1], messages: messages.filter { !$0.isEmpty })
default:
    fail("unknown command")
}
