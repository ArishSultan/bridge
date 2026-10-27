import BridgeCore
import SwiftUI

/// What the Global window's sidebar shows below its terminals: shared presets every project uses.
struct GlobalSections: View {
    let controller: WindowController

    private var store: Store { .shared }

    var body: some View {
        Section {
            ForEach(store.profiles.hosts) { host in
                HostRow(host: host, controller: controller)
                ForEach(host.forwards) { forward in
                    ForwardRow(forward: forward, host: host, controller: controller)
                }
            }
            if store.profiles.hosts.isEmpty {
                Text("Servers you connect to, and port forwards over them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("SSH Hosts")
                Spacer()
                VaultButton()
                Button("New SSH Host", systemImage: "plus") { controller.hostSheet = .init(id: 0) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
        }
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

private struct HostRow: View {
    let host: SSHHost
    let controller: WindowController

    @State private var confirmDelete = false
    private var store: Store { .shared }

    var body: some View {
        HStack {
            Image(systemName: "server.rack").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(host.displayName)
                Text(host.address).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Connect", systemImage: "play.fill") { store.connect(host) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Open an SSH session")
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { controller.hostSheet = .init(id: host.id) }
        .contextMenu {
            Button("Connect") { store.connect(host) }
            Button("Add Port Forward…") { controller.forwardSheet = .init(host: host.id, forward: 0) }
            Button("Edit Host…") { controller.hostSheet = .init(id: host.id) }
            Divider()
            Button("Delete Host…", role: .destructive) { confirmDelete = true }
        }
        .confirmationDialog("Delete “\(host.displayName)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { store.deleteHost(host.id) }
        } message: {
            Text("Its port forwards and saved password are deleted too.")
        }
    }
}

private struct ForwardRow: View {
    let forward: Forward
    let host: SSHHost
    let controller: WindowController

    @State private var hovering = false
    private var store: Store { .shared }

    var body: some View {
        let state = store.forwards.state(forward.id)
        HStack(spacing: 6) {
            StatusDot(forward: state)
            VStack(alignment: .leading, spacing: 1) {
                Text(forward.name.isEmpty ? forward.summary : forward.name)
                if !forward.name.isEmpty || state != .off && state != .up {
                    Text(state == .off || state == .up ? forward.summary : state.text)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if forward.showLogs && hovering {
                Button("Log", systemImage: "doc.plaintext") { controller.logSheet = .init(id: forward.id) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            Toggle("On", isOn: Binding(get: { forward.enabled }, set: { store.forwards.setEnabled(forward.id, $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.leading, 18)
        .help(state.text)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Edit…") { controller.forwardSheet = .init(host: host.id, forward: forward.id) }
            Button("Connection Log") { controller.logSheet = .init(id: forward.id) }
            Divider()
            Button("Delete", role: .destructive) { store.deleteForward(forward.id) }
        }
    }
}

/// Lock or unlock Vaultwarden.
struct VaultButton: View {
    @State private var showSheet = false
    private var store: Store { .shared }

    var body: some View {
        if store.vaultUnlocked {
            Button("Lock Vaultwarden", systemImage: "lock.open") { store.lockVault() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Vaultwarden is unlocked: its SSH keys are in use. Click to lock.")
        } else {
            Button(store.profiles.vault == nil ? "Link Vaultwarden" : "Unlock Vaultwarden", systemImage: "lock") {
                showSheet = true
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(store.profiles.vault == nil ? "Link Vaultwarden, to sign in with its SSH keys" : "Unlock Vaultwarden")
            .sheet(isPresented: $showSheet) { VaultSheet() }
        }
    }
}
