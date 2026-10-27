import AppKit
import BridgeCore
import BridgeSystem
import SwiftUI

/// New / Edit SSH host.
struct HostSheet: View {
    /// 0 for a new host.
    let hostID: ID

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var host = ""
    @State private var port = ""
    @State private var user = ""
    @State private var auth: AuthChoice = .agent
    @State private var keyPath = ""
    @State private var password = ""
    @State private var vaultItem: (id: String, name: String)?
    @State private var keepalive = "30"
    @State private var onDisconnect: OnDisconnect = .nothing
    @State private var error: String?
    @State private var hasSavedPassword = false

    enum AuthChoice: String, CaseIterable, Identifiable {
        case agent = "Agent / config", key = "Key file", password = "Password", vault = "Vaultwarden"
        var id: Self { self }
    }

    private var store: Store { .shared }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text(host.isEmpty ? "Production" : host))
                    TextField("Host", text: $host, prompt: Text("example.com"))
                    TextField("Port", text: $port, prompt: Text("22"))
                    TextField("User", text: $user, prompt: Text("From ~/.ssh/config"))
                }
                Section("Sign in with") {
                    Picker("Sign in with", selection: $auth) {
                        ForEach(AuthChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    switch auth {
                    case .agent:
                        Text("Your ssh-agent, keys and ~/.ssh/config, as in any terminal.")
                            .foregroundStyle(.secondary)
                    case .key:
                        LabeledContent("Key file") {
                            HStack {
                                TextField("", text: $keyPath, prompt: Text("~/.ssh/id_ed25519")).labelsHidden()
                                Button("Choose…", action: chooseKey)
                            }
                        }
                    case .password:
                        SecureField("Password", text: $password,
                                    prompt: Text(hasSavedPassword ? "Saved in Keychain — type to replace" : "Asked when connecting if empty"))
                    case .vault:
                        VaultKeyPicker(selection: $vaultItem)
                    }
                }
                Section("Connection") {
                    TextField("Keep-alive (seconds)", text: $keepalive, prompt: Text("0: off"))
                    Picker("When the connection drops", selection: $onDisconnect) {
                        ForEach(OnDisconnect.allCases, id: \.self) { Text($0.label) }
                    }
                    .pickerStyle(.segmented)
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(hostID == 0 ? "Add" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 500)
        .onAppear(perform: load)
    }

    private func load() {
        guard let existing = store.profiles.host(hostID) else { return }
        name = existing.name
        host = existing.host
        port = existing.port == 22 ? "" : "\(existing.port)"
        user = existing.user
        keepalive = "\(existing.keepaliveSecs)"
        onDisconnect = existing.onDisconnect
        hasSavedPassword = Keychain.hasPassword(host: hostID)
        switch existing.auth {
        case .agent: auth = .agent
        case .key(let path):
            auth = .key
            keyPath = path
        case .password: auth = .password
        case .vault(let item, let name):
            auth = .vault
            vaultItem = (item, name)
        }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: Paths.home + "/.ssh")
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        keyPath = Paths.tilde(url.path)
    }

    private func save() {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { error = "Enter the host's address."; return }
        let portText = port.trimmingCharacters(in: .whitespaces)
        guard let port = portText.isEmpty ? 22 : UInt16(portText) else { error = "The port must be a number up to 65535."; return }
        let keepaliveText = keepalive.trimmingCharacters(in: .whitespaces)
        guard let keepalive = keepaliveText.isEmpty ? 0 : UInt32(keepaliveText) else { error = "Keep-alive must be a number of seconds."; return }

        let sshAuth: SSHAuth
        switch auth {
        case .agent:
            sshAuth = .agent
        case .key:
            let path = keyPath.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty, FileManager.default.fileExists(atPath: Paths.expandHome(path)) else {
                error = "Choose a key file that exists."
                return
            }
            sshAuth = .key(path: Paths.tilde(Paths.expandHome(path)))
        case .password:
            sshAuth = .password
        case .vault:
            guard let vaultItem else { error = "Choose a key from Vaultwarden."; return }
            sshAuth = .vault(item: vaultItem.id, name: vaultItem.name)
        }

        let saved = SSHHost(
            id: hostID, name: name.trimmingCharacters(in: .whitespaces), host: host, port: port,
            user: user.trimmingCharacters(in: .whitespaces), auth: sshAuth, keepaliveSecs: keepalive,
            onDisconnect: onDisconnect)
        let id = store.profiles.upsert(saved)
        // The password lives in the Keychain: replaced when typed, kept when left empty, and
        // removed when the host stops using one.
        if case .password = sshAuth {
            if !password.isEmpty { Keychain.setPassword(password, host: id) }
        } else {
            Keychain.deletePassword(host: id)
        }
        dismiss()
    }
}

