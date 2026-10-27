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
        /// Stopped by hand (or by leaving its item).
        case stopped

        var isRunning: Bool { self == .running }
    }

    let id: ID
    let projectID: ID
    private(set) var surface: TerminalSurfaceView?
    var status: Status = .notStarted

    private(set) var title = ""
    private(set) var directory: String?
    private(set) var hoveredLink: String?
    /// The bell rang or a long command finished while this pane was out of sight.
    var needsAttention = false
    /// Set when the user stopped it, so exiting doesn't restart or reconnect it.
    @ObservationIgnored var stoppedByHand = false
    @ObservationIgnored var restartTask: Task<Void, Never>?

    init(id: ID, projectID: ID) {
        self.id = id
        self.projectID = projectID
    }

    func attach(_ surface: TerminalSurfaceView) {
        self.surface = surface
        status = .running
        stoppedByHand = false
        title = ""
        surface.onChange = { [weak self] in self?.refresh() }
    }

    /// End the program and drop the surface.
    func detach(status: Status) {
        restartTask?.cancel()
        surface?.onChange = nil
        surface?.onFocus = nil
        surface?.interceptKey = nil
        surface?.removeFromSuperview()
        surface = nil
        self.status = status
    }

    private func refresh() {
        guard let surface else { return }
        title = surface.title
        directory = surface.workingDirectory
        hoveredLink = surface.hoveredLink
        if surface.bell { needsAttention = true }
    }
}
