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
        VStack(spacing: 0) {
            Form {
                Section {
                    if isProject {
                        LabeledContent("Name", value: "Project (default)")
                    } else {
                        TextField("Name", text: $name, prompt: Text("Agents"))
                    }
                    Picker("Isolation", selection: $docker) {
                        Text("macOS sandbox").tag(false)
                        Text("Docker container").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .disabled(isProject)
                }

                if docker {
                    Section("Container") {
                        TextField("Image", text: $image, prompt: Text("ubuntu:24.04"))
                        Toggle("Network", isOn: $dockerNetwork)
                        listEditor("Extra mounts", text: $mounts, hint: "One per line: ~/data:/data or ~/models:/models:ro")
                        listEditor("Pass variables", text: $env, hint: "Names of environment variables to pass in, one per line")
                    }
                    Section {
                        Text("The project folder is mounted at /workspace. Nothing else on your Mac is visible inside.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Files") {
                        Toggle("Confine reads", isOn: $confineReads)
                        Text(confineReads
                             ? "Programs read only the project, system folders, what they may write, and the list below."
                             : "Programs can read everything your account can, except what is hidden.")
                            .font(.caption).foregroundStyle(.secondary)
                        if confineReads {
                            listEditor("Also readable", text: $readable, hint: "Shell and toolchain setup is found automatically")
                        }
                        listEditor("Writable besides the project", text: $writable, hint: "Caches and tool settings")
                        listEditor("Hidden", text: $hidden, hint: "Neither readable nor writable: credentials")
                    }
                    Section("Programs and services") {
                        Picker("Network", selection: $network) {
                            ForEach(Network.allCases, id: \.self) { Text($0.label) }
                        }
                        TextField("Blocked programs", text: $blocked, prompt: Text("docker kubectl"))
                        Toggle("Clipboard (pasting with ⌘V always works)", isOn: $allowClipboard)
                        Toggle("Open apps, files and links", isOn: $allowOpen)
                        Toggle("Block the Keychain", isOn: $blockKeychain)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if !isProject && profileID != 0 {
                    Button("Delete…", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 560, height: 640)
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

    private func listEditor(_ title: String, text: Binding<String>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            TextEditor(text: text)
                .font(.callout.monospaced())
                .frame(minHeight: 64, maxHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
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
