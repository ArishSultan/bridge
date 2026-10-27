import AppKit
import BridgeCore
import SwiftUI

@main
struct BridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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

/// The app's menu commands, acting on the project window in front.
struct BridgeCommands: Commands {
    @FocusedValue(\.windowController) private var controller
    @Environment(\.openWindow) private var openWindow

    private var store: Store { .shared }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Folder…") { store.showOpenPanel() }
                .keyboardShortcut("o")
            Divider()
            Button("New Terminal") { controller?.newTerminal(.shell) }
                .keyboardShortcut("t")
                .disabled(controller == nil)
            Button("New Open Terminal") { controller?.newTerminal(.openShell) }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(controller == nil)
            Button("New Task") { controller?.newTerminal(.task) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(controller == nil)
            Divider()
            Button("Split Right") { controller?.split(.horizontal) }
                .keyboardShortcut("d")
                .disabled(controller == nil)
            Button("Split Down") { controller?.split(.vertical) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(controller == nil)
            Divider()
            Button("Close Terminal") { controller?.closeFocused() }
                .keyboardShortcut("w")
                .disabled(controller == nil)
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }

        CommandGroup(after: .sidebar) {
            Button("Toggle Sidebar") { store.sidebarOpen.toggle() }
                .keyboardShortcut("b")
            Divider()
            Button("Next Terminal") { controller?.cyclePanes(1) }
                .keyboardShortcut("]")
                .disabled(controller == nil)
            Button("Previous Terminal") { controller?.cyclePanes(-1) }
                .keyboardShortcut("[")
                .disabled(controller == nil)
            Button("Next Item") { controller?.cycleItems(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(controller == nil)
            Button("Previous Item") { controller?.cycleItems(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(controller == nil)
            Button("Next Item") { controller?.cycleItems(1) }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled(controller == nil)
            Button("Previous Item") { controller?.cycleItems(-1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled(controller == nil)
            Divider()
            ForEach(1...9, id: \.self) { index in
                Button("Go to Item \(index)") { controller?.goToItem(index - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index)")))
                    .disabled(controller == nil)
            }
        }

        CommandGroup(after: .windowList) {
            Divider()
            Button("Global") { store.openGlobal() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button("Welcome") { openWindow(id: "welcome") }
        }
    }
}
