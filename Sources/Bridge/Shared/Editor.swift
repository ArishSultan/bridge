import AppKit
import BridgeCore

/// An app a project folder can be opened in.
struct Editor: Hashable {
    let name: String
    let bundleID: String

    /// Editors Bridge knows, in the order "first editor found" tries them.
    static let known = [
        Editor(name: "Visual Studio Code", bundleID: "com.microsoft.VSCode"),
        Editor(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92"),
        Editor(name: "Zed", bundleID: "dev.zed.Zed"),
        Editor(name: "Xcode", bundleID: "com.apple.dt.Xcode"),
        Editor(name: "Sublime Text", bundleID: "com.sublimetext.4"),
        Editor(name: "Nova", bundleID: "com.panic.Nova"),
        Editor(name: "BBEdit", bundleID: "com.barebones.bbedit"),
        Editor(name: "IntelliJ IDEA", bundleID: "com.jetbrains.intellij"),
        Editor(name: "Windsurf", bundleID: "com.exafunction.windsurf"),
    ]

    /// The known editors that are installed.
    @MainActor static var installed: [Editor] {
        known.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }

    /// The editor chosen in Settings, else the first one installed.
    @MainActor static var preferred: Editor? {
        let chosen = Store.shared.settings.editor
        return installed.first { $0.bundleID == chosen } ?? installed.first
    }

    /// Open a folder in this editor.
    @MainActor func open(_ folder: URL) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
