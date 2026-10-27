import AppKit
import BridgeCore
import SwiftUI

@main
struct BridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Bridge reopens its own windows (from projects.json). macOS's window restoration would
        // otherwise, after a crash or force quit, restore "no windows" and keep even the
        // Welcome window from opening.
        UserDefaults.standard.register(defaults: [
            "ApplePersistenceIgnoreState": true,
            "NSQuitAlwaysKeepsWindows": false,
        ])
    }

    var body: some Scene {
        // The first scene opens at launch; it reopens the windows of the last session and closes
        // itself when there were any.
        Window("Welcome to Bridge", id: "welcome") {
            WelcomeWindow()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.presented)

        WindowGroup("Project", id: "project", for: ID.self) { $id in
            if let id {
                ProjectWindow(projectID: id)
            }
        }
        .defaultSize(width: 1080, height: 700)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        .commands { BridgeCommands() }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A regular app with a Dock icon and menu bar, also when started from a build folder.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        NSWindow.allowsAutomaticWindowTabbing = false
        // Start libghostty and load the projects before the first window draws.
        MainActor.assumeIsolated { _ = Store.shared }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { Store.shared.reportLaunchProblems() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let store = Store.shared
            if store.anyRunning {
                let alert = NSAlert()
                alert.messageText = "Quit Bridge?"
                alert.informativeText = "Terminals are still running; quitting stops them."
                alert.addButton(withTitle: "Quit")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            }
            store.rememberOpenWindows()
            store.shutdown()
            return .terminateNow
        }
    }

    /// Closing the last window doesn't quit: forwards and background terminals keep going.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            MainActor.assumeIsolated { Store.shared.openWelcomeWindow?() }
        }
        return true
    }
}

// MARK: - Menus

extension FocusedValues {
    @Entry var windowController: WindowController?
}

/// The app's menu commands, acting on the project window in front. Every toolbar and sidebar
/// action is here too, with the standard Mac shortcuts where there is one.
struct BridgeCommands: Commands {
    @FocusedValue(\.windowController) private var controller
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openURL) private var openURL

    private var store: Store { .shared }
    private var noWindow: Bool { controller == nil }
    private var noTerminal: Bool { controller?.focusedSurface == nil }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Folder…") { store.showOpenPanel() }
                .keyboardShortcut("o")
            Divider()
            Button(controller?.isGlobal == true ? "New Terminal" : "New Sandboxed Terminal") { controller?.newShell() }
                .keyboardShortcut("t")
                .disabled(noWindow)
            Button("New Terminal…") { controller?.newTerminal(.shell) }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(noWindow)
            Button("New Task…") { controller?.newTerminal(.task) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(noWindow)
            Menu("New Agent Terminal") {
                ForEach(Agent.allCases) { agent in
                    let button = Button(agent.name) {
                        if let controller { store.newAgentTerminal(agent, in: controller.projectID) }
                    }
                    if agent == .claude {
                        button.keyboardShortcut("c", modifiers: [.command, .option])
                    } else {
                        button
                    }
                }
            }
            .disabled(noWindow)
            Divider()
            Button("Split Right") { controller?.split(.horizontal) }
                .keyboardShortcut("d")
                .disabled(noWindow)
            Button("Split Down") { controller?.split(.vertical) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(noWindow)
            Divider()
            Button("Close Terminal") { controller?.closeFocused() }
                .keyboardShortcut("w")
                .disabled(noWindow)
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }

        CommandGroup(after: .textEditing) {
            Menu("Find") {
                Button("Find…") { controller?.focusedSurface?.startSearch() }
                    .keyboardShortcut("f")
                Button("Find Next") { controller?.focusedSurface?.searchNext() }
                    .keyboardShortcut("g")
                Button("Find Previous") { controller?.focusedSurface?.searchNext(backwards: true) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
            }
            .disabled(noTerminal)
            Button("Clear Scrollback") { _ = controller?.focusedSurface?.perform(binding: "clear_screen") }
                .keyboardShortcut("k")
                .disabled(noTerminal)
        }

        CommandGroup(after: .sidebar) {
            Divider()
            Button("Bigger") { _ = controller?.focusedSurface?.perform(binding: "increase_font_size:1") }
                .keyboardShortcut("+")
                .disabled(noTerminal)
            Button("Smaller") { _ = controller?.focusedSurface?.perform(binding: "decrease_font_size:1") }
                .keyboardShortcut("-")
                .disabled(noTerminal)
            Button("Actual Size") { _ = controller?.focusedSurface?.perform(binding: "reset_font_size") }
                .keyboardShortcut("0")
                .disabled(noTerminal)
            Divider()
            Button("Next in Sidebar") { controller?.cycleItems(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(noWindow)
            Button("Previous in Sidebar") { controller?.cycleItems(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(noWindow)
            Button("Next Pane") { controller?.cyclePanes(1) }
                .keyboardShortcut("]")
                .disabled(noWindow)
            Button("Previous Pane") { controller?.cyclePanes(-1) }
                .keyboardShortcut("[")
                .disabled(noWindow)
            Menu("Go To") {
                ForEach(1...9, id: \.self) { index in
                    Button(itemTitle(index)) { controller?.goToItem(index - 1) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index)")))
                        .disabled((controller?.project?.views.count ?? 0) < index)
                }
            }
            .disabled(noWindow)
            Divider()
            Button("Command History…") { controller?.historyPane = controller?.focusedPane }
                .disabled(controller?.focusedPane == nil)
        }

        CommandGroup(after: .windowList) {
            Divider()
            Button("Home") { store.openGlobal() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Welcome") { openWindow(id: "welcome") }
        }

        CommandGroup(replacing: .help) {
            Button("Bridge Help") { openURL(Links.help) }
            Button("How Sandboxed Terminals Work") { openURL(Links.sandbox) }
            Button("Keyboard Shortcuts") {
                store.settingsTab = .keyboard
                openSettings()
            }
            Divider()
            Button("Report an Issue…") { openURL(Links.issues) }
        }
    }

    /// "1  web" for the first item of the window in front.
    private func itemTitle(_ index: Int) -> String {
        guard let project = controller?.project, index <= project.views.count else { return "Item \(index)" }
        return store.itemName(project.views[index - 1], in: project)
    }
}

/// Where the documentation lives.
enum Links {
    static let repository = URL(string: "https://github.com/ArishSultan/bridge")!
    static let help = URL(string: "https://github.com/ArishSultan/bridge#readme")!
    static let sandbox = URL(string: "https://github.com/ArishSultan/bridge/blob/main/docs/sandbox.md")!
    static let issues = URL(string: "https://github.com/ArishSultan/bridge/issues/new")!
}
