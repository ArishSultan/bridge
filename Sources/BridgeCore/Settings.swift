import Foundation

/// User settings, stored as JSON in `~/.config/bridge/settings.json`.
///
/// The keys and values are the ones Bridge v1 wrote, so an existing file carries over. Keys this
/// version doesn't use (prompt style, autosuggestions and the like, until those features return)
/// are kept in `extra` and written back unchanged.
public struct Settings: Equatable, Sendable {
    // Appearance
    public var appTheme: AppTheme = .system
    public var colorScheme: String = ColorScheme.matchApp
    public var fontFamily: String = "Menlo"
    public var fontSize: Double = 14
    public var lineHeight: Double = 1.3
    public var letterSpacing: Double = 0
    public var fontLigatures: Bool = false
    public var boldIsBright: Bool = false
    public var padding: Double = 8
    public var backgroundEffect: BackgroundEffect = .opaque
    public var backgroundOpacity: Double = 1

    // Cursor and pointer
    public var cursorShape: CursorShape = .bar
    public var cursorBlink: Bool = true
    public var hidePointerWhileTyping: Bool = true

    // Mouse
    public var copyOnSelect: Bool = false
    public var clickToMoveCursor: Bool = true
    public var scrollMultiplier: Double = 1

    // Keyboard
    public var optionAsAlt: Bool = false

    // Shell
    public var shell: String = ""
    public var workingDirectory: String = ""
    public var scrollbackLines: Int = 10_000
    public var pasteProtection: Bool = true
    public var shellIntegration: Bool = true

    /// Keys from the file that this version doesn't know.
    public var extra: [String: JSONValue] = [:]

    public static let minFontSize = 6.0
    public static let maxFontSize = 48.0

    public init() {}

    /// Clamp values into ranges the renderer handles, and replace ones that can't be used.
    public mutating func sanitize() {
        fontSize = fontSize.clamped(Self.minFontSize, Self.maxFontSize)
        lineHeight = lineHeight.clamped(0.8, 3)
        letterSpacing = letterSpacing.clamped(-2, 10)
        padding = padding.clamped(0, 64)
        backgroundOpacity = backgroundOpacity.clamped(0.2, 1)
        scrollMultiplier = scrollMultiplier.clamped(0.1, 10)
        scrollbackLines = min(max(scrollbackLines, 0), 1_000_000)
        if fontFamily.trimmingCharacters(in: .whitespaces).isEmpty {
            fontFamily = Settings().fontFamily
        }
        if colorScheme != ColorScheme.matchApp && ColorScheme.find(colorScheme) == nil {
            colorScheme = ColorScheme.matchApp
        }
    }
}

public enum AppTheme: String, CaseIterable, Codable, Sendable {
    case system, dark, light

    public var label: String {
        switch self {
        case .system: "Follow system"
        case .dark: "Dark"
        case .light: "Light"
        }
    }
}

public enum CursorShape: String, CaseIterable, Codable, Sendable {
    case bar, block, underline, hollow

    public var label: String {
        switch self {
        case .bar: "Bar (editor style)"
        case .block: "Block"
        case .underline: "Underline"
        case .hollow: "Hollow block"
        }
    }
}

public enum BackgroundEffect: String, CaseIterable, Codable, Sendable {
    case opaque, transparent, blurred

    public var label: String {
        switch self {
        case .opaque: "Opaque"
        case .transparent: "Transparent"
        case .blurred: "Blurred"
        }
    }
}

// MARK: - JSON

extension Settings: Codable {
    /// The JSON key of every known field, as v1 named them.
    private enum Key: String, CaseIterable {
        case appTheme = "app_theme"
        case colorScheme = "color_scheme"
        case fontFamily = "font_family"
        case fontSize = "font_size"
        case lineHeight = "line_height"
        case letterSpacing = "letter_spacing"
        case fontLigatures = "font_ligatures"
        case boldIsBright = "bold_is_bright"
        case padding
        case backgroundEffect = "background_effect"
        case backgroundOpacity = "background_opacity"
        case cursorShape = "cursor_shape"
        case cursorBlink = "cursor_blink"
        case hidePointerWhileTyping = "hide_pointer_while_typing"
        case copyOnSelect = "copy_on_select"
        case clickToMoveCursor = "click_to_move_cursor"
        case scrollMultiplier = "scroll_multiplier"
        case optionAsAlt = "option_as_alt"
        case shell
        case workingDirectory = "working_directory"
        case scrollbackLines = "scrollback_lines"
        case pasteProtection = "paste_protection"
        case shellIntegration = "shell_integration"

        var codingKey: AnyKey { AnyKey(rawValue) }
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: AnyKey.self)

