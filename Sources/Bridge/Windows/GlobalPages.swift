import BridgeCore
import BridgeSystem
import SwiftUI

/// A Global window page: what every project shares.
struct GlobalPageView: View {
    let page: GlobalPage
    let controller: WindowController

    var body: some View {
        switch page {
        case .hosts: HostsPage(controller: controller)
        case .sandboxes: SandboxesPage(controller: controller)
        case .vault: VaultPage()
        }
    }
}

// MARK: - SSH hosts

private struct HostsPage: View {
    let controller: WindowController

    private var store: Store { .shared }

    var body: some View {
        Group {
            if store.profiles.hosts.isEmpty {
                ContentUnavailableView {
                    Label("No SSH Hosts", systemImage: "server.rack")
                } description: {
                    Text("Servers you connect to, from any project, and port forwards over them. Bridge uses your system ssh, so ~/.ssh/config keeps working.")
                } actions: {
                    Button("Add SSH Host") { controller.hostSheet = .init(id: 0) }
                        .buttonStyle(.glassProminent)
                }
            } else {
                Form {
                    ForEach(store.profiles.hosts) { host in
                        HostSection(host: host, controller: controller)
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
        }
        .background(store.chrome.surface)
        .navigationTitle("SSH Hosts")
        .toolbar {
            ToolbarItem {
                VaultButton()
            }
            ToolbarItem {
                Button("Add SSH Host", systemImage: "plus") { controller.hostSheet = .init(id: 0) }
                    .help("Add an SSH host")
            }
        }
    }
}

private struct HostSection: View {
    let host: SSHHost
    let controller: WindowController

    @State private var confirmDelete = false
    private var store: Store { .shared }

    var body: some View {
        Section {
            LabeledContent("Address", value: host.address)
            LabeledContent("Signs in with", value: authLabel)
            if host.onDisconnect != .nothing {
                LabeledContent("When it drops", value: host.onDisconnect.label)
            }
            ForEach(host.forwards) { forward in
                ForwardRow(forward: forward, host: host, controller: controller)
            }
            HStack {
                Button("Add Port Forward", systemImage: "arrow.left.arrow.right") {
                    controller.forwardSheet = .init(host: host.id, forward: 0)
                }
                Spacer()
                Button("Connect", systemImage: "terminal") { store.connect(host) }
                    .buttonStyle(.glassProminent)
            }
            .buttonStyle(.glass)
        } header: {
            HStack {
                Label(host.displayName, systemImage: "server.rack")
                    .font(.headline)
                Spacer()
                Menu {
                    Button("Edit Host…", systemImage: "pencil") { controller.hostSheet = .init(id: host.id) }
                    Button("Add Port Forward…", systemImage: "arrow.left.arrow.right") {
                        controller.forwardSheet = .init(host: host.id, forward: 0)
                    }
                    Divider()
                    Button("Delete Host…", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .fixedSize()
            }
        }
        .confirmationDialog("Delete “\(host.displayName)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { store.deleteHost(host.id) }
        } message: {
            Text("Its port forwards and saved password are deleted too.")
        }
    }

    private var authLabel: String {
        switch host.auth {
        case .agent: "ssh-agent and ~/.ssh/config"
        case .key(let path): "Key \(path)"
        case .password: Keychain.hasPassword(host: host.id) ? "Saved password" : "Password"
        case .vault(_, let name): "Vaultwarden key “\(name)”"
        }
    }
}

private struct ForwardRow: View {
    let forward: Forward
    let host: SSHHost
    let controller: WindowController

    private var store: Store { .shared }

    var body: some View {
        let state = store.forwards.state(forward.id)
        Toggle(isOn: Binding(get: { forward.enabled }, set: { store.forwards.setEnabled(forward.id, $0) })) {
            HStack(spacing: 8) {
                StatusDot(forward: state)
                VStack(alignment: .leading, spacing: 2) {
                    Text(forward.name.isEmpty ? forward.summary : forward.name)
                    Text(forward.name.isEmpty ? state.text : "\(forward.summary) · \(state.text)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .toggleStyle(.switch)
        .contextMenu {
            Button("Edit…") { controller.forwardSheet = .init(host: host.id, forward: forward.id) }
            Button("Connection Log") { controller.logSheet = .init(id: forward.id) }
            Divider()
            Button("Delete", role: .destructive) { store.deleteForward(forward.id) }
        }
        .swipeActions {
            Button("Delete", role: .destructive) { store.deleteForward(forward.id) }
        }
    }
}

// MARK: - Sandboxes

private struct SandboxesPage: View {
    let controller: WindowController

    private var store: Store { .shared }

    var body: some View {
        Form {
            Section {
                SandboxRow(name: "Project", detail: summary(store.profiles.projectEngine), isDefault: true, docker: false) {
                    controller.sandboxSheet = .init(profile: nil)
                }
                ForEach(store.profiles.sandboxes) { profile in
                    SandboxRow(name: profile.name, detail: summary(profile.engine), isDefault: false, docker: profile.engine.isDocker) {
                        controller.sandboxSheet = .init(profile: profile.id)
                    }
                }
            } footer: {
                Text("Every project terminal runs in a sandbox unless it's open. The Project sandbox is the default; terminals can pick another one.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(store.chrome.surface)
        .navigationTitle("Sandboxes")
        .toolbar {
            ToolbarItem {
                Button("New Sandbox", systemImage: "plus") { controller.sandboxSheet = .init(profile: 0) }
                    .help("Add a sandbox profile")
            }
        }
    }

    private func summary(_ engine: SandboxEngine) -> String {
        switch engine {
        case .seatbelt(let s):
            var parts = ["macOS sandbox"]
            parts.append(s.confineReads ? "reads confined" : "reads open")
            let network: String = switch s.network {
            case .all: "network"
            case .localhost: "localhost only"
            case .none: "no network"
            }
            parts.append(network)
            if !s.blocked.isEmpty { parts.append("\(s.blocked.count) blocked") }
            return parts.joined(separator: " · ")
        case .docker(let d):
            return "Docker · \(d.image.isEmpty ? "ubuntu:24.04" : d.image)\(d.network ? "" : " · no network")"
        }
    }
}

private struct SandboxRow: View {
    let name: String
    let detail: String
    let isDefault: Bool
    let docker: Bool
    let edit: () -> Void

    var body: some View {
        Button(action: edit) {
            HStack(spacing: 12) {
                Image(systemName: docker ? "shippingbox.fill" : "checkmark.shield.fill")
                    .font(.title2)
                    .foregroundStyle(docker ? Color.blue : Color.green)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(name).font(.body.weight(.medium))
                        if isDefault {
                            Text("Default")
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Vaultwarden

private struct VaultPage: View {
    @State private var showUnlock = false
    private var store: Store { .shared }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: store.vaultUnlocked ? "lock.open.fill" : "lock.fill")
                        .font(.largeTitle)
                        .foregroundStyle(store.vaultUnlocked ? Color.green : Color.secondary)
                        .frame(width: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.vaultUnlocked ? "Unlocked" : store.profiles.vault == nil ? "Not linked" : "Locked")
                            .font(.title3.weight(.semibold))
                        Text(statusDetail).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.vaultUnlocked {
                        Button("Lock") { store.lockVault() }
                            .buttonStyle(.glass)
                    } else {
                        Button(store.profiles.vault == nil ? "Link…" : "Unlock…") { showUnlock = true }
                            .buttonStyle(.glassProminent)
                    }
                }
                .padding(.vertical, 6)
            }
            if let account = store.profiles.vault {
                Section("Account") {
                    LabeledContent("Server", value: account.server)
                    LabeledContent("Email", value: account.email)
                    Picker("Lock after", selection: Binding(
                        get: { account.lockMinutes },
                        set: { store.profiles.vault?.lockMinutes = $0 })) {
                        Text("15 minutes").tag(UInt32(15))
                        Text("1 hour").tag(UInt32(60))
                        Text("4 hours").tag(UInt32(240))
                        Text("Never").tag(UInt32(0))
                    }
                }
            }
            if store.vaultUnlocked {
                Section("SSH Keys") {
                    ForEach(store.vaultKeys) { key in
                        Label(key.name, systemImage: "key.fill")
                    }
                }
            }
            Section {
                EmptyView()
            } footer: {
                Text("Hosts that sign in with a Vaultwarden key use it while the vault is unlocked. The master password and keys are never saved; locking, quitting or the idle time removes them.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(store.chrome.surface)
        .navigationTitle("Vaultwarden")
        .sheet(isPresented: $showUnlock) { VaultSheet() }
    }

    private var statusDetail: String {
        if store.vaultUnlocked {
            return store.vaultKeys.count == 1 ? "1 SSH key is ready." : "\(store.vaultKeys.count) SSH keys are ready."
        }
        if let account = store.profiles.vault { return account.email }
        return "Sign in with SSH keys stored in your own Vaultwarden server."
    }
}

/// Lock or unlock Vaultwarden, for the SSH Hosts page's toolbar.
struct VaultButton: View {
    @State private var showSheet = false
    private var store: Store { .shared }

    var body: some View {
        if store.vaultUnlocked {
            Button("Lock Vaultwarden", systemImage: "lock.open") { store.lockVault() }
                .help("Vaultwarden is unlocked: its SSH keys are in use. Click to lock.")
        } else {
            Button(store.profiles.vault == nil ? "Link Vaultwarden" : "Unlock Vaultwarden", systemImage: "lock") {
                showSheet = true
            }
            .help(store.profiles.vault == nil ? "Link Vaultwarden, to sign in with its SSH keys" : "Unlock Vaultwarden")
            .sheet(isPresented: $showSheet) { VaultSheet() }
        }
    }
}
