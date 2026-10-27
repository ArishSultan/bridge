import AppKit
import BridgeCore
import SwiftUI

/// New Terminal / Edit Terminal: what it runs, where, and how isolated.
struct TerminalSheet: View {
    let project: Project
    let request: TerminalSheetRequest
    let global: Bool
    let save: (TerminalSpec) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind: Kind = .shell
    @State private var name = ""
    @State private var tag = ""
    @State private var background = false
    @State private var command = ""
    @State private var autoStart = false
    @State private var restartOnExit = false
    @State private var host: ID?
    @State private var folder = "."
    @State private var isolation: IsolationChoice = .project
    @State private var error: String?

    enum Kind: String, CaseIterable, Identifiable {
        case shell = "Shell", task = "Task", ssh = "SSH"
        var id: Self { self }
    }

    enum IsolationChoice: Hashable {
        case project
        case profile(ID)
        case open
    }

    private var store: Store { .shared }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if request.isEdit {
                        LabeledContent("Type", value: kind.rawValue)
                    } else {
                        Picker("Type", selection: $kind) {
                            ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    TextField("Name", text: $name, prompt: Text("Named after what it runs"))
                    TextField("Tag", text: $tag, prompt: Text("api"))
                    Toggle("Keep alive", isOn: $background)
                        .help("Keeps running when you switch to another terminal or view")
                }

                switch kind {
                case .task:
                    Section("Task") {
                        TextField("Command", text: $command, prompt: Text("npm run dev"))
                            .font(.body.monospaced())
                        Toggle("Start when it is opened", isOn: $autoStart)
                        Toggle("Restart when it exits", isOn: $restartOnExit)
                    }
                case .ssh:
                    Section("SSH host") {
                        if store.profiles.hosts.isEmpty {
                            Text("Add SSH hosts in the Global window first.").foregroundStyle(.secondary)
                        } else {
                            Picker("Host", selection: $host) {
                                Text("Choose a host").tag(ID?.none)
                                ForEach(store.profiles.hosts) { host in
                                    Text("\(host.displayName) · \(host.address)").tag(ID?.some(host.id))
                                }
                            }
                        }
                    }
                case .shell:
                    EmptyView()
                }

                if kind != .ssh {
                    Section {
                        LabeledContent(global ? "Folder in your home folder" : "Folder in the project") {
                            HStack {
                                TextField("", text: $folder, prompt: Text("."))
                                    .labelsHidden()
                                Button("Choose…", action: chooseFolder)
                            }
                        }
                        if !global {
                            Picker("Isolation", selection: $isolation) {
                                Text("Project sandbox (writes only inside the project)").tag(IsolationChoice.project)
                                ForEach(store.profiles.sandboxes) { profile in
                                    Text("\(profile.name) sandbox\(profile.engine.isDocker ? " (Docker)" : "")")
                                        .tag(IsolationChoice.profile(profile.id))
                                }
                                Text("Open — not sandboxed").tag(IsolationChoice.open)
                            }
                            .pickerStyle(.radioGroup)
                            if isolation == .open {
                                Label("Open terminals can read and change anything your account can, including other projects and your SSH keys.",
                                      systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .font(.callout)
                            }
                        }
                    }
                }

                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(request.isEdit ? "Save" : "Create", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 520)
        .navigationTitle(request.isEdit ? "Edit Terminal" : "New Terminal")
        .onAppear(perform: load)
    }

    private func load() {
        var spec: TerminalSpec
        switch request.preset {
        case .shell:
            spec = TerminalSpec(isolation: global ? .open : .sandboxed(profile: nil))
        case .openShell:
            spec = TerminalSpec(isolation: .open)
        case .task:
            spec = TerminalSpec(kind: .task(command: "", autoStart: false, restartOnExit: false),
                                isolation: global ? .open : .sandboxed(profile: nil))
        case .spec(let preset):
            spec = preset
        }
        name = spec.name
        tag = spec.tag ?? ""
        background = spec.background
        folder = spec.folder
        switch spec.kind {
        case .shell: kind = .shell
        case .task(let c, let a, let r):
            kind = .task
            command = c
            autoStart = a
            restartOnExit = r
        case .ssh(let h):
            kind = .ssh
            host = h
        }
        switch spec.isolation {
        case .open: isolation = .open
        case .sandboxed(nil): isolation = .project
        case .sandboxed(let id?): isolation = .profile(id)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = project.folder(folder)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let root = project.root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == root {
            folder = "."
        } else if path.hasPrefix(root + "/") {
            folder = String(path.dropFirst(root.count + 1))
        } else {
            error = global ? "The folder must be inside your home folder." : "The folder must be inside the project."
        }
    }

    private func commit() {
        let command = command.trimmingCharacters(in: .whitespaces)
        let folder = folder.trimmingCharacters(in: .whitespaces).isEmpty ? "." : folder.trimmingCharacters(in: .whitespaces)

        let terminalKind: TerminalKind
        switch kind {
        case .shell:
            terminalKind = .shell
        case .task:
            guard !command.isEmpty else { error = "Enter the command this terminal runs."; return }
            terminalKind = .task(command: command, autoStart: autoStart, restartOnExit: restartOnExit)
        case .ssh:
            guard let host else { error = "Choose an SSH host (add hosts in Global)."; return }
            terminalKind = .ssh(host: host)
        }

        if kind != .ssh {
            let parts = folder.split(separator: "/")
            var isDir: ObjCBool = false
            guard !folder.hasPrefix("/"), !parts.contains(".."),
                  FileManager.default.fileExists(atPath: project.folder(folder).path, isDirectory: &isDir), isDir.boolValue
            else {
                error = global ? "The folder must be inside your home folder." : "The folder must be inside the project."
                return
            }
        }

        let chosenIsolation: Isolation = switch isolation {
        case .project: .sandboxed(profile: nil)
        case .profile(let id): .sandboxed(profile: id)
        case .open: .open
        }
        let spec = TerminalSpec(
            name: name.trimmingCharacters(in: .whitespaces),
            tag: tag.trimmingCharacters(in: .whitespaces).isEmpty ? nil : tag.trimmingCharacters(in: .whitespaces),
            kind: terminalKind,
            folder: folder,
            isolation: global ? .open : chosenIsolation,
            background: background)
        save(spec)
        dismiss()
    }
}
