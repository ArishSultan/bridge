import AppKit
import BridgeCore
import Observation
import SwiftUI
import BridgeTerm

/// One project window's state and commands: sheets, confirmations, renaming, and the menu
/// commands that act on the window in front.
@MainActor
@Observable
final class WindowController {
    let projectID: ID
    @ObservationIgnored weak var window: NSWindow?

    /// The New/Edit Terminal sheet.
    var terminalSheet: TerminalSheetRequest?
    var showProjectSheet = false
    /// The command history sheet, for this pane.
    var historyPane: ID?
    /// Switching away would stop these running terminals: asks Keep alive / Stop and switch.
    var pendingSwitch: (target: ID, stopping: [ID])?
    /// The item, pane or project being renamed inline.
    var renaming: RenameTarget?
    var confirmDeleteItem: ID?
    var confirmRemoveProject = false
    /// Identifies a sheet's subject (SSH sheets: a host, 0 new; a forward's log).
    struct Sheet: Identifiable {
        let id: ID
    }

    struct ForwardTarget: Identifiable {
        let host: ID
        let forward: ID
        var id: String { "\(host)-\(forward)" }
    }

    /// A sandbox profile to edit.
    struct SandboxTarget: Identifiable {
        /// nil: the Project sandbox; 0: a new profile.
        let profile: ID?
        var id: String { profile.map(String.init) ?? "project" }
    }
    var toast: String?

    enum RenameTarget: Equatable {
        case item(ID)
        case pane(ID)
        case project
    }

    private var store: Store { .shared }

    init(projectID: ID) {
        self.projectID = projectID
    }

    var project: Project? { store.project(projectID) }
    var isGlobal: Bool { store.isGlobal(projectID) }

    /// The focused pane's terminal, when it is running.
    var focusedSurface: TerminalSurfaceView? {
        focusedPane.flatMap { store.sessions[$0]?.surface }
    }

    /// The pane with focus in the item on screen.
    var focusedPane: ID? {
        guard let project, let active = project.active, let view = project.view(active) else { return nil }
        return view.focused ?? view.panes.first
    }

    // MARK: - Items

    /// Show another item, asking first if that would stop running terminals.
    func select(_ item: ID) {
        guard let project, project.active != item else { return }
        let stopping = store.stoppingOnLeave(projectID)
        if stopping.isEmpty {
            store.activate(projectID, item: item)
        } else {
            pendingSwitch = (item, stopping)
        }
    }

    func confirmSwitch(keepAlive: Bool) {
        guard let pending = pendingSwitch else { return }
        pendingSwitch = nil
        if keepAlive { store.setKeepAlive(projectID, panes: pending.stopping, true) }
        store.activate(projectID, item: pending.target)
    }

    func cycleItems(_ offset: Int) {
        if let next = project?.cycleView(offset) { select(next) }
    }

    func goToItem(_ index: Int) {
        guard let views = project?.views, index < views.count else { return }
        select(views[index].id)
    }

    // MARK: - Terminals

    /// ⌘T: a shell right away, sandboxed in the project (in the Home window, where there is no
    /// project to confine it to, open). Every other kind of terminal is made with the sheet.
    func newShell() {
        store.addItem(projectID, spec: TerminalSpec(isolation: isGlobal ? .open : .sandboxed(profile: nil)))
    }

    /// ⌘⇧T, ⌘⇧E: the New Terminal sheet with a preset.
    func newTerminal(_ preset: TerminalSheetRequest.Preset) {
        terminalSheet = TerminalSheetRequest(mode: .newItem, preset: preset)
    }

    /// ⌘D / ⌘⇧D: a shell beside the focused terminal right away, like it (same folder and
    /// isolation).
    func split(_ axis: SplitAxis) {
        guard let project else { return }
        guard let pane = focusedPane, let spec = project.terminal(pane) else {
            newShell()
            return
        }
        store.addPane(projectID, spec: spec.forSplit, axis: axis, nextTo: pane)
    }

    func edit(_ pane: ID) {
        guard let spec = project?.terminal(pane) else { return }
        terminalSheet = TerminalSheetRequest(mode: .edit(pane: pane), preset: .spec(spec))
    }

    /// Save the terminal sheet.
    func commit(_ request: TerminalSheetRequest, spec: TerminalSpec) {
        switch request.mode {
        case .newItem:
            store.addItem(projectID, spec: spec)
        case .split(let axis, let nextTo):
            store.addPane(projectID, spec: spec, axis: axis, nextTo: nextTo)
        case .edit(let pane):
            store.updateSpec(projectID, pane: pane) { $0 = spec }
        }
    }

    /// ⌘W: close the focused terminal of a view, or the terminal on screen; the window stays.
    /// It can be undone (the terminal comes back, started again). A program that is busy (not at
    /// a shell prompt) asks first.
    func closeFocused() {
        guard let project, let pane = focusedPane, let view = project.view(ofPane: pane) else {
            window?.performClose(nil)
            return
        }
        let close = { [self] in
            if view.single == nil {
                store.closePane(projectID, pane: pane, undo: window?.undoManager)
            } else {
                store.deleteItem(projectID, item: view.id, undo: window?.undoManager)
            }
        }
        guard let session = store.sessions[pane], session.status.isRunning, !session.atPrompt else {
            close()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Close “\(store.label(of: pane, in: project) ?? "Terminal")”?"
        alert.informativeText = "A program is still running in it; closing stops it."
        alert.addButton(withTitle: "Stop and Close")
        alert.addButton(withTitle: "Cancel")
        guard let window else { return }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { close() }
        }
    }

    func focusNeighbor(of pane: ID, _ direction: BridgeCore.Layout.Focus) -> Bool {
        guard let view = project?.view(ofPane: pane),
              let target = view.layout.neighbor(of: pane, direction)
        else { return false }
        focus(target)
        return true
    }

    func focus(_ pane: ID) {
        store.setFocused(projectID, pane: pane)
        if let surface = store.sessions[pane]?.surface {
            surface.window?.makeFirstResponder(surface)
        }
    }

    func cyclePanes(_ offset: Int) {
        guard let pane = focusedPane else { return }
        _ = focusNeighbor(of: pane, offset > 0 ? .next : .previous)
    }

    func equalize() {
        guard let active = project?.active else { return }
        store.updateLayout(projectID, item: active) { $0 = $0.equalized() }
    }
}

/// What the terminal sheet is for, and what it starts with.
struct TerminalSheetRequest: Identifiable {
    enum Mode {
        case newItem
        case split(axis: SplitAxis, nextTo: ID)
        case edit(pane: ID)
    }

    enum Preset {
        case shell
        case openShell
        case task
        case spec(TerminalSpec)
    }

    let id = UUID()
    let mode: Mode
    let preset: Preset

    var isEdit: Bool { if case .edit = mode { true } else { false } }
}

/// Lets a window ask before it closes, without replacing the delegate SwiftUI installed: it
/// answers `windowShouldClose` and passes every other message on.
final class WindowCloseGuard: NSObject, NSWindowDelegate {
    private weak var original: NSWindowDelegate?
    private let shouldClose: (NSWindow) -> Bool
    private let willClose: () -> Void

    init(window: NSWindow, shouldClose: @escaping (NSWindow) -> Bool, willClose: @escaping () -> Void) {
        original = window.delegate
        self.shouldClose = shouldClose
        self.willClose = willClose
        super.init()
        window.delegate = self
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard shouldClose(sender) else { return false }
        return original?.windowShouldClose?(sender) ?? true
    }

    func windowWillClose(_ notification: Notification) {
        willClose()
        original?.windowWillClose?(notification)
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
    }
}
