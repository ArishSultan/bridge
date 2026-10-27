import AppKit
import BridgeCore
import SwiftUI

/// Shown when no other window is open: recent projects, Open Folder and Global.
struct WelcomeWindow: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings

    private var store: Store { .shared }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 14) {
                Spacer()
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                Text("Bridge").font(.largeTitle.weight(.semibold))
                Text("Your projects, servers and terminals")
                    .foregroundStyle(.secondary)
                Spacer()
                VStack(spacing: 8) {
                    Button {
                        store.showOpenPanel()
                    } label: {
                        Label("Open Folder…", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("o")
                    Button {
                        store.openGlobal()
                    } label: {
                        Label("Global", systemImage: "globe")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
                .frame(width: 220)
                .padding(.bottom, 28)
            }
            .frame(width: 300)

            Divider()

            Group {
                if store.projects.projects.isEmpty {
                    ContentUnavailableView(
                        "No projects yet", systemImage: "folder",
                        description: Text("A project is a folder. Open one to start."))
                } else {
                    List {
                        Section("Recent Projects") {
                            ForEach(store.projects.projects) { project in
                                Button {
                                    store.open(project.id)
                                } label: {
                                    HStack(spacing: 10) {
                                        ProjectIcon(project: project, size: 28)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(project.name)
                                            Text(Paths.tilde(project.root.path))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Remove from List", role: .destructive) { store.removeProject(project.id) }
                                        .disabled(store.openWindows.contains(project.id))
                                }
                            }
                            .onMove { store.moveProjects(fromOffsets: $0, toOffset: $1) }
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(minWidth: 320)
        }
        .frame(width: 720, height: 440)
        .onAppear {
            store.openProjectWindow = { [openWindow] id in openWindow(id: "project", value: id) }
            store.openWelcomeWindow = { [openWindow] in openWindow(id: "welcome") }
            store.closeWelcomeWindow = { [dismissWindow] in dismissWindow(id: "welcome") }
            store.openSettingsWindow = { [openSettings] in openSettings() }
            if store.restoreWindows() {
                dismissWindow(id: "welcome")
            }
        }
    }
}
