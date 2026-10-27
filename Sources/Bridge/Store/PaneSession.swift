import AppKit
import BridgeCore
import BridgeTerm
import Observation

/// A terminal pane while the app runs: its libghostty surface (when started) and what the window
/// shows about it.
@MainActor
@Observable
final class PaneSession: Identifiable {
    enum Status: Equatable {
        /// A task waiting for ▶.
        case notStarted
        case running
        /// The program exited on its own; its output stays on screen.
        case exited(code: Int?)
        // When it exited is in `endedAt`, how long it ran from `startedAt`.
        /// Stopped by hand (or by leaving its item).
        case stopped

        var isRunning: Bool { self == .running }
    }

    let id: ID
    let projectID: ID
    private(set) var surface: TerminalSurfaceView?
    var status: Status = .notStarted {
        didSet {
            if case .exited = status, endedAt == nil { endedAt = Date() }
        }
    }
    /// When the program started, and when it exited (for the exit bar).
    private(set) var startedAt: Date?
    private(set) var endedAt: Date?

    private(set) var title = ""
    private(set) var directory: String?
    private(set) var hoveredLink: String?
    /// The bell rang or a long command finished while this pane was out of sight.
    var needsAttention = false
    /// Set when the user stopped it, so exiting doesn't restart or reconnect it.
    @ObservationIgnored var stoppedByHand = false
    @ObservationIgnored var restartTask: Task<Void, Never>?

    // Reported by the shell integration.
    /// Identifies this pane's shell on the app's socket.
    @ObservationIgnored var token: String?
    /// The shell is waiting at its prompt (not running a command).
    var atPrompt = false
    /// The command running now, its folder and when it started.
    @ObservationIgnored var running: (command: String, cwd: String, started: Date)?
    /// The shell's PATH, for completing command names.
    @ObservationIgnored var path: String?
    /// The shell's folder, as last reported.
    @ObservationIgnored var shellDirectory: String?
    /// The Docker container this pane runs in, removed when it stops.
    @ObservationIgnored var dockerContainer: String?
    /// Reconnecting an SSH session that dropped.
    @ObservationIgnored var reconnectAttempts = 0
    @ObservationIgnored var lastReconnect: Date?
    /// A folder was just completed: offer what's inside once the shell shows it.
    @ObservationIgnored var reopenMenu = false

    init(id: ID, projectID: ID) {
        self.id = id
        self.projectID = projectID
    }

    func attach(_ surface: TerminalSurfaceView) {
        self.surface = surface
        startedAt = Date()
        endedAt = nil
        status = .running
        stoppedByHand = false
        title = ""
        surface.onChange = { [weak self] in self?.refresh() }
    }

    /// End the program and drop the surface.
    func detach(status: Status) {
        restartTask?.cancel()
        if let container = dockerContainer {
            // Closing the terminal leaves the container running otherwise.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["docker", "rm", "-f", container]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            dockerContainer = nil
        }
        atPrompt = false
        running = nil
        surface?.onChange = nil
        surface?.onFocus = nil
        surface?.interceptKey = nil
        surface?.removeFromSuperview()
        surface = nil
        self.status = status
    }

    /// The shell reported its folder.
    func report(directory: String) {
        shellDirectory = directory
        self.directory = directory
    }

    private func refresh() {
        guard let surface else { return }
        title = surface.title
        directory = surface.workingDirectory ?? shellDirectory
        hoveredLink = surface.hoveredLink
        if surface.bell { needsAttention = true }
    }
}
