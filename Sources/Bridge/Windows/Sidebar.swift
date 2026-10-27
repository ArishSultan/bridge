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
            Section("Terminals") {
                if project.views.isEmpty {
                    Text(controller.isGlobal ? "Shells and SSH sessions outside any project." : "No terminals yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(project.views) { view in
                    ItemRow(project: project, view: view, controller: controller)
                        .tag(view.id)
                        // A terminal can be dragged into the split on screen, to sit beside one there.
                        .itemProvider {
                            guard let pane = view.single else {
                                // A split only moves within the sidebar.
                                Store.shared.draggedPane = nil
                                return NSItemProvider()
                            }
                            return PaneDrag(project: project.id, item: view.id, pane: pane).provider()
                        }
                }
                .onMove { store.moveItems(project.id, fromOffsets: $0, toOffset: $1) }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, alignment: .trailing) {
            NewTerminalMenu(project: project, controller: controller)
                .padding(12)
        }
    }

    private var selection: Binding<ID?> {
        Binding(
            get: { project.active },
            set: { if let id = $0 { controller.select(id) } })
    }
}

/// The + menu under the sidebar: a sandboxed shell right away, or any kind of terminal. Every
/// entry is also in the File menu.
struct NewTerminalMenu: View {
    let project: Project
    let controller: WindowController

    private var store: Store { .shared }

    var body: some View {
        Menu {
            Button(controller.isGlobal ? "Shell" : "Sandboxed Shell", systemImage: "terminal") { controller.newShell() }
            Button("Terminal of Any Kind…", systemImage: "rectangle.and.pencil.and.ellipsis") { controller.newTerminal(.shell) }
            Button("Task…", systemImage: "play.circle") { controller.newTerminal(.task) }
            Menu("Agent", systemImage: "sparkles") {
                ForEach(Agent.allCases) { agent in
                    Button(agent.name) { store.newAgentTerminal(agent, in: project.id) }
                }
            }
            Section("SSH") {
                ForEach(store.profiles.hosts) { host in
                    Button(host.displayName, systemImage: "server.rack") {
                        store.addItem(project.id, spec: TerminalSpec(kind: .ssh(host: host.id), isolation: .open))
                    }
                }
                Button("Add an SSH Host…", systemImage: "plus") {
                    store.settingsTab = .hosts
                    store.openSettingsWindow?()
                    SharedSheets.shared.hostSheet = .init(id: 0)
                }
            }
        } label: {
            Label("New Terminal", systemImage: "plus")
                .labelStyle(.iconOnly)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 22, height: 22)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .fixedSize()
        .help(controller.isGlobal ? "New terminal: a shell, a task or an SSH session" : "New terminal: sandboxed, or any other kind")
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

        let open = single.map { $0.effectiveIsolation.isOpen } == true && !controller.isGlobal
        HStack(spacing: 6) {
            Image(systemName: icon(single))
                .foregroundStyle(open ? Color.orange : Color.secondary)
                .accessibilityHidden(true)
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
            if open {
                Text("open")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
                    .help("Not sandboxed")
            }
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
                // A filled circle, not only a color: running.
                Image(systemName: "circle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.green)
            }
        }
        .help(tooltip(single: single, running: running))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(store.itemName(view, in: project))
        .accessibilityValue(tooltip(single: single, running: running) + (attention ? ", needs your attention" : ""))
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
                Button("Delete Split…", role: .destructive) { controller.confirmDeleteItem = view.id }
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
            return "Split of \(view.panes.count) terminals, \(running) running"
        }
        var parts = [running > 0 ? "Running" : "Not running"]
        parts.append(spec.effectiveIsolation.isOpen ? "open" : "sandboxed")
        if spec.background { parts.append("kept alive") }
        return parts.joined(separator: ", ")
    }
}
