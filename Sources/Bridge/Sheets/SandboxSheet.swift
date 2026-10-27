import BridgeCore
import SwiftUI

/// Edit a sandbox profile (or the built-in Project sandbox): macOS's sandbox with its rules, or
/// a Docker container.
struct SandboxSheet: View {
    /// nil edits the built-in Project sandbox; 0 makes a new profile.
    let profileID: ID?

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var docker = false
    // Seatbelt
    @State private var confineReads = true
    @State private var readable = ""
    @State private var writable = ""
    @State private var hidden = ""
    @State private var network: Network = .all
    @State private var blocked = ""
    @State private var allowClipboard = false
    @State private var allowOpen = false
    @State private var blockKeychain = true
    // Docker
    @State private var image = "ubuntu:24.04"
    @State private var dockerNetwork = true
    @State private var mounts = ""
    @State private var env = ""
    @State private var confirmDelete = false

    private var store: Store { .shared }
    private var isProject: Bool { profileID == nil }

    var body: some View {
        SheetScaffold(
            title: isProject ? "Project Sandbox" : profileID == 0 ? "New Sandbox" : "Edit Sandbox",
            subtitle: isProject ? "The default for project terminals" : nil,
            confirm: "Save",
            destructive: isProject || profileID == 0 ? nil : ("Delete Sandbox…", { confirmDelete = true }),
            onConfirm: save
        ) {
            Section {
                if !isProject {
                    TextField("Name", text: $name, prompt: Text("Agents"))
                }
                Picker("Isolation", selection: $docker) {
                    Label("macOS sandbox", systemImage: "checkmark.shield").tag(false)
                    Label("Docker container", systemImage: "shippingbox").tag(true)
                }
                .disabled(isProject)
            }

            if docker {
                Section {
                    TextField("Image", text: $image, prompt: Text("ubuntu:24.04"))
                    Toggle("Network", isOn: $dockerNetwork)
                } footer: {
                    Text("The project folder is mounted at /workspace. Nothing else on your Mac is visible inside.")
                }
                Section("Extra mounts") {
                    listEditor(text: $mounts, hint: "One per line: ~/data:/data or ~/models:/models:ro")
                }
                Section("Pass variables") {
                    listEditor(text: $env, hint: "Names of environment variables, one per line")
                }
            } else {
                Section {
                    Toggle(isOn: $confineReads) {
                        Text("Confine reads")
                        Text(confineReads
                             ? "Programs read only the project, system folders, what they may write, and the paths below."
                             : "Programs can read everything your account can, except what is hidden.")
                    }
                    Picker("Network", selection: $network) {
                        ForEach(Network.allCases, id: \.self) { Text($0.label) }
                    }
                    TextField("Blocked programs", text: $blocked, prompt: Text("docker kubectl"))
                }
                Section("Services") {
                    Toggle("Block the Keychain", isOn: $blockKeychain)
                    Toggle("Allow the clipboard", isOn: $allowClipboard)
                    Toggle("Allow opening apps, files and links", isOn: $allowOpen)
                }
                if confineReads {
                    Section("Also readable") {
                        listEditor(text: $readable, hint: "Shell and toolchain setup is found automatically.")
                    }
                }
                Section("Writable besides the project") {
                    listEditor(text: $writable, hint: "Caches and tool settings, one path per line.")
                }
                Section("Hidden") {
                    listEditor(text: $hidden, hint: "Neither readable nor writable: credentials, one path per line.")
                }
            }
        }
        .onAppear(perform: load)
        .confirmationDialog("Delete “\(name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.profiles.sandboxes.removeAll { $0.id == profileID }
                dismiss()
            }
        } message: {
            Text("Terminals using it go back to the Project sandbox.")
        }
    }

    private func listEditor(text: Binding<String>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: text)
                .font(.callout.monospaced())
                .frame(minHeight: 70, maxHeight: 140)
                .scrollContentBackground(.hidden)
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func load() {
        let engine: SandboxEngine
        if let profileID, profileID != 0, let profile = store.profiles.sandbox(profileID) {
            name = profile.name
            engine = profile.engine
        } else if profileID == 0 {
            name = "Agents"
            engine = store.profiles.projectEngine
        } else {
            engine = store.profiles.projectEngine
        }
        switch engine {
        case .seatbelt(let s):
            docker = false
            confineReads = s.confineReads
            readable = s.readable.joined(separator: "\n")
            writable = s.writable.joined(separator: "\n")
            hidden = s.hidden.joined(separator: "\n")
            network = s.network
            blocked = s.blocked.joined(separator: " ")
            allowClipboard = s.allowClipboard
            allowOpen = s.allowOpen
            blockKeychain = s.blockKeychain
        case .docker(let d):
            docker = true
            image = d.image
            dockerNetwork = d.network
            mounts = d.mounts.joined(separator: "\n")
            env = d.env.joined(separator: "\n")
        }
    }

    private func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func save() {
        let engine: SandboxEngine = docker
            ? .docker(.init(image: image.trimmingCharacters(in: .whitespaces), network: dockerNetwork,
                            mounts: lines(mounts), env: lines(env)))
            : .seatbelt(.init(
                writable: lines(writable), hidden: lines(hidden), network: network,
                blocked: blocked.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init),
                blockKeychain: blockKeychain, confineReads: confineReads, readable: lines(readable),
                allowClipboard: allowClipboard, allowOpen: allowOpen))
        if isProject {
            store.profiles.projectSandbox = engine
        } else {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            store.profiles.upsert(SandboxProfile(id: profileID ?? 0, name: trimmed.isEmpty ? "Sandbox" : trimmed, engine: engine))
        }
        dismiss()
    }
}
