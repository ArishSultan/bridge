import AppKit
import BridgeCore
import SwiftUI

/// The Settings window's pages.
enum SettingsTab: String, Hashable {
    case appearance, prompt, cursor, completions, keyboard, shell, hosts, sandboxes, vault
}

/// Settings, applied live to every terminal as they change, and what every project shares: SSH
/// hosts, sandboxes and Vaultwarden.
struct SettingsView: View {
    @Bindable private var store = Store.shared

    var body: some View {
        TabView(selection: $store.settingsTab) {
            Tab("Appearance", systemImage: "paintpalette", value: .appearance) { AppearancePage() }
            Tab("Prompt", systemImage: "chevron.right.square", value: .prompt) { PromptPage() }
            Tab("Mouse", systemImage: "cursorarrow", value: .cursor) { CursorPage() }
            Tab("Completions", systemImage: "text.badge.plus", value: .completions) { CompletionsPage() }
            Tab("Keyboard", systemImage: "keyboard", value: .keyboard) { KeyboardPage() }
            Tab("Shell", systemImage: "terminal", value: .shell) { ShellPage() }
            Tab("SSH Hosts", systemImage: "server.rack", value: .hosts) { SharedPageView(page: .hosts) }
            Tab("Sandboxes", systemImage: "checkmark.shield", value: .sandboxes) { SharedPageView(page: .sandboxes) }
            Tab("Vaultwarden", systemImage: "key.viewfinder", value: .vault) { SharedPageView(page: .vault) }
        }
        .frame(minWidth: 720, idealWidth: 760, minHeight: 520, idealHeight: 600)
    }
}

/// A binding to one setting on the shared store.
@MainActor
private func setting<Value>(_ keyPath: WritableKeyPath<BridgeCore.Settings, Value>) -> Binding<Value> {
    Binding(
        get: { Store.shared.settings[keyPath: keyPath] },
        set: { Store.shared.settings[keyPath: keyPath] = $0 })
}

@MainActor
private var settings: BridgeCore.Settings { Store.shared.settings }

private struct SliderRow: View {
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: step)
                Text(format(value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
        }
    }
}

