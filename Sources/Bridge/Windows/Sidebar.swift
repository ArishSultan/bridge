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
                ForEach(project.views) { view in
                    ItemRow(project: project, view: view, controller: controller)
                        .tag(view.id)
                }
                .onMove { store.moveItems(project.id, fromOffsets: $0, toOffset: $1) }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Button {
                    controller.newTerminal(.shell)
                } label: {
                    Label("New Terminal", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .help(controller.isGlobal ? "New terminal (⌘T)" : "New sandboxed terminal (⌘T)")
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
            .padding(10)
        }
    }

    private var selection: Binding<ID?> {
        Binding(
            get: { project.active },
            set: { if let id = $0 { controller.select(id) } })
    }
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