        // A value of the wrong type falls back to the default rather than failing the whole file.
        func read<T: Decodable>(_ key: Key, _ value: inout T) {
            if let decoded = try? c.decodeIfPresent(T.self, forKey: key.codingKey) {
                value = decoded
            }
        }

        read(.appTheme, &appTheme)
        read(.colorScheme, &colorScheme)
        read(.fontFamily, &fontFamily)
        read(.fontSize, &fontSize)
        read(.lineHeight, &lineHeight)
        read(.letterSpacing, &letterSpacing)
        read(.fontLigatures, &fontLigatures)
        read(.boldIsBright, &boldIsBright)
        read(.padding, &padding)
        read(.backgroundEffect, &backgroundEffect)
        read(.backgroundOpacity, &backgroundOpacity)
        read(.cursorShape, &cursorShape)
        read(.cursorBlink, &cursorBlink)
        read(.hidePointerWhileTyping, &hidePointerWhileTyping)
        read(.copyOnSelect, &copyOnSelect)
        read(.clickToMoveCursor, &clickToMoveCursor)
        read(.scrollMultiplier, &scrollMultiplier)
        read(.optionAsAlt, &optionAsAlt)
        read(.shell, &shell)
        read(.workingDirectory, &workingDirectory)
        read(.scrollbackLines, &scrollbackLines)
        read(.pasteProtection, &pasteProtection)
        read(.shellIntegration, &shellIntegration)

        let known = Set(Key.allCases.map(\.rawValue))
        for key in c.allKeys where !known.contains(key.stringValue) {
            extra[key.stringValue] = try c.decode(JSONValue.self, forKey: key)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (key, value) in extra {
            try c.encode(value, forKey: AnyKey(key))
        }
        try c.encode(appTheme, forKey: Key.appTheme.codingKey)
        try c.encode(colorScheme, forKey: Key.colorScheme.codingKey)
        try c.encode(fontFamily, forKey: Key.fontFamily.codingKey)
        try c.encode(fontSize, forKey: Key.fontSize.codingKey)
        try c.encode(lineHeight, forKey: Key.lineHeight.codingKey)
        try c.encode(letterSpacing, forKey: Key.letterSpacing.codingKey)
        try c.encode(fontLigatures, forKey: Key.fontLigatures.codingKey)
        try c.encode(boldIsBright, forKey: Key.boldIsBright.codingKey)
        try c.encode(padding, forKey: Key.padding.codingKey)
        try c.encode(backgroundEffect, forKey: Key.backgroundEffect.codingKey)
        try c.encode(backgroundOpacity, forKey: Key.backgroundOpacity.codingKey)
        try c.encode(cursorShape, forKey: Key.cursorShape.codingKey)
        try c.encode(cursorBlink, forKey: Key.cursorBlink.codingKey)
        try c.encode(hidePointerWhileTyping, forKey: Key.hidePointerWhileTyping.codingKey)
        try c.encode(copyOnSelect, forKey: Key.copyOnSelect.codingKey)
        try c.encode(clickToMoveCursor, forKey: Key.clickToMoveCursor.codingKey)
        try c.encode(scrollMultiplier, forKey: Key.scrollMultiplier.codingKey)
        try c.encode(optionAsAlt, forKey: Key.optionAsAlt.codingKey)
        try c.encode(shell, forKey: Key.shell.codingKey)
        try c.encode(workingDirectory, forKey: Key.workingDirectory.codingKey)
        try c.encode(scrollbackLines, forKey: Key.scrollbackLines.codingKey)
        try c.encode(pasteProtection, forKey: Key.pasteProtection.codingKey)
        try c.encode(shellIntegration, forKey: Key.shellIntegration.codingKey)
    }
}

// MARK: - Disk

extension Settings {
    /// The app's own folder: `~/.config/bridge`, shared with v1.
    public static var configDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("bridge", isDirectory: true)
    }

    public static var fileURL: URL {
        configDirectory.appendingPathComponent("settings.json")
    }

    /// Load from disk, falling back to defaults when the file is missing or unreadable.
    public static func load(from url: URL = fileURL) -> Settings {
        var settings: Settings
        do {
            settings = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: url))
        } catch CocoaError.fileReadNoSuchFile {
            settings = Settings()
        } catch {
            NSLog("Bridge: ignoring settings file %@: %@", url.path, String(describing: error))
            settings = Settings()
        }
        settings.sanitize()
        return settings
    }

    public func save(to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

extension Double {
    func clamped(_ low: Double, _ high: Double) -> Double {
        Swift.min(Swift.max(self, low), high)
    }
}
