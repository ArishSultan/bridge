import AppKit
import BridgeCore
import SwiftUI

/// A project's items: terminals and views, in order, with their state.
struct Sidebar: View {
    let project: Project
    let controller: WindowController

    private var store: Store { .shared }

    var body: some View {
        List(selection: selection) {
            Section(controller.isGlobal ? "Terminals" : "Terminals and Views") {
                if project.views.isEmpty {
                    Text(controller.isGlobal ? "Shells and SSH sessions outside any project." : "No terminals yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(project.views) { view in
                    ItemRow(project: project, view: view, controller: controller)
                        .tag(SidebarTag.item(view.id))
                }
                .onMove { store.moveItems(project.id, fromOffsets: $0, toOffset: $1) }
            }
            if controller.isGlobal {
                Section("Shared") {
                    ForEach(GlobalPage.allCases) { page in
                        Label(page.title, systemImage: page.systemImage)
                            .badge(badge(page))
                            .tag(SidebarTag.page(page))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(store.chrome.surface)
        .overlay(alignment: .bottomTrailing) {
            NewTerminalButton(project: project, controller: controller)
                .padding(14)
        }
    }

    private var selection: Binding<SidebarTag?> {
        Binding(
            get: {
                if let page = controller.globalPage { return .page(page) }
                return project.active.map(SidebarTag.item)
            },
            set: { tag in
                switch tag {
                case .item(let id)?:
                    controller.globalPage = nil
                    controller.select(id)
                case .page(let page)?:
                    controller.globalPage = page
                case nil:
                    break
                }
            })
    }

    private func badge(_ page: GlobalPage) -> Int {
        switch page {
        case .hosts: store.profiles.hosts.count
        case .sandboxes: store.profiles.sandboxes.count + 1
        case .vault: 0
        }
    }
}

/// What a sidebar row stands for: an item of the project, or (in Global) a shared page.
enum SidebarTag: Hashable {
    case item(ID)
    case page(GlobalPage)
}

/// The Global window's pages for what every project shares.
enum GlobalPage: String, CaseIterable, Identifiable, Hashable {
    case hosts, sandboxes, vault

    var id: Self { self }

    var title: String {
        switch self {
        case .hosts: "SSH Hosts"
        case .sandboxes: "Sandboxes"
        case .vault: "Vaultwarden"
        }
    }

    var systemImage: String {
        switch self {
        case .hosts: "server.rack"
        case .sandboxes: "checkmark.shield"
        case .vault: "key.viewfinder"
        }
    }
}

/// The floating + button: a menu of every kind of terminal, each opening its own form. It is
/// the toolbar's glass button style, tinted blue, and opens a native menu where it's clicked.
struct NewTerminalButton: View {
    let project: Project
    let controller: WindowController

    private var store: Store { .shared }

    var body: some View {
        Button(action: showMenu) {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .controlSize(.extraLarge)
        .tint(.blue)
        .help(controller.isGlobal
              ? "New terminal: a shell, a task or an SSH session"
              : "New terminal: a sandboxed or open shell, a task, Claude, or an SSH session")
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(.sectionHeader(title: "New Terminal"))
        menu.addItem(ClosureMenuItem(controller.isGlobal ? "Shell" : "Sandboxed Shell", symbol: "terminal") {
            controller.newTerminal(.shell)
        })
        if !controller.isGlobal {
            menu.addItem(ClosureMenuItem("Open Shell", symbol: "exclamationmark.shield") {
                controller.newTerminal(.openShell)
            })
        }
        menu.addItem(ClosureMenuItem("Task…", symbol: "play.circle") { controller.newTerminal(.task) })
        menu.addItem(ClosureMenuItem("Claude", symbol: "sparkles") { store.newClaudeTerminal(in: project.id) })
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "SSH"))
        if store.profiles.hosts.isEmpty {
            menu.addItem(ClosureMenuItem("Add an SSH Host…", symbol: "server.rack") {
                store.openGlobal()
                store.controllers[store.globalID]?.globalPage = .hosts
                store.controllers[store.globalID]?.hostSheet = .init(id: 0)
            })
        } else {
            for host in store.profiles.hosts {
                let projectID = project.id
                menu.addItem(ClosureMenuItem(host.displayName, symbol: "server.rack") {
                    store.addItem(projectID, spec: TerminalSpec(kind: .ssh(host: host.id), isolation: .open))
                })
            }
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    required init(coder: NSCoder) { fatalError("not supported") }

    @objc private func run() { handler() }
}

/// One item in the sidebar.
private struct ItemRow: View {
    let project: Project
    let view: ProjectItem
    let controller: WindowController

    @State private var draft = ""
    @FocusState private var editing: Bool

    private var store: Store { .shared }

    var body: some View {
        let sessions = view.panes.compactMap { store.sessions[$0] }
        let running = sessions.filter(\.status.isRunning).count
        let attention = sessions.contains(where: \.needsAttention)
        let single = view.single.flatMap { project.terminal($0) }

        HStack(spacing: 6) {
            Image(systemName: icon(single))
                .foregroundStyle(single.map { $0.effectiveIsolation.isOpen } == true ? Color.orange : Color.secondary)
            if controller.renaming == .item(view.id) {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($editing)
                    .onSubmit(commitRename)
                    .onExitCommand { controller.renaming = nil }
                    .onAppear {
                        draft = single?.name ?? view.name
                        editing = true
                    }
                    .onChange(of: editing) { if !editing { commitRename() } }
            } else {
                Text(store.itemName(view, in: project))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if attention {
                Image(systemName: "bell.badge.fill")
                    .foregroundStyle(.orange)
                    .help("Needs your attention")
            }
            if running > 0 {
                if view.single == nil {
                    Text("\(running)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Circle().fill(.green).frame(width: 7, height: 7)
            }
        }
        .help(tooltip(single: single, running: running))
        .contextMenu {
            if let pane = view.single, let spec = single {
                Button("Edit Terminal…") { controller.edit(pane) }
                Button("Rename") { controller.renaming = .item(view.id) }
                Toggle("Keep Alive", isOn: Binding(
                    get: { spec.background },
                    set: { store.setKeepAlive(project.id, panes: [pane], $0) }))
                Divider()
                Button("Delete Terminal…", role: .destructive) { controller.confirmDeleteItem = view.id }
            } else {
                Button("Rename") { controller.renaming = .item(view.id) }
                Divider()
                Button("Delete View…", role: .destructive) { controller.confirmDeleteItem = view.id }
            }
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { controller.renaming = .item(view.id) })
    }

    private func commitRename() {
        guard controller.renaming == .item(view.id) else { return }
        store.rename(project.id, item: view.id, to: draft)
        controller.renaming = nil
    }

    private func icon(_ spec: TerminalSpec?) -> String {
        guard let spec else { return "square.grid.2x2" }
        switch spec.kind {
        case .shell: return "terminal"
        case .task: return "play.circle"
        case .ssh: return "server.rack"
        }
    }

    private func tooltip(single: TerminalSpec?, running: Int) -> String {
        guard let spec = single else {
            return "View of \(view.panes.count) terminals, \(running) running"
        }
        var parts = [running > 0 ? "Running" : "Not running"]
        parts.append(spec.effectiveIsolation.isOpen ? "open" : "sandboxed")
        if spec.background { parts.append("kept alive") }
        return parts.joined(separator: ", ")
    }
}
