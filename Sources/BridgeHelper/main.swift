import Darwin
import Foundation

// bridge-helper: small jobs Bridge runs as separate processes.
//
//   bridge-helper send <socket> <fields…> [-- <fields…>]…
//       Deliver messages to the app's shell socket (for bash, which has no unix sockets).
//   bridge-helper guard <program> <args…>
//       Run a program and end it when the app goes away (port forwards, the vault's ssh-agent).
//   SSH_ASKPASS mode, when BRIDGE_ASKPASS is set (ssh runs us with its prompt):
//       answer password prompts with the host's saved password, asked from the app; ask on the
//       terminal for anything else (host keys, passphrases, codes).

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("bridge-helper: \(message)\n".utf8))
    exit(1)
}

/// Connect to the app's unix socket.
func connectSocket(_ path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else {
        close(fd)
        return nil
    }
    return fd
}

/// Write a message: fields joined by U+001F, ended by NUL.
func write(_ fd: Int32, _ fields: [String]) {
    var data = Array(fields.joined(separator: "\u{1F}").utf8)
    data.append(0)
    _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
}

/// Read one reply, up to its NUL.
func readReply(_ fd: Int32) -> String? {
    var reply: [UInt8] = []
    var byte: UInt8 = 0
    while Darwin.read(fd, &byte, 1) == 1 {
        if byte == 0 { return String(decoding: reply, as: UTF8.self) }
        reply.append(byte)
    }
    return nil
}

// MARK: - askpass

/// Ask on the controlling terminal; without echo unless it's a yes/no question.
func askTerminal(_ prompt: String) -> String? {
    let tty = open("/dev/tty", O_RDWR)
    guard tty >= 0 else { return nil }
    defer { close(tty) }
    _ = prompt.withCString { Darwin.write(tty, $0, strlen($0)) }
    let echo = prompt.lowercased().contains("yes/no")
    var saved = termios()
    tcgetattr(tty, &saved)
    if !echo {
        var quiet = saved
        quiet.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(tty, TCSANOW, &quiet)
    }
    defer {
        if !echo {
            tcsetattr(tty, TCSANOW, &saved)
            _ = Darwin.write(tty, "\n", 1)
        }
    }
    var line: [UInt8] = []
    var byte: UInt8 = 0
    while Darwin.read(tty, &byte, 1) == 1, byte != UInt8(ascii: "\n") {
        if byte != UInt8(ascii: "\r") { line.append(byte) }
    }
    return String(decoding: line, as: UTF8.self)
}

func askpass(host: String) -> Never {
    let prompt = CommandLine.arguments.dropFirst().first ?? ""
    let lowered = prompt.lowercased()
    let env = ProcessInfo.processInfo.environment
    if lowered.contains("password") && !lowered.contains("yes/no"),
       let socketPath = env["BRIDGE_ASKPASS_SOCKET"], let nonce = env["BRIDGE_ASKPASS_NONCE"],
       let fd = connectSocket(socketPath) {
        // The app answers only with the nonce it gave this ssh, so nothing else can ask.
        write(fd, ["askpass", nonce, host])
        let reply = readReply(fd)
        close(fd)
        if let reply, !reply.isEmpty {
            print(reply)
            exit(0)
        }
    }
    guard let answer = askTerminal(prompt) else { exit(1) }
    print(answer)
    exit(0)
}

// MARK: - guard

nonisolated(unsafe) var guardedChild: pid_t = 0

/// Run a program; end it if the app (our parent) goes away or asks us to stop.
func runGuarded(_ program: [String]) -> Never {
    let parent = getppid()
    // Already re-parented to launchd: whoever started us is gone.
    guard parent != 1 else { exit(1) }
    var pid: pid_t = 0
    var argv = program.map { strdup($0) } + [nil]
    let status = posix_spawnp(&pid, program[0], nil, nil, &argv, environ)
    guard status == 0 else { exit(127) }
    guardedChild = pid
    // Stopping the guard stops what it runs.
    for sig in [SIGTERM, SIGINT, SIGHUP] {
        signal(sig) { sig in
            kill(guardedChild, SIGTERM)
            _exit(128 + sig)
        }
    }
    while true {
        var childStatus: Int32 = 0
        let result = waitpid(pid, &childStatus, WNOHANG)
        if result == pid {
            if (childStatus & 0x7f) == 0 { exit((childStatus >> 8) & 0xff) }
            exit(1)
        }
        if getppid() != parent {
            // Re-parented to launchd: the app is gone.
            kill(pid, SIGTERM)
            exit(1)
        }
        usleep(500_000)
    }
}

// MARK: - main

let arguments = Array(CommandLine.arguments.dropFirst())

if let host = ProcessInfo.processInfo.environment["BRIDGE_ASKPASS"] {
    askpass(host: host)
}

switch arguments.first {
case "send":
    guard arguments.count >= 3, let fd = connectSocket(arguments[1]) else { exit(1) }
    var messages: [[String]] = [[]]
    for argument in arguments.dropFirst(2) {
        if argument == "--" {
            messages.append([])
        } else {
            messages[messages.count - 1].append(argument)
        }
    }
    for message in messages where !message.isEmpty { write(fd, message) }
    close(fd)
case "guard":
    guard arguments.count >= 2 else { fail("usage: guard <program> <args…>") }
    runGuarded(Array(arguments.dropFirst()))
default:
    fail("unknown command")
}
