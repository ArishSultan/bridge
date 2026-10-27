import BridgeCore
import SwiftUI

/// What the Global window's sidebar shows below its terminals: shared presets every project uses.
struct GlobalSections: View {
    let controller: WindowController

    private var store: Store { .shared }

    var body: some View {
        Section {
            SandboxRow(name: "Project", detail: "default", docker: store.profiles.projectEngine.isDocker) {
                controller.sandboxSheet = .init(profile: nil)
            }
            ForEach(store.profiles.sandboxes) { profile in
                SandboxRow(name: profile.name, detail: profile.engine.isDocker ? "Docker" : "macOS", docker: profile.engine.isDocker) {
                    controller.sandboxSheet = .init(profile: profile.id)
                }
            }
        } header: {
            HStack {
                Text("Sandboxes")
                Spacer()
                Button("New Sandbox", systemImage: "plus") { controller.sandboxSheet = .init(profile: 0) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
        }
    }
}

private struct SandboxRow: View {
    let name: String
    let detail: String
    let docker: Bool
    let edit: () -> Void

    var body: some View {
        Button(action: edit) {
            HStack {
                Image(systemName: docker ? "shippingbox" : "checkmark.shield")
                    .foregroundStyle(.secondary)
                Text(name)
                Spacer()
                Text(detail).foregroundStyle(.secondary).font(.caption)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { Button("Edit…", action: edit) }
    }
}
