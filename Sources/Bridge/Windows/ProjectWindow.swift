import AppKit
import BridgeCore
import SwiftUI

/// A project's window (or the Global window): its items in the sidebar, the item on screen in
/// the detail area, and its controls in the toolbar.
struct ProjectWindow: View {
    let projectID: ID

    @State private var controller: WindowController
    @State private var closeGuard: WindowCloseGuard?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    private var store: Store { .shared }

    init(projectID: ID) {
        self.projectID = projectID
        _controller = State(initialValue: WindowController(projectID: projectID))
    }

    var body: some View {
        if let project = store.project(projectID) {
            content(project)
        } else {
            ContentUnavailableView("This project was removed", systemImage: "folder.badge.minus")
        }
    }

    private func content(_ project: Project) -> some View {
        NavigationSplitView(columnVisibility: sidebarVisibility) {
            Sidebar(project: project, controller: controller)
                .navigationSplitViewColumnWidth(min: 200, ideal: 248, max: 360)
        } detail: {
            detail(project)
        }
        .navigationTitle(project.name)
        .navigationSubtitle(controller.isGlobal ? "" : Paths.tilde(project.root.path))
        .toolbar { ProjectToolbar(project: project, controller: controller) }
        .focusedSceneValue(\.windowController, controller)
        .sheet(item: $controller.terminalSheet) { request in
            TerminalSheet(project: project, request: request, global: controller.isGlobal) { spec in
                controller.commit(request, spec: spec)
            }
        }
        .sheet(isPresented: $controller.showProjectSheet) {
            ProjectSheet(project: project)
        }
        .sheet(item: historyTarget) { target in
            HistorySheet(pane: target.id)
        }
        .confirmationDialog(
            switchTitle, isPresented: pendingSwitchShown, titleVisibility: .visible
        ) {
            Button("Keep Alive") { controller.confirmSwitch(keepAlive: true) }
            Button("Stop and Switch", role: .destructive) { controller.confirmSwitch(keepAlive: false) }
            Button("Cancel", role: .cancel) { controller.pendingSwitch = nil }
        } message: {
            Text("Leaving this item stops its terminals. Keep them alive to let them run in the background.")
        }
        .confirmationDialog(
            "Delete “\(deleteName(project))”?", isPresented: deleteShown, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let item = controller.confirmDeleteItem { store.deleteItem(projectID, item: item) }
            }
        } message: {
            Text("Its terminals stop. This can't be undone.")
        }
        .confirmationDialog(
            "Remove “\(project.name)”?", isPresented: $controller.confirmRemoveProject, titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { store.removeProject(projectID) }
        } message: {
            Text("The project leaves Bridge with its terminals. The folder stays as it is.")
        }
        .background(WindowAccessor { window in attach(window) })
        .onAppear {
            store.openProjectWindow = { [openWindow] id in openWindow(id: "project", value: id) }
            store.closeWelcomeWindow = { [dismissWindow] in dismissWindow(id: "welcome") }
            store.openWelcomeWindow = { [openWindow] in openWindow(id: "welcome") }
            store.windowOpened(projectID, controller: controller)
            if let active = project.active ?? project.views.first?.id {
                store.activate(projectID, item: active)
            }
            if store.pendingFirstTerminal.remove(projectID) != nil {
                controller.newTerminal(.shell)
            }
        }
    }

    @ViewBuilder
    private func detail(_ project: Project) -> some View {
        if let active = project.active, let view = project.view(active) {
            ItemView(project: project, view: view, controller: controller)
                .id(view.id)
        } else {
            ContentUnavailableView {
                Label(
                    controller.isGlobal ? "No terminals outside projects yet" : "No terminals in this project yet",
                    systemImage: "terminal")
            } description: {
                Text(controller.isGlobal
                     ? "Shells and SSH sessions here start in your home folder."
                     : "Add a shell, a task like a dev server, or an SSH session.")
            } actions: {
                Button("New Terminal") { controller.newTerminal(.shell) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { store.sidebarOpen ? .all : .detailOnly },
            set: { store.sidebarOpen = $0 != .detailOnly })
    }

    private var historyTarget: Binding<PaneTarget?> {
        Binding(
            get: { controller.historyPane.map(PaneTarget.init) },
            set: { controller.historyPane = $0?.id })
    }

    private var pendingSwitchShown: Binding<Bool> {
        Binding(get: { controller.pendingSwitch != nil }, set: { if !$0 { controller.pendingSwitch = nil } })
    }

    private var switchTitle: String {
        let count = controller.pendingSwitch?.stopping.count ?? 0
        return count == 1 ? "Stop 1 running terminal?" : "Stop \(count) running terminals?"
    }

    private var deleteShown: Binding<Bool> {
        Binding(get: { controller.confirmDeleteItem != nil }, set: { if !$0 { controller.confirmDeleteItem = nil } })
    }

    private func deleteName(_ project: Project) -> String {
        guard let item = controller.confirmDeleteItem, let view = project.view(item) else { return "" }
        return store.itemName(view, in: project)
    }

    /// Ask before closing a window with running terminals; closing stops them.
    private func attach(_ window: NSWindow) {
        controller.window = window
        window.tabbingMode = .disallowed
        closeGuard = WindowCloseGuard(
            window: window,
            shouldClose: { window in
                let running = Store.shared.runningPanes(of: projectID).count
                guard running > 0 else { return true }
                let alert = NSAlert()
                alert.messageText = "Close “\(Store.shared.project(projectID)?.name ?? "")”?"
                alert.informativeText = running == 1
                    ? "1 terminal is still running; closing the window stops it."
                    : "\(running) terminals are still running; closing the window stops them."
                alert.addButton(withTitle: "Stop and Close")
                alert.addButton(withTitle: "Cancel")
                return alert.runModal() == .alertFirstButtonReturn
            },
            willClose: { Store.shared.windowClosed(projectID) })
    }
}

// MARK: - Toolbar

private struct ProjectToolbar: ToolbarContent {
    let project: Project
    let controller: WindowController

    private var store: Store { .shared }
    @Environment(\.openWindow) private var openWindow

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if controller.isGlobal {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
            } else {
                Menu {
                    Button("Open in Zed", systemImage: "chevron.left.forwardslash.chevron.right") { openInZed(project.root) }
                    Button("Reveal in Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([project.root])
                    }
                    Divider()
                    Button("Edit Project…", systemImage: "pencil") { controller.showProjectSheet = true }
                    Button("Remove Project…", systemImage: "trash", role: .destructive) {
                        controller.confirmRemoveProject = true
                    }
                } label: {
                    ProjectIcon(project: project, size: 20)
                }
                .menuIndicator(.hidden)
                .help(Paths.tilde(project.root.path))
            }
        }

        // Controls of the terminal on screen when the item is a single terminal.
        if let active = project.active, let view = project.view(active), let pane = view.single {
            ToolbarItemGroup {
                PaneControls(project: project, pane: pane, controller: controller)
            }
        }

        ToolbarItemGroup {
            Button("Split Right", systemImage: "rectangle.split.2x1") { controller.split(.horizontal) }
                .help("Add a terminal to the right (⌘D)")
            Button("Split Down", systemImage: "rectangle.split.1x2") { controller.split(.vertical) }
                .help("Add a terminal below (⌘⇧D)")
        }

        ToolbarItem {
            Button("History", systemImage: "clock.arrow.circlepath") {
                controller.historyPane = controller.focusedPane
            }
            .help("Command history (⌃R)")
            .disabled(controller.focusedPane == nil)
        }

        if !controller.isGlobal {
            ToolbarItem {
                Button("Global", systemImage: "globe") { store.openGlobal() }
                    .help("Shells, SSH hosts and sandboxes outside projects (⌘⇧G)")
            }
        }
    }
}

