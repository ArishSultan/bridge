import Darwin
import Foundation

// bridge-helper: small jobs Bridge runs as separate processes.
//
//   bridge-helper send <socket> <fields…> [-- <fields…>]…
//       Deliver messages to the app's shell socket (for bash, which has no unix sockets).
//   bridge-helper pane <socket> <token> -- <program> <args…>
//       Tell the app which process a terminal runs (this one: it then becomes the program, with
//       the same pid), for its monitor.
//   bridge-helper sandbox <policy> <program> <args…>
//       Run a program in a Seatbelt sandbox, after putting the terminal it runs in (stdin's tty)
//       into the policy where it says @BRIDGE_TTY@.
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

/// Ask on the controlling terminal; without echo unless it's a yes/no question. `readpassphrase`
/// puts the terminal back as it was even when interrupted (⌃C).
func askTerminal(_ prompt: String) -> String? {
    let echo = prompt.lowercased().contains("yes/no")
    var buffer = [CChar](repeating: 0, count: 1024)
    defer { for index in buffer.indices { buffer[index] = 0 } }
    let flags = RPP_REQUIRE_TTY | (echo ? RPP_ECHO_ON : RPP_ECHO_OFF)
    guard readpassphrase(prompt, &buffer, buffer.count, flags) != nil else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// The command line of a process (same user only).
func arguments(of pid: pid_t) -> [String] {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
    let count = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
    // argc, the executable path, padding NULs, then argv.
    var index = MemoryLayout<Int32>.size
    while index < size, buffer[index] != 0 { index += 1 }
    while index < size, buffer[index] == 0 { index += 1 }
    var args: [String] = []
    while args.count < Int(count), index < size {
        let start = index
        while index < size, buffer[index] != 0 { index += 1 }
        args.append(String(decoding: buffer[start..<index], as: UTF8.self))
        index += 1
    }
    return args
}

func askpass(host: String) -> Never {
    let prompt = CommandLine.arguments.dropFirst().first ?? ""
    let lowered = prompt.lowercased()
    let env = ProcessInfo.processInfo.environment
    // ssh starts another ssh for a jump host (`ProxyJump`), with `-W`; it inherits this
    // environment, but its prompt is for the jump host, which must not get this host's password.
    let forJumpHost = arguments(of: getppid()).contains("-W")
    if lowered.contains("password") && !lowered.contains("yes/no") && !forJumpHost,
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

/// Run a program in a process group of its own; end the group if the app (our parent) goes away
/// or asks us to stop.
func runGuarded(_ program: [String]) -> Never {
    let parent = getppid()
    // Already re-parented to launchd: whoever started us is gone.
    guard parent != 1 else { exit(1) }
    // Watch the parent before anything else, so its end can't be missed.
    let queue = kqueue()
    var watch = kevent(ident: UInt(parent), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                       fflags: NOTE_EXIT, data: 0, udata: nil)
    guard queue >= 0, kevent(queue, &watch, 1, nil, 0, nil) == 0, getppid() == parent else { exit(1) }

    // Signals wait until the child exists, so stopping us right after the spawn still stops it.
    var signals = sigset_t()
    sigemptyset(&signals)
    for sig in [SIGTERM, SIGINT, SIGHUP] { sigaddset(&signals, sig) }
    sigprocmask(SIG_BLOCK, &signals, nil)

    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK))
    posix_spawnattr_setpgroup(&attributes, 0)
    var unblocked = sigset_t()
    sigemptyset(&unblocked)
    posix_spawnattr_setsigmask(&attributes, &unblocked)
    var pid: pid_t = 0
    var argv = program.map { strdup($0) } + [nil]
    let status = posix_spawnp(&pid, program[0], nil, &attributes, &argv, environ)
    guard status == 0 else { exit(127) }

    // Stopping the guard stops what it runs, and everything that started (ssh's ProxyCommand).
    for sig in [SIGTERM, SIGINT, SIGHUP] {
        var event = kevent(ident: UInt(sig), filter: Int16(EVFILT_SIGNAL), flags: UInt16(EV_ADD), fflags: 0, data: 0, udata: nil)
        kevent(queue, &event, 1, nil, 0, nil)
    }
    var child = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                       fflags: NOTE_EXIT, data: 0, udata: nil)
    kevent(queue, &child, 1, nil, 0, nil)

    func reap() -> Int32? {
        var childStatus: Int32 = 0
        guard waitpid(pid, &childStatus, WNOHANG) == pid else { return nil }
        return (childStatus & 0x7f) == 0 ? (childStatus >> 8) & 0xff : 1
    }
    // The child may already have exited before its watch was added.
    if let code = reap() { exit(code) }
    while true {
        var event = kevent()
        guard kevent(queue, nil, 0, &event, 1, nil) == 1 else { continue }
        if event.filter == Int16(EVFILT_PROC) && event.ident == UInt(pid) {
            if let code = reap() { exit(code) }
            continue
        }
        // The app is gone, or asked us to stop.
        killpg(pid, SIGTERM)
        exit(event.filter == Int16(EVFILT_SIGNAL) ? 128 + Int32(event.ident) : 1)
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
case "pane":
    guard arguments.count >= 5, arguments[3] == "--" else { fail("usage: pane <socket> <token> -- <program> <args…>") }
    if let fd = connectSocket(arguments[1]) {
        write(fd, ["pid", arguments[2], "\(getpid())"])
        close(fd)
    }
    let program = Array(arguments.dropFirst(4))
    var cArgs = program.map { strdup($0) } + [nil]
    execvp(program[0], &cArgs)
    fail("could not start \(program[0]): \(String(cString: strerror(errno)))")
case "sandbox":
    guard arguments.count >= 3 else { fail("usage: sandbox <policy> <program> <args…>") }
    // No terminal: a path no tty has, so none is allowed.
    let tty = ttyname(0).map { String(cString: $0) } ?? "/dev/null"
    let quoted = "\"" + tty.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    let policy = arguments[1].replacingOccurrences(of: "\"@BRIDGE_TTY@\"", with: quoted)
    let argv = ["sandbox-exec", "-p", policy] + arguments.dropFirst(2)
    var cArgs = argv.map { strdup($0) } + [nil]
    execv("/usr/bin/sandbox-exec", &cArgs)
    fail("could not start sandbox-exec: \(String(cString: strerror(errno)))")
case "guard":
    guard arguments.count >= 2 else { fail("usage: guard <program> <args…>") }
    runGuarded(Array(arguments.dropFirst()))
default:
    fail("unknown command")
}
