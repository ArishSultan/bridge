import AppKit
import BridgeCore
import SwiftUI

/// Shown when no other window is open: recent projects, Open Folder and Home.
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
                Text("Terminals your agents can't escape")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
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
                        Label("Home", systemImage: "house")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .help("Terminals in your home folder, outside any project (not sandboxed)")
                }
                .controlSize(.large)
                .frame(width: 220)
                .padding(.bottom, 28)
            }
            .frame(width: 300)

            Divider()

            Group {
                if store.projects.projects.isEmpty {
                    GettingStarted()
                } else {
                    List {
                        Section("Recent Projects") {
                            ForEach(recent) { project in
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
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(minWidth: 320)
        }
        .frame(width: 720, height: 460)
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

    /// Most recently opened first; never-opened ones after, in the order they were added.
    private var recent: [Project] {
        store.projects.projects.enumerated().sorted { a, b in
            switch (a.element.lastOpened, b.element.lastOpened) {
            case let (x?, y?): x > y
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): a.offset < b.offset
            }
        }.map(\.element)
    }
}

/// What a first-time user sees: what Bridge does, in three lines.
private struct GettingStarted: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Getting started").font(.title2.weight(.semibold))
            point("folder", "Open a folder", "It becomes a project with a window of its own.")
            point("checkmark.shield", "Terminals are sandboxed",
                  "Programs in them, coding agents included, can change the project but can't read your other files, SSH keys or the Keychain.")
            point("exclamationmark.shield", "Open terminals when you need them",
                  "For SSH, Docker and deploys, make an open terminal (⌘⇧T). It's marked in orange.")
            Link("How sandboxed terminals work", destination: Links.sandbox)
                .font(.callout)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func point(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
