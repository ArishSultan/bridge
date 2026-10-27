import Foundation

/// User settings, stored as JSON in `~/.config/bridge/settings.json` with the same keys and
/// values as v1. Keys this version doesn't know are kept in `extra` and written back unchanged.
public struct Settings: Equatable, Sendable {
    // Appearance
    public var appTheme: AppTheme = .system
    public var colorScheme: String = ColorScheme.matchApp
    public var fontFamily: String = "Menlo"
    public var fontSize: Double = 14
    public var lineHeight: Double = 1.3
    public var letterSpacing: Double = 0
    public var fontLigatures = false
    public var boldIsBright = false
    public var padding: Double = 8
    public var backgroundEffect: BackgroundEffect = .opaque
    public var backgroundOpacity: Double = 1

    // Cursor and pointer
    public var cursorShape: CursorShape = .bar
    public var cursorBlink = true
    public var pointerStyle: PointerStyle = .ibeam
    public var hidePointerWhileTyping = true

    // Mouse
    public var copyOnSelect = false
    public var clickToMoveCursor = true
    public var mouseReporting = true
    public var scrollMultiplier: Double = 1

    // Keyboard
    public var optionAsAlt = false

    // Shell
    public var shell = ""
    public var workingDirectory = ""
    public var scrollbackLines = 10_000
    public var visualBell = true
    /// Mark a terminal that rang the bell while you were elsewhere, and tell the system when the
    /// app is in the background.
    public var notifyOnBell = true
    /// In sandboxed shells the project folder stands in for `~` (prompt and `cd`).
    public var projectIsHome = true
    public var notifyLongCommands = true
    /// How long a command runs before finishing counts as long.
    public var notifyAfterSecs = 10
    public var pasteProtection = true
    public var shellIntegration = true

    // Completions and history
    public var autosuggestions = true
    public var tabCompletions = true
    public var completionsAsYouType = false
    public var importShellHistory = true

    // Prompt
    public var promptStyle: PromptStyle = .folderGit
    public var promptTemplate = "{blue}{dir}{reset}{magenta}{git}{reset} {cyan}{symbol}{reset} "
    public var hidePartialLineMarker = true

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
        notifyAfterSecs = min(max(notifyAfterSecs, 1), 3600)
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

public enum PointerStyle: String, CaseIterable, Codable, Sendable {
    case ibeam, arrow

    public var label: String {
        switch self {
        case .ibeam: "Text I-beam"
        case .arrow: "Arrow"
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

/// The shell prompt the integration scripts set (zsh and bash).
public enum PromptStyle: String, CaseIterable, Codable, Sendable {
    case folderGit = "folder-git"
    case starship
    case minimal
    case folder
    case pathGit = "path-git"
    case userHost = "user-host"
    case shellDefault = "shell-default"
    case custom

    public var label: String {
        switch self {
        case .folderGit: "Folder and git branch"
        case .starship: "Starship"
        case .minimal: "Minimal (❯ only)"
        case .folder: "Folder"
        case .pathGit: "Full path and git branch"
        case .userHost: "User, host and folder"
        case .shellDefault: "Keep my shell's prompt"
        case .custom: "Custom pattern"
        }
    }

    /// The prompt pattern for this style; nil leaves the shell's own prompt alone. For Starship
    /// this is the pattern used until Starship is installed.
    public func template(custom: String) -> String? {
        switch self {
        case .folderGit, .starship: "{bold}{blue}{dir}{reset}{magenta}{git}{reset} {cyan}{symbol}{reset} "
        case .minimal: "{cyan}{symbol}{reset} "
        case .folder: "{bold}{blue}{dir}{reset} {cyan}{symbol}{reset} "
        case .pathGit: "{bold}{blue}{path}{reset}{magenta}{git}{reset} {cyan}{symbol}{reset} "
        case .userHost: "{green}{user}@{host}{reset} {bold}{blue}{dir}{reset} {cyan}{symbol}{reset} "
        case .shellDefault: nil
        case .custom: custom
        }
    }
}

// MARK: - JSON

extension Settings: Codable {
    /// How one setting is read and written, under the key v1 used.
    private struct Field: Sendable {
        let key: String
        let read: @Sendable (inout Settings, KeyedDecodingContainer<AnyKey>) -> Void
        let write: @Sendable (Settings, inout KeyedEncodingContainer<AnyKey>) throws -> Void

        /// A value of the wrong type falls back to the default rather than failing the file.
        static func of<T: Codable & Sendable>(_ key: String, _ path: WritableKeyPath<Settings, T> & Sendable) -> Field {
            Field(
                key: key,
                read: { settings, c in
                    if let value = try? c.decodeIfPresent(T.self, forKey: AnyKey(key)) {
                        settings[keyPath: path] = value
                    }
                },
                write: { settings, c in try c.encode(settings[keyPath: path], forKey: AnyKey(key)) })
        }
    }

    private static let fields: [Field] = [
        .of("app_theme", \.appTheme),
        .of("color_scheme", \.colorScheme),
        .of("font_family", \.fontFamily),
        .of("font_size", \.fontSize),
        .of("line_height", \.lineHeight),
        .of("letter_spacing", \.letterSpacing),
        .of("font_ligatures", \.fontLigatures),
        .of("bold_is_bright", \.boldIsBright),
        .of("padding", \.padding),
        .of("background_effect", \.backgroundEffect),
        .of("background_opacity", \.backgroundOpacity),
        .of("cursor_shape", \.cursorShape),
        .of("cursor_blink", \.cursorBlink),
        .of("pointer_style", \.pointerStyle),
        .of("hide_pointer_while_typing", \.hidePointerWhileTyping),
        .of("copy_on_select", \.copyOnSelect),
        .of("click_to_move_cursor", \.clickToMoveCursor),
        .of("mouse_reporting", \.mouseReporting),
        .of("scroll_multiplier", \.scrollMultiplier),
        .of("option_as_alt", \.optionAsAlt),
        .of("shell", \.shell),
        .of("working_directory", \.workingDirectory),
        .of("scrollback_lines", \.scrollbackLines),
        .of("visual_bell", \.visualBell),
        .of("notify_on_bell", \.notifyOnBell),
        .of("project_is_home", \.projectIsHome),
        .of("notify_long_commands", \.notifyLongCommands),
        .of("notify_after_secs", \.notifyAfterSecs),
        .of("paste_protection", \.pasteProtection),
        .of("shell_integration", \.shellIntegration),
        .of("autosuggestions", \.autosuggestions),
        .of("tab_completions", \.tabCompletions),
        .of("completions_as_you_type", \.completionsAsYouType),
        .of("import_shell_history", \.importShellHistory),
        .of("prompt_style", \.promptStyle),
        .of("prompt_template", \.promptTemplate),
        .of("hide_partial_line_marker", \.hidePartialLineMarker),
    ]

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: AnyKey.self)
        for field in Self.fields {
            field.read(&self, c)
        }
        let known = Set(Self.fields.map(\.key))
        for key in c.allKeys where !known.contains(key.stringValue) {
            extra[key.stringValue] = try c.decode(JSONValue.self, forKey: key)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (key, value) in extra {
            try c.encode(value, forKey: AnyKey(key))
        }
        for field in Self.fields {
            try field.write(self, &c)
        }
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
