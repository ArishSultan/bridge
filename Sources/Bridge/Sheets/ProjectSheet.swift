import AppKit
import BridgeCore
import SwiftUI
import UniformTypeIdentifiers

/// Edit Project: its name, icon, color and folder.
struct ProjectSheet: View {
    let project: Project

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var icon: String?
    @State private var color: String?
    @State private var dir = ""
    @State private var emoji = ""
    @State private var folderMissing = false
    @FocusState private var emojiFocused: Bool

    var body: some View {
        SheetScaffold(title: "Edit Project", confirm: "Save", onConfirm: save) {
            Section {
                HStack(spacing: 14) {
                    ProjectIcon(project: preview, size: 52)
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Name", text: $name, prompt: Text("Named after the folder"))
                            .textFieldStyle(.plain)
                            .font(.title3.weight(.semibold))
                        HStack(spacing: 8) {
                            ColorSwatch(color: nil, selected: color == nil) { color = nil }
                            ForEach(ProjectColor.allCases) { option in
                                ColorSwatch(color: option, selected: color == option.rawValue) { color = option.rawValue }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Icon") {
                LabeledContent("Emoji") {
                    HStack {
                        TextField("Emoji", text: $emoji, prompt: Text("🚀"))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                            .focused($emojiFocused)
                            .onChange(of: emoji) {
                                // Keep only the last character typed or picked.
                                if let last = emoji.last {
                                    icon = String(last)
                                    if emoji.count > 1 { emoji = String(last) }
                                }
                            }
                        Button("Emoji & Symbols…") {
                            emojiFocused = true
                            NSApp.orderFrontCharacterPalette(nil)
                        }
                    }
                }
                HStack {
                    Button("Import Image…", action: importIcon)
                    Spacer()
                    if icon != nil {
                        Button("No Icon", role: .destructive) {
                            icon = nil
                            emoji = ""
                        }
                    }
                }
            }
            Section {
                LabeledContent("Folder") {
                    HStack {
                        TextField("Folder", text: $dir)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                        Button("Choose…", action: chooseFolder)
                    }
                }
            } footer: {
                Text(folderMissing ? "Folder not found." : Paths.expandHome(dir))
                    .foregroundStyle(folderMissing ? Color.red : Color.secondary)
            }
        }
        .onAppear {
            name = project.name
            icon = project.icon
            color = project.color
            dir = project.dir
            if let icon = project.icon, !icon.hasPrefix("file:") { emoji = icon }
        }
    }

    private var preview: Project {
        var preview = project
        preview.icon = icon
        preview.color = color
        return preview
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: Paths.expandHome(dir))
        guard panel.runModal() == .OK, let url = panel.url else { return }
        dir = Paths.tilde(url.path)
        folderMissing = false
    }

    private func importIcon() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.svg, .png, .jpeg, .image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let value = try? ProjectIcons.importIcon(from: url) {
            icon = value
            emoji = ""
        }
    }

    private func save() {
        let path = Paths.expandHome(dir.trimmingCharacters(in: .whitespaces))
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            folderMissing = true
            return
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        Store.shared.update(project.id) { project in
            project.name = trimmed.isEmpty ? URL(fileURLWithPath: path).lastPathComponent : trimmed
            project.icon = icon
            project.color = color
            project.dir = Paths.tilde(path)
        }
        dismiss()
    }
}

private struct ColorSwatch: View {
    let color: ProjectColor?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(color?.color ?? Color.clear)
                    .overlay(Circle().strokeBorder(.secondary.opacity(color == nil ? 0.6 : 0), lineWidth: 1))
                if color == nil {
                    Image(systemName: "slash.circle").foregroundStyle(.secondary)
                }
            }
            .frame(width: 18, height: 18)
            .padding(2)
            .overlay(Circle().strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .help(color?.rawValue.capitalized ?? "No color")
    }
}