/// Start, stop, restart and the git branch menu for one terminal: in the toolbar for a single
/// terminal, in the pane header in a view.
struct PaneControls: View {
    let project: Project
    let pane: ID
    let controller: WindowController
    var compact = false

    private var store: Store { .shared }

    var body: some View {
        let session = store.sessions[pane]
        let spec = project.terminal(pane)
        if let session, let spec {
            BranchMenu(folder: session.directory.map(URL.init(fileURLWithPath:)) ?? project.folder(spec.folder),
                       session: session, controller: controller, compact: compact)
        }
        if let session {
            if session.status.isRunning {
                if spec?.kind.isTask ?? false {
                    Button("Restart", systemImage: "arrow.clockwise") { store.restart(pane, in: project.id) }
                        .help("Restart")
                    Button("Stop", systemImage: "stop.fill") { store.stop(pane) }
                        .help("Stop")
                }
            } else {
                Button(startTitle(spec, session), systemImage: "play.fill") { store.start(pane, in: project.id) }
                    .help(startTitle(spec, session))
            }
        }
    }

    private func startTitle(_ spec: TerminalSpec?, _ session: PaneSession) -> String {
        if case .exited = session.status {
            return spec?.kind.isSSH == true ? "Reconnect" : "Restart"
        }
        return "Start"
    }
}

