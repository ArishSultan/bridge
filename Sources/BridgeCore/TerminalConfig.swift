import Foundation

/// Turns Bridge's settings into libghostty configuration entries (`key = value` lines, in the
/// syntax of a Ghostty config file).
///
/// libghostty owns the terminal, so this is the one place where a Bridge setting becomes a
/// terminal behavior. Keybindings are left at Ghostty's macOS defaults (⌘D split, ⌘T tab, ⌘W
/// close, ⌘[ / ⌘] move between splits); the app handles the actions they produce.
public enum TerminalConfig {
    /// One `key = value` entry. Repeatable keys (palette, font-feature) appear once per value.
    public struct Entry: Equatable, Sendable {
        public let key: String
        public let value: String

        public init(_ key: String, _ value: String) {
            self.key = key
            self.value = value
        }
    }

    /// The entries for `settings`, with "match-app" schemes resolved for a dark or light window.
    /// `naturalLineHeight` is the font's own line height as a multiple of its size (from its
    /// metrics), so v1's line height (a multiple of the size) maps exactly.
    public static func entries(for settings: Settings, dark: Bool, naturalLineHeight: Double = 1.2) -> [Entry] {
        var entries: [Entry] = []
        func add(_ key: String, _ value: String) { entries.append(Entry(key, value)) }
        func add(_ key: String, _ value: Bool) { add(key, value ? "true" : "false") }

        // Font. v1's line height multiplied the font size; Ghostty adjusts the font's own line
        // height, so scale by the ratio of the two.
        add("font-family", settings.fontFamily)
        add("font-size", format(settings.fontSize))
        let cellHeight = (settings.lineHeight / max(naturalLineHeight, 0.5) - 1) * 100
        add("adjust-cell-height", "\(Int(cellHeight.rounded()))%")
        if settings.letterSpacing != 0 {
            add("adjust-cell-width", "\(Int(settings.letterSpacing.rounded()))")
        }
        if !settings.fontLigatures {
            for feature in ["-calt", "-liga", "-dlig"] {
                add("font-feature", feature)
            }
        }
        if settings.boldIsBright {
            add("bold-color", "bright")
        }

        // Colors.
        let scheme = ColorScheme.resolve(settings.colorScheme, dark: dark)
        add("background", scheme.background.hexString)
        add("foreground", scheme.foreground.hexString)
        if let cursor = scheme.cursor {
            add("cursor-color", cursor.hexString)
        }
        for (index, color) in (scheme.ansi ?? []).enumerated() {
            add("palette", "\(index)=\(color.hexString)")
        }

        // Window.
        let padding = "\(Int(settings.padding.rounded()))"
        add("window-padding-x", padding)
        add("window-padding-y", padding)
        add("window-padding-balance", true)
        let opacity = settings.backgroundEffect == .opaque ? 1 : settings.backgroundOpacity
        add("background-opacity", format(opacity))
        add("background-blur", settings.backgroundEffect == .blurred)

        // Cursor and mouse.
        add("cursor-style", cursorStyle(settings.cursorShape))
        add("cursor-style-blink", settings.cursorBlink)
        add("mouse-hide-while-typing", settings.hidePointerWhileTyping)
        add("copy-on-select", settings.copyOnSelect ? "clipboard" : "false")
        add("cursor-click-to-move", settings.clickToMoveCursor)
        let scroll = settings.scrollMultiplier
        add("mouse-scroll-multiplier", "precision:\(format(scroll)),discrete:\(format(scroll * 3))")

        // Keyboard.
        add("macos-option-as-alt", settings.optionAsAlt)

        // Shell.
        let shell = settings.shell.trimmingCharacters(in: .whitespaces)
        if !shell.isEmpty {
            add("command", shell)
        }
        let directory = settings.workingDirectory.trimmingCharacters(in: .whitespaces)
        add("working-directory", directory.isEmpty ? "home" : directory)
        add("window-inherit-working-directory", true)
        add("scrollback-limit", "\(scrollbackBytes(lines: settings.scrollbackLines))")
        add("clipboard-paste-protection", settings.pasteProtection)
        // Bridge installs its own shell integration (see ShellIntegration).
        add("shell-integration", "none")
        add("confirm-close-surface", true)
        add("mouse-reporting", settings.mouseReporting)

        // The app's menus own these shortcuts (new terminal, splits, items, windows); without a
        // Ghostty binding the key goes on to the menu. Ghostty keeps copy and paste, font size,
        // clearing, scrolling and text editing keys.
        for trigger in appShortcuts {
            add("keybind", "\(trigger)=unbind")
        }

        return entries
    }

    /// Ghostty's default bindings for keys the app's menus handle.
    static let appShortcuts: [String] = [
        "super+t", "super+shift+t", "super+n", "super+shift+n", "super+o",
        "super+d", "super+shift+d", "super+w", "super+shift+w", "super+alt+w",
        "super+[", "super+]", "super+shift+[", "super+shift+]",
        "ctrl+tab", "ctrl+shift+tab", "super+b", "super+shift+g", "super+shift+e", "super+alt+c",
    ] + (1...9).map { "super+\($0)" }

    /// The entries as the text of a Ghostty config file.
    public static func fileContents(for settings: Settings, dark: Bool, naturalLineHeight: Double = 1.2) -> String {
        entries(for: settings, dark: dark, naturalLineHeight: naturalLineHeight)
            .map { "\($0.key) = \($0.value)" }
            .joined(separator: "\n") + "\n"
    }

    /// Ghostty limits scrollback in bytes, not lines. A line of a wide terminal takes roughly 2 KB
    /// in Ghostty's page format, so this keeps about the requested number of lines.
    static func scrollbackBytes(lines: Int) -> Int {
        max(lines, 500) * 2_000
    }

    static func cursorStyle(_ shape: CursorShape) -> String {
        switch shape {
        case .bar: "bar"
        case .block: "block"
        case .underline: "underline"
        case .hollow: "block_hollow"
        }
    }

    /// A number without a trailing `.0` for whole values.
    static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
