import AppKit
import BridgeCore
import SwiftUI

@main
struct BridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: "terminal", for: UUID.self) { $id in
            TerminalWindowView(id: id)
        } defaultValue: {
            UUID()
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 960, height: 620)
        .commands { BridgeCommands() }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as a regular app with a Dock icon and menu bar, also when started from a build
        // folder rather than the app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        // Ghostty's keybindings drive tabs; macOS's own window tabbing would duplicate them.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            AppModel.shared.shouldQuit() ? .terminateNow : .terminateCancel
        }
    }
}

/// Menu items for terminals. With a terminal focused, its key bindings (Ghostty's macOS
/// defaults) handle these shortcuts first; the menu covers clicks and other focus.
struct BridgeCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") { AppModel.shared.newWindow(from: AppModel.shared.focusedPane) }
                .keyboardShortcut("n")
            Button("New Tab") { AppModel.shared.newTab() }
                .keyboardShortcut("t")
            Divider()
            Button("Split Right") { splitFocused(.right) }
                .keyboardShortcut("d")
            Button("Split Down") { splitFocused(.down) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
            Button("Close") { AppModel.shared.focusedPane?.surface.requestClose() }
                .keyboardShortcut("w")
            Button("Close Tab") {
                if let tab = AppModel.shared.keyWindow?.selectedTab {
                    AppModel.shared.requestClose(tab)
                }
            }
            .keyboardShortcut("w", modifiers: [.command, .option])
        }
        CommandGroup(after: .toolbar) {
            Button("Bigger") { AppModel.shared.focusedPane?.surface.perform(binding: "increase_font_size:1") }
                .keyboardShortcut("+")
            Button("Smaller") { AppModel.shared.focusedPane?.surface.perform(binding: "decrease_font_size:1") }
                .keyboardShortcut("-")
            Button("Actual Size") { AppModel.shared.focusedPane?.surface.perform(binding: "reset_font_size") }
                .keyboardShortcut("0")
            Divider()
        }
    }

    @MainActor
    private func splitFocused(_ side: SplitDirection) {
        if let pane = AppModel.shared.focusedPane {
            AppModel.shared.split(pane, side: side)
        }
    }
}