private struct AppearancePage: View {
    private static let monospacedFonts: [String] = {
        let manager = NSFontManager.shared
        return manager.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 12) else { return false }
            return font.isFixedPitch || manager.traits(of: font).contains(.fixedPitchFontMask)
        }
    }()

    var body: some View {
        Form {
            Section("Theme") {
                Picker("App theme", selection: setting(\.appTheme)) {
                    ForEach(AppTheme.allCases, id: \.self) { Text($0.label) }
                }
                Picker("Color scheme", selection: setting(\.colorScheme)) {
                    ForEach(BridgeCore.ColorScheme.options, id: \.id) { Text($0.name).tag($0.id) }
                    if !BridgeCore.ColorScheme.ghosttyThemes.isEmpty {
                        Section("Ghostty Themes") {
                            ForEach(BridgeCore.ColorScheme.ghosttyThemes) { Text($0.name).tag($0.id) }
                        }
                    }
                }
                Toggle("Bold text in bright colors", isOn: setting(\.boldIsBright))
            }
            Section("Font") {
                Picker("Family", selection: setting(\.fontFamily)) {
                    let current = settings.fontFamily
                    ForEach(Self.monospacedFonts.contains(current) ? Self.monospacedFonts : [current] + Self.monospacedFonts,
                            id: \.self) { Text($0).tag($0) }
                }
                LabeledContent("Size") {
                    Stepper(value: setting(\.fontSize), in: BridgeCore.Settings.minFontSize...BridgeCore.Settings.maxFontSize) {
                        Text("\(Int(settings.fontSize)) pt").monospacedDigit()
                    }
                }
                SliderRow(title: "Line height", value: setting(\.lineHeight), range: 0.8...3, step: 0.05) {
                    String(format: "%.2f", $0)
                }
                SliderRow(title: "Letter spacing", value: setting(\.letterSpacing), range: -2...10, step: 1) {
                    "\(Int($0)) px"
                }
                Toggle("Ligatures", isOn: setting(\.fontLigatures))
            }
            Section("Window") {
                SliderRow(title: "Padding", value: setting(\.padding), range: 0...64, step: 1) { "\(Int($0)) pt" }
                Picker("Terminal background", selection: setting(\.backgroundEffect)) {
                    ForEach(BackgroundEffect.allCases, id: \.self) { Text($0.label) }
                }
                if settings.backgroundEffect != .opaque {
                    SliderRow(title: "Opacity", value: setting(\.backgroundOpacity), range: 0.2...1, step: 0.05) {
                        "\(Int($0 * 100))%"
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PromptPage: View {
    var body: some View {
        Form {
            Section {
                Picker("Prompt", selection: setting(\.promptStyle)) {
                    ForEach(PromptStyle.allCases, id: \.self) { Text($0.label) }
                }
                if settings.promptStyle == .custom {
                    TextField("Pattern", text: setting(\.promptTemplate))
                        .font(.body.monospaced())
                }
                Toggle("Hide the % marker after output without a newline", isOn: setting(\.hidePartialLineMarker))
            } footer: {
                Text("Applies to new zsh and bash terminals with shell integration on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Pattern tokens") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    tokenRow("{dir}", "Current folder name")
                    tokenRow("{path}", "Full path, ~ for home")
                    tokenRow("{git}", "Git branch")
                    tokenRow("{user}  {host}", "User and computer name")
                    tokenRow("{time}", "Time (HH:MM)")
                    tokenRow("{symbol}", "❯")
                    tokenRow("{newline}", "A line break")
                    tokenRow("{red} {green} … {gray}", "Colors; {bold} and {reset}")
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
    }

    private func tokenRow(_ token: String, _ meaning: String) -> some View {
        GridRow {
            Text(token).font(.callout.monospaced())
            Text(meaning).foregroundStyle(.secondary)
        }
    }
}

private struct CursorPage: View {
    var body: some View {
        Form {
            Section("Cursor") {
                Picker("Style", selection: setting(\.cursorShape)) {
                    ForEach(CursorShape.allCases, id: \.self) { Text($0.label) }
                }
                Toggle("Blink", isOn: setting(\.cursorBlink))
            }
            Section("Pointer") {
                Picker("Style", selection: setting(\.pointerStyle)) {
                    ForEach(PointerStyle.allCases, id: \.self) { Text($0.label) }
                }
                Toggle("Hide while typing", isOn: setting(\.hidePointerWhileTyping))
            }
            Section("Mouse") {
                Toggle("Option-click moves the cursor", isOn: setting(\.clickToMoveCursor))
                Toggle("Copy selected text", isOn: setting(\.copyOnSelect))
                Toggle("Let programs use the mouse", isOn: setting(\.mouseReporting))
                SliderRow(title: "Scroll speed", value: setting(\.scrollMultiplier), range: 0.25...4, step: 0.25) {
                    String(format: "%.2g×", $0)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct CompletionsPage: View {
    var body: some View {
        Form {
            Section {
                Toggle("Suggest from history as you type", isOn: setting(\.autosuggestions))
                Toggle("Tab opens Bridge's completions", isOn: setting(\.tabCompletions))
                Picker("⌃R at a prompt opens", selection: setting(\.controlR)) {
                    ForEach(ControlRHandler.allCases, id: \.self) { Text($0.label) }
                }
                Toggle("Show completions as you type", isOn: setting(\.completionsAsYouType))
                Toggle("Include your shell's own history", isOn: setting(\.importShellHistory))
            } footer: {
                Text("Suggestions and the completion menu work in zsh. → or End accepts a suggestion, ⌥→ its next word.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct KeyboardPage: View {
    var body: some View {
        Form {
            Section {
                Toggle("Use Option as Meta (Alt)", isOn: setting(\.optionAsAlt))
            } footer: {
                Text("Off: Option types special characters (like ©). On: it sends Alt, for shell and editor shortcuts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("App") {
                ForEach(Shortcut.app) { shortcut($0.keys, $0.meaning) }
            }
            Section("Terminal") {
                ForEach(Shortcut.terminal) { shortcut($0.keys, $0.meaning) }
            }
        }
        .formStyle(.grouped)
    }

    private func shortcut(_ keys: String, _ meaning: String) -> some View {
        LabeledContent(meaning) { Text(keys).monospaced().foregroundStyle(.secondary) }
    }
}

/// The shortcuts, listed once for the Keyboard page (and the README).
struct Shortcut: Identifiable {
    let keys: String
    let meaning: String
    var id: String { keys }

    static let app = [
        Shortcut(keys: "⌘T", meaning: "New sandboxed terminal"),
        Shortcut(keys: "⌘⇧T", meaning: "New terminal of any kind…"),
        Shortcut(keys: "⌘⇧E", meaning: "New task…"),
        Shortcut(keys: "⌘⌥C", meaning: "New Claude Code terminal"),
        Shortcut(keys: "⌘D / ⌘⇧D", meaning: "Split right / down"),
        Shortcut(keys: "⌘W", meaning: "Close the terminal (⌘Z brings it back)"),
        Shortcut(keys: "⌘⇧W", meaning: "Close the window"),
        Shortcut(keys: "⌘] / ⌘[", meaning: "Next / previous pane of a split"),
        Shortcut(keys: "⌃Tab, ⌘⇧] / ⌘⇧[", meaning: "Next / previous in the sidebar"),
        Shortcut(keys: "⌘1 … ⌘9", meaning: "Go to a terminal in the sidebar"),
        Shortcut(keys: "⌘O", meaning: "Open a folder as a project"),
        Shortcut(keys: "⌘⇧H", meaning: "The Home window"),
        Shortcut(keys: "⌃⌘S", meaning: "Show or hide the sidebar"),
        Shortcut(keys: "⌃R", meaning: "Command history (see Completions)"),
        Shortcut(keys: "⌘,", meaning: "Settings"),
    ]

    static let terminal = [
        Shortcut(keys: "⌘C / ⌘V", meaning: "Copy / paste"),
        Shortcut(keys: "⌘F, ⌘G / ⌘⇧G", meaning: "Find in the scrollback, next / previous match"),
        Shortcut(keys: "⌘K", meaning: "Clear the scrollback"),
        Shortcut(keys: "⌘+ / ⌘- / ⌘0", meaning: "Font size"),
        Shortcut(keys: "⌘↑ / ⌘↓", meaning: "Jump to the previous / next prompt"),
        Shortcut(keys: "⌘-click", meaning: "Open a link"),
    ]
}

private struct ShellPage: View {
    var body: some View {
        Form {
            Section("Apps") {
                Picker("Open projects in", selection: setting(\.editor)) {
                    Text("First editor found").tag("")
                    ForEach(Editor.installed, id: \.bundleID) { editor in
                        Text(editor.name).tag(editor.bundleID)
                    }
                }
            }
            Section("Session") {
                TextField("Shell", text: setting(\.shell), prompt: Text("Login shell"))
                TextField("Start in", text: setting(\.workingDirectory), prompt: Text("Home folder"))
                LabeledContent("Scrollback lines") {
                    TextField("", value: setting(\.scrollbackLines), format: .number)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                }
            }
            Section("Notifications") {
                Toggle("When a long command finishes", isOn: setting(\.notifyLongCommands))
                LabeledContent("Long means at least") {
                    Stepper(value: setting(\.notifyAfterSecs), in: 1...3600) {
                        Text("\(settings.notifyAfterSecs) s").monospacedDigit()
                    }
                }
                .disabled(!settings.notifyLongCommands)
                Toggle("When a terminal rings the bell", isOn: setting(\.notifyOnBell))
            }
            Section("Behavior") {
                Toggle("Shell integration", isOn: setting(\.shellIntegration))
                Toggle("Flash on the bell", isOn: setting(\.visualBell))
                Toggle("Project folder as ~ in sandboxed shells", isOn: setting(\.projectIsHome))
                Toggle("Confirm pastes that could run commands", isOn: setting(\.pasteProtection))
            }
        }
        .formStyle(.grouped)
    }
}