/// The SSH keys in Vaultwarden, or a way to unlock it.
struct VaultKeyPicker: View {
    @Binding var selection: (id: String, name: String)?

    private var store: Store { .shared }

    var body: some View {
        let keys = store.vaultKeys
        if keys.isEmpty {
            HStack {
                Text(selection.map { "Uses “\($0.name)”." } ?? "Unlock Vaultwarden to choose a key.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Unlock Vaultwarden…") { store.showVaultSheet = true }
            }
        } else {
            Picker("Key", selection: Binding(
                get: { selection?.id ?? "" },
                set: { id in selection = keys.first { $0.id == id }.map { ($0.id, $0.name) } })) {
                Text("Choose a key").tag("")
                ForEach(keys, id: \.id) { key in Text(key.name).tag(key.id) }
            }
        }
    }
}

/// New / Edit port forward.
struct ForwardSheet: View {
    let hostID: ID
    /// 0 for a new forward.
    let forwardID: ID

    @Environment(\.dismiss) private var dismiss
    @State private var kind: ForwardKind = .local
    @State private var bind = ""
    @State private var target = ""
    @State private var name = ""
    @State private var showLogs = false
    @State private var error: String?

    private var store: Store { .shared }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Type", selection: $kind) {
                        ForEach(ForwardKind.allCases, id: \.self) { Text($0.label) }
                    }
                    .pickerStyle(.segmented)
                    Text(help).font(.caption).foregroundStyle(.secondary)
                    TextField(kind == .remote ? "Server port" : "Local port", text: $bind, prompt: Text("8080 or 127.0.0.1:8080"))
                    if kind != .dynamic {
                        TextField("Target", text: $target, prompt: Text("localhost:5432"))
                    }
                    TextField("Name", text: $name, prompt: Text("Database"))
                    Toggle("Keep a connection log", isOn: $showLogs)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(forwardID == 0 ? "Add" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 460)
        .onAppear {
            guard let (forward, _) = store.profiles.forward(forwardID) else { return }
            kind = forward.kind
            bind = forward.bind
            target = forward.target
            name = forward.name
            showLogs = forward.showLogs
        }
    }

    private var help: String {
        switch kind {
        case .local: "A port on this Mac reaches a target through the server."
        case .remote: "A port on the server reaches a target on this Mac."
        case .dynamic: "A SOCKS proxy on this Mac that goes out through the server."
        }
    }

    private func save() {
        let bind = bind.trimmingCharacters(in: .whitespaces)
        let portText = bind.split(separator: ":").last.map(String.init) ?? bind
        guard let port = UInt16(portText), port > 0 else { error = "Enter a port (1–65535), optionally after an address."; return }
        let target = target.trimmingCharacters(in: .whitespaces)
        if kind != .dynamic {
            let parts = target.split(separator: ":")
            guard parts.count >= 2, !parts.dropLast().joined(separator: ":").isEmpty, UInt16(parts.last!) != nil else {
                error = "The target must be host:port, like localhost:5432."
                return
            }
        }
        store.profiles.upsert(Forward(
            id: forwardID, name: name.trimmingCharacters(in: .whitespaces), kind: kind, bind: bind,
            target: kind == .dynamic ? "" : target, showLogs: showLogs), host: hostID)
        if forwardID != 0, store.forwards.state(forwardID) != .off { store.forwards.start(forwardID) }
        dismiss()
    }
}

/// A forward's connection log.
struct ForwardLogSheet: View {
    let forwardID: ID

    @Environment(\.dismiss) private var dismiss
    private var store: Store { .shared }

    var body: some View {
        let lines = store.forwards.logs[forwardID] ?? []
        VStack(spacing: 0) {
            HStack {
                StatusDot(forward: store.forwards.state(forwardID))
                Text(store.forwards.state(forwardID).text)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(8)
                }
                .onAppear { proxy.scrollTo(lines.count - 1, anchor: .bottom) }
                .onChange(of: lines.count) { proxy.scrollTo(lines.count - 1, anchor: .bottom) }
            }
        }
        .frame(width: 720, height: 460)
        .navigationTitle(store.profiles.forward(forwardID).map { $0.forward.name.isEmpty ? $0.forward.summary : $0.forward.name } ?? "Log")
    }
}

extension StatusDot {
    init(forward: Forwards.State) {
        switch forward {
        case .up: self.init(status: .running)
        case .failed: self.init(status: .exited(code: 1))
        case .connecting, .retrying: self.init(color: .orange, help: forward.text)
        case .off: self.init(status: .stopped)
        }
    }
}
