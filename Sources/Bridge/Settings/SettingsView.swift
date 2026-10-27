import AppKit
import BridgeCore
import SwiftUI

/// Settings, applied live to every terminal and saved to ~/.config/bridge/settings.json.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Appearance", systemImage: "paintpalette") { AppearancePage() }
            Tab("Prompt", systemImage: "chevron.right.square") { PromptPage() }
            Tab("Cursor & Mouse", systemImage: "cursorarrow") { CursorPage() }
            Tab("Completions", systemImage: "text.badge.plus") { CompletionsPage() }
            Tab("Keyboard", systemImage: "keyboard") { KeyboardPage() }
            Tab("Shell", systemImage: "terminal") { ShellPage() }
        }
        .frame(width: 600, height: 560)
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
                Toggle("Tab opens completions", isOn: setting(\.tabCompletions))
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
                shortcut("⌘T / ⌘⇧T", "New terminal (sandboxed / open)")
                shortcut("⌘⇧E", "New task")
                shortcut("⌘D / ⌘⇧D", "Add a terminal to the right / below")
                shortcut("⌘W", "Close a terminal of a view, else the window")
                shortcut("⌘] / ⌘[", "Next / previous terminal of a view")
                shortcut("⌃Tab, ⌘⇧] / ⌘⇧[", "Next / previous item")
                shortcut("⌘1 … ⌘9", "Go to an item")
                shortcut("⌘O / ⌘⇧G", "Open a folder / the Global window")
                shortcut("⌘B", "Show or hide the sidebar")
                shortcut("⌃R", "Command history")
            }
            Section("Terminal") {
                shortcut("⌘C / ⌘V", "Copy / paste")
                shortcut("⌘K", "Clear")
                shortcut("⌘+ / ⌘- / ⌘0", "Font size")
                shortcut("⌘↑ / ⌘↓", "Jump to the previous / next prompt")
            }
        }
        .formStyle(.grouped)
    }

    private func shortcut(_ keys: String, _ meaning: String) -> some View {
        LabeledContent(meaning) { Text(keys).monospaced().foregroundStyle(.secondary) }
    }
}

private struct ShellPage: View {
    var body: some View {
        Form {
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
