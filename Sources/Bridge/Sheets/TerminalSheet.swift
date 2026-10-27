import AppKit
import BridgeCore
import SwiftUI

/// New or edit one kind of terminal: a shell, a task, or an SSH session. The kind is chosen
/// before (from the + menu) and can't change here.
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

    enum Kind { case shell, task, ssh }

    enum IsolationChoice: Hashable {
        case project
        case profile(ID)
        case open
    }

    private var store: Store { .shared }

    var body: some View {
        SheetScaffold(title: title, subtitle: project.name, confirm: request.isEdit ? "Save" : "Create", onConfirm: commit) {
            switch kind {
            case .task:
                Section("Runs") {
                    TextField("Command", text: $command, prompt: Text("npm run dev"))
                        .font(.body.monospaced())
                    Toggle("Start when it's opened", isOn: $autoStart)
                    Toggle("Restart when it exits", isOn: $restartOnExit)
                }
            case .ssh:
                Section("Host") {
                    if store.profiles.hosts.isEmpty {
                        Text("Add SSH hosts in Settings → SSH Hosts first.").foregroundStyle(.secondary)
                    } else {
                        Picker("Connect to", selection: $host) {
                            ForEach(store.profiles.hosts) { host in
                                Text(host.displayName).tag(ID?.some(host.id))
                            }
                        }
                    }
                }
            case .shell:
                EmptyView()
            }

            Section {
                TextField("Name", text: $name, prompt: Text("Named after what it runs"))
                TextField("Tag", text: $tag, prompt: Text("Optional, like api"))
                Toggle(isOn: $background) {
                    Text("Keep alive")
                    Text("Keeps running when you switch to another terminal or view.")
                }
            }

            if kind != .ssh {
                Section {
                    LabeledContent(global ? "Folder" : "Folder in project") {
                        HStack {
                            TextField("Folder", text: $folder, prompt: Text("."))
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                            Button("Choose…", action: chooseFolder)
                        }
                    }
                    if !global {
                        Picker("Isolation", selection: $isolation) {
                            Label("Project sandbox", systemImage: "checkmark.shield").tag(IsolationChoice.project)
                            ForEach(store.profiles.sandboxes) { profile in
                                Label("\(profile.name) sandbox", systemImage: profile.engine.isDocker ? "shippingbox" : "checkmark.shield")
                                    .tag(IsolationChoice.profile(profile.id))
                            }
                            Divider()
                            Label("Open, not sandboxed", systemImage: "exclamationmark.shield").tag(IsolationChoice.open)
                        }
                    }
                } footer: {
                    if !global {
                        Text(isolation == .open
                             ? "Open terminals can read and change anything your account can, including other projects and your SSH keys."
                             : "Sandboxed terminals write only inside the project and can't see your credentials.")
                            .foregroundStyle(isolation == .open ? Color.orange : Color.secondary)
                    }
                }
            }

            if let error {
                FormMessage(text: error)
            }
        }
        .onAppear(perform: load)
    }

    private var title: String {
        switch (kind, request.isEdit) {
        case (.shell, false): isolation == .open && !global ? "New Open Shell" : "New Shell"
        case (.task, false): "New Task"
        case (.ssh, false): "New SSH Session"
        case (.shell, true): "Edit Shell"
        case (.task, true): "Edit Task"
        case (.ssh, true): "Edit SSH Session"
        }
    }

    private func load() {
        var spec: TerminalSpec
        switch request.preset {
        case .shell:
            spec = TerminalSpec(isolation: global ? .open : .sandboxed(profile: nil))
        case .openShell:
            spec = TerminalSpec(isolation: .open)
        case .task:
            spec = TerminalSpec(kind: .task(command: "", autoStart: true, restartOnExit: false),
                                isolation: global ? .open : .sandboxed(profile: nil))
        case .spec(let preset):
            spec = preset
        }
        name = spec.name
        tag = spec.tag ?? ""
        background = spec.background
        folder = spec.folder
        switch spec.kind {
        case .shell:
            kind = .shell
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
        case .sandboxed(let id?): isolation = store.profiles.sandbox(id) == nil ? .project : .profile(id)
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
            guard let host else { error = "Choose an SSH host (add hosts in Settings → SSH Hosts)."; return }
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
        let trimmedTag = tag.trimmingCharacters(in: .whitespaces)
        save(TerminalSpec(
            name: name.trimmingCharacters(in: .whitespaces),
            tag: trimmedTag.isEmpty ? nil : trimmedTag,
            kind: terminalKind,
            folder: folder,
            isolation: global || kind == .ssh ? .open : chosenIsolation,
            background: background))
        dismiss()
    }
}