/// The branch of a terminal's folder, with a menu to switch branches or worktrees.
struct BranchMenu: View {
    let folder: URL
    let session: PaneSession
    let controller: WindowController
    var compact = false

    @State private var branches: [String] = []
    @State private var worktrees: [Git.Worktree] = []

    var body: some View {
        if let current = Git.currentBranch(in: folder) {
            Menu {
                ForEach(branches.prefix(40), id: \.self) { branch in
                    Toggle(branch, isOn: Binding(get: { branch == current }, set: { _ in switchTo(branch) }))
                }
                Divider()
                Button("New Branch…") { session.surface?.typeText("git switch -c ") }
                if worktrees.count > 1 {
                    Section("Worktrees") {
                        ForEach(worktrees, id: \.path) { worktree in
                            Button("\(worktree.branch ?? "detached") — \(Paths.tilde(worktree.path))") {
                                Store.shared.openFolder(URL(fileURLWithPath: worktree.path))
                            }
                        }
                    }
                }
                let checkedOut = Set(worktrees.compactMap(\.branch))
                let others = branches.filter { !checkedOut.contains($0) }
                if !others.isEmpty {
                    Menu("Open Branch in a New Worktree") {
                        ForEach(others.prefix(40), id: \.self) { branch in
                            Button(branch) { openWorktree(branch) }
                        }
                    }
                }
            } label: {
                Label(current, systemImage: "arrow.triangle.branch")
                    .labelStyle(.titleAndIcon)
            }
            .help("Git branch")
            .onAppear(perform: reload)
            .onChange(of: folder) { reload() }
        }
    }

    private func reload() {
        let folder = folder
        Task.detached {
            let branches = Git.branches(in: folder)
            let worktrees = Git.worktrees(in: folder)
            await MainActor.run {
                self.branches = branches
                self.worktrees = worktrees
            }
        }
    }

    /// Switch branches by running `git switch` at the prompt, so the shell sees it.
    private func switchTo(_ branch: String) {
        session.surface?.typeText("git switch -- \(Launch.quote(branch))\r")
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            reload()
        }
    }

    private func openWorktree(_ branch: String) {
        do {
            let url = try Git.addWorktree(in: folder, branch: branch)
            Store.shared.openFolder(url)
        } catch {
            controller.toast = error.localizedDescription
        }
    }
}

func openInZed(_ folder: URL) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    // The `zed` command when installed, otherwise the app.
    process.arguments = ["sh", "-lc", "command -v zed >/dev/null && exec zed \"$0\" || exec open -a Zed \"$0\"", folder.path]
    try? process.run()
}

/// A pane, as an identifiable sheet item.
struct PaneTarget: Identifiable {
    let id: ID
}
