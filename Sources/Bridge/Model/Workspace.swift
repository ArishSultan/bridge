import AppKit
import BridgeCore
import BridgeTerm
import Foundation
import Observation

/// One terminal pane: a libghostty surface plus what the chrome shows about it.
@MainActor
@Observable
final class Pane: Identifiable {
    let id = PaneID()
    @ObservationIgnored let surface: TerminalSurfaceView

    private(set) var title = ""
    private(set) var directory: String?
    private(set) var bell = false
    private(set) var hoveredLink: String?

    @ObservationIgnored weak var tab: Tab?

    init(surface: TerminalSurfaceView) {
        self.surface = surface
    }

    /// Copy the surface's state, after it reports a change.
    func refresh() {
        title = surface.title
        directory = surface.workingDirectory
        bell = surface.bell
        hoveredLink = surface.hoveredLink
    }

    /// What to call this pane: the program's title, else the folder it's in.
    var displayTitle: String {
        if !title.isEmpty { return title }
        if let directory {
            let url = URL(fileURLWithPath: directory)
            return url.path == FileManager.default.homeDirectoryForCurrentUser.path ? "~" : url.lastPathComponent
        }
        return "Terminal"
    }
}

/// A tab: panes arranged by a split tree.
@MainActor
@Observable
final class Tab: Identifiable {
    let id = UUID()
    private(set) var tree: SplitTree
    private(set) var panes: [PaneID: Pane]
    var focusedPaneID: PaneID
    /// The pane shown alone, filling the tab, if one is zoomed.
    var zoomedPaneID: PaneID?

    @ObservationIgnored weak var window: TerminalWindow?

    init(pane: Pane) {
        tree = SplitTree(pane: pane.id)
        panes = [pane.id: pane]
        focusedPaneID = pane.id
        pane.tab = self
    }

    var focusedPane: Pane? { panes[focusedPaneID] }
    var orderedPanes: [Pane] { tree.panes.compactMap { panes[$0] } }
    var title: String { focusedPane?.displayTitle ?? "Terminal" }
    var bell: Bool { panes.values.contains { $0.bell } }

    func split(_ paneID: PaneID, side: SplitDirection, with pane: Pane) {
        pane.tab = self
        panes[pane.id] = pane
        tree.split(paneID, direction: side, newPane: pane.id)
        zoomedPaneID = nil
        focusedPaneID = pane.id
    }

    /// Remove a pane; returns false if it was the last one (the tab should close).
    func remove(_ paneID: PaneID) -> Bool {
        let neighbor = tree.neighbor(of: paneID, .previous)
        guard tree.remove(paneID) else { return false }
        panes[paneID] = nil
        if zoomedPaneID == paneID { zoomedPaneID = nil }
        if focusedPaneID == paneID, let neighbor { focusedPaneID = neighbor }
        return true
    }

    func updateTree(_ change: (inout SplitTree) -> Void) {
        change(&tree)
    }
}

/// A window: a row of tabs, one shown at a time.
@MainActor
@Observable
final class TerminalWindow: Identifiable {
    let id: UUID
    private(set) var tabs: [Tab] = []
    var selectedTabID: UUID?

    @ObservationIgnored weak var nsWindow: NSWindow?

    init(id: UUID) {
        self.id = id
    }

    var selectedTab: Tab? { tabs.first { $0.id == selectedTabID } ?? tabs.first }

    func add(_ tab: Tab, after other: Tab? = nil) {
        tab.window = self
        if let other, let index = tabs.firstIndex(where: { $0 === other }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        selectedTabID = tab.id
    }

    /// Remove a tab, selecting its neighbor if it was selected. Returns false if none are left.
    func remove(_ tab: Tab) -> Bool {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return !tabs.isEmpty }
        tabs.remove(at: index)
        if selectedTabID == tab.id, !tabs.isEmpty {
            selectedTabID = tabs[min(index, tabs.count - 1)].id
        }
        return !tabs.isEmpty
    }

    func move(_ tab: Tab, by offset: Int) {
        guard let index = tabs.firstIndex(where: { $0 === tab }), tabs.count > 1 else { return }
        let target = ((index + offset) % tabs.count + tabs.count) % tabs.count
        tabs.remove(at: index)
        tabs.insert(tab, at: target)
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        tabs.move(fromOffsets: source, toOffset: destination)
    }
}
