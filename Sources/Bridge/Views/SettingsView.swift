import AppKit
import BridgeCore
import SwiftUI

/// Settings, applied live to every open terminal and saved to ~/.config/bridge/settings.json.
struct SettingsView: View {
    var body: some View {
        TabView {
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            TerminalSettings()
                .tabItem { Label("Terminal", systemImage: "terminal") }
            ShellSettings()
                .tabItem { Label("Shell", systemImage: "chevron.left.forwardslash.chevron.right") }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

/// A binding to one setting on the shared model.
@MainActor
private func setting<Value>(_ keyPath: WritableKeyPath<BridgeCore.Settings, Value>) -> Binding<Value> {
    Binding(
        get: { AppModel.shared.settings[keyPath: keyPath] },
        set: { AppModel.shared.settings[keyPath: keyPath] = $0 })
}

private struct AppearanceSettings: View {
    private static let monospacedFonts: [String] = {
        let manager = NSFontManager.shared
        return manager.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 12) else { return false }
            return font.isFixedPitch || manager.traits(of: font).contains(.fixedPitchFontMask)
        }
    }()

    var body: some View {
        let settings = AppModel.shared.settings
        Form {
            Picker("Theme", selection: setting(\.appTheme)) {
                ForEach(AppTheme.allCases, id: \.self) { Text($0.label) }
            }
            Picker("Color scheme", selection: setting(\.colorScheme)) {
                ForEach(BridgeCore.ColorScheme.options, id: \.id) { option in
                    Text(option.name).tag(option.id)
                }
            }

            Section("Font") {
                Picker("Family", selection: setting(\.fontFamily)) {
                    let families = Self.monospacedFonts.contains(settings.fontFamily)
                        ? Self.monospacedFonts : [settings.fontFamily] + Self.monospacedFonts
                    ForEach(families, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                LabeledContent("Size") {
                    Stepper(value: setting(\.fontSize), in: BridgeCore.Settings.minFontSize...BridgeCore.Settings.maxFontSize, step: 1) {
                        Text("\(Int(settings.fontSize)) pt").monospacedDigit()
                    }
                }
                LabeledContent("Line height") {
                    Slider(value: setting(\.lineHeight), in: 0.8...2.0, step: 0.05)
                    Text(String(format: "%.2f", settings.lineHeight)).monospacedDigit().frame(width: 36)
                }
                LabeledContent("Letter spacing") {
                    Slider(value: setting(\.letterSpacing), in: -2...10, step: 1)
                    Text("\(Int(settings.letterSpacing)) px").monospacedDigit().frame(width: 36)
                }
                Toggle("Ligatures", isOn: setting(\.fontLigatures))
                Toggle("Bold text in bright colors", isOn: setting(\.boldIsBright))
            }

            Section("Window") {
                LabeledContent("Padding") {
                    Slider(value: setting(\.padding), in: 0...32, step: 1)
                    Text("\(Int(settings.padding)) pt").monospacedDigit().frame(width: 36)
                }
                Picker("Background", selection: setting(\.backgroundEffect)) {
                    ForEach(BackgroundEffect.allCases, id: \.self) { Text($0.label) }
                }
                if settings.backgroundEffect != .opaque {
                    LabeledContent("Opacity") {
                        Slider(value: setting(\.backgroundOpacity), in: 0.2...1, step: 0.05)
                        Text("\(Int(settings.backgroundOpacity * 100))%").monospacedDigit().frame(width: 36)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct TerminalSettings: View {
    var body: some View {
        let settings = AppModel.shared.settings
        Form {
            Section("Cursor") {
                Picker("Shape", selection: setting(\.cursorShape)) {
                    ForEach(CursorShape.allCases, id: \.self) { Text($0.label) }
                }
                Toggle("Blink", isOn: setting(\.cursorBlink))
            }
            Section("Mouse") {
                Toggle("Hide the pointer while typing", isOn: setting(\.hidePointerWhileTyping))
                Toggle("Copy selected text", isOn: setting(\.copyOnSelect))
                Toggle("Option-click moves the cursor", isOn: setting(\.clickToMoveCursor))
                LabeledContent("Scroll speed") {
                    Slider(value: setting(\.scrollMultiplier), in: 0.25...4, step: 0.25)
                    Text(String(format: "%.2g×", settings.scrollMultiplier)).monospacedDigit().frame(width: 36)
                }
            }
            Section("Keyboard") {
                Toggle("Use Option as Meta", isOn: setting(\.optionAsAlt))
            }
            Section("Scrollback") {
                LabeledContent("Lines") {
                    TextField("", value: setting(\.scrollbackLines), format: .number)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                }
                Text("Applies to new terminals.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShellSettings: View {
    var body: some View {
        Form {
            Section {
                TextField("Shell", text: setting(\.shell), prompt: Text("Login shell"))
                TextField("Start in", text: setting(\.workingDirectory), prompt: Text("Home folder"))
            } footer: {
                Text("Applies to new terminals. New tabs and splits start in the current terminal's folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Shell integration", isOn: setting(\.shellIntegration))
                Toggle("Confirm pastes that could run commands", isOn: setting(\.pasteProtection))
            } footer: {
                Text("Shell integration reports the current folder and prompt positions (zsh, bash, fish, elvish).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
