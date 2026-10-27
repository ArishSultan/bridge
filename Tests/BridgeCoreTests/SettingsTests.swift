import Foundation
import Testing
@testable import BridgeCore

struct SettingsTests {
    @Test func defaultsRoundTrip() throws {
        let data = try JSONEncoder().encode(Settings())
        #expect(try JSONDecoder().decode(Settings.self, from: data) == Settings())
    }

    @Test func readsV1FileAndKeepsUnknownKeys() throws {
        let v1 = """
        {
          "app_theme": "dark",
          "color_scheme": "dracula",
          "font_family": "JetBrains Mono",
          "font_size": 15.0,
          "cursor_shape": "hollow",
          "option_as_alt": true,
          "prompt_style": "starship",
          "some_future_key": [1, 2]
        }
        """
        let settings = try JSONDecoder().decode(Settings.self, from: Data(v1.utf8))
        #expect(settings.appTheme == .dark)
        #expect(settings.colorScheme == "dracula")
        #expect(settings.fontFamily == "JetBrains Mono")
        #expect(settings.fontSize == 15)
        #expect(settings.cursorShape == .hollow)
        #expect(settings.optionAsAlt)
        #expect(settings.promptStyle == .starship)
        #expect(settings.extra["some_future_key"] == .array([.number(1), .number(2)]))

        let saved = try JSONEncoder().encode(settings)
        let object = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        #expect(object["prompt_style"] as? String == "starship")
        #expect(object["some_future_key"] as? [Int] == [1, 2])
        #expect(object["font_family"] as? String == "JetBrains Mono")
    }

    @Test func badValuesFallBackAndAreClamped() throws {
        let json = #"{"font_size": 400, "cursor_shape": "triangle", "color_scheme": "nope"}"#
        var settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        settings.sanitize()
        #expect(settings.fontSize == Settings.maxFontSize)
        #expect(settings.cursorShape == .bar)
        #expect(settings.colorScheme == ColorScheme.matchApp)
    }

    @Test func savesAndLoadsFromDisk() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var settings = Settings()
        settings.fontSize = 18
        try settings.save(to: url)
        #expect(Settings.load(from: url) == settings)
    }

    @Test func missingFileGivesDefaults() {
        let url = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).json")
        #expect(Settings.load(from: url) == Settings())
    }
}

struct TerminalConfigTests {
    private func values(_ key: String, _ entries: [TerminalConfig.Entry]) -> [String] {
        entries.filter { $0.key == key }.map(\.value)
    }

    @Test func mapsSchemeToPalette() {
        var settings = Settings()
        settings.colorScheme = "nord"
        let entries = TerminalConfig.entries(for: settings, dark: false)
        #expect(values("background", entries) == ["#2e3440"])
        #expect(values("foreground", entries) == ["#d8dee9"])
        let palette = values("palette", entries)
        #expect(palette.count == 16)
        #expect(palette.first == "0=#3b4252")
        #expect(palette.last == "15=#eceff4")
    }

    @Test func matchAppFollowsAppearance() {
        let settings = Settings()
        // v1's "match app": near-black or white, with the terminal's default ANSI colors.
        let dark = TerminalConfig.entries(for: settings, dark: true)
        #expect(values("background", dark) == ["#0a0a0a"])
        #expect(values("foreground", dark) == ["#fafafa"])
        #expect(values("palette", dark).isEmpty)
        #expect(values("background", TerminalConfig.entries(for: settings, dark: false)) == ["#ffffff"])
        // Line height 1.3 of the size, for a font whose own is 1.25: 4% taller cells.
        #expect(values("adjust-cell-height", TerminalConfig.entries(for: settings, dark: true, naturalLineHeight: 1.25)) == ["4%"])
    }

    @Test func mapsBehaviorSettings() {
        var settings = Settings()
        settings.cursorShape = .hollow
        settings.optionAsAlt = true
        settings.shell = "/bin/zsh"
        settings.shellIntegration = false
        settings.fontLigatures = false
        let entries = TerminalConfig.entries(for: settings, dark: true)
        #expect(values("cursor-style", entries) == ["block_hollow"])
        #expect(values("macos-option-as-alt", entries) == ["true"])
        #expect(values("command", entries) == ["/bin/zsh"])
        #expect(values("shell-integration", entries) == ["none"])
        #expect(values("font-feature", entries) == ["-calt", "-liga", "-dlig"])
        #expect(values("working-directory", entries) == ["home"])
    }

    @Test func opaqueIgnoresOpacity() {
        var settings = Settings()
        settings.backgroundOpacity = 0.5
        #expect(values("background-opacity", TerminalConfig.entries(for: settings, dark: true)) == ["1"])
        settings.backgroundEffect = .blurred
        let entries = TerminalConfig.entries(for: settings, dark: true)
        #expect(values("background-opacity", entries) == ["0.5"])
        #expect(values("background-blur", entries) == ["true"])
    }

    @Test func fileContentsAreKeyValueLines() {
        let text = TerminalConfig.fileContents(for: Settings(), dark: true)
        #expect(text.contains("font-family = Menlo\n"))
        #expect(text.hasSuffix("\n"))
    }
}
