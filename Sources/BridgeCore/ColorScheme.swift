import Foundation
import Synchronization
/// A terminal color scheme: foreground, background, cursor and the 16 ANSI colors.
public struct ColorScheme: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let foreground: RGB
    public let background: RGB
    public let cursor: RGB?
    /// The 16 ANSI colors; nil keeps the terminal's defaults ("match app", as in v1).
    public let ansi: [RGB]?

    /// The pseudo-scheme that follows the app's light or dark appearance.
    public static let matchApp = "match-app"

    public static func find(_ id: String) -> ColorScheme? {
        all.first { $0.id == id } ?? ghosttyThemes.first { $0.id == id }
    }

    /// The scheme to draw with: the chosen one, or for "match-app" v1's app colors: near-black
    /// (or white) with the terminal's default ANSI colors.
    public static func resolve(_ id: String, dark: Bool) -> ColorScheme {
        if let scheme = find(id) { return scheme }
        return dark ? matchAppDark : matchAppLight
    }

    /// gpui-component's default dark and light themes (neutral-950 and neutral-50), which v1's
    /// "match app" drew with.
    public static let matchAppDark = ColorScheme(id: matchApp, name: "Match app theme", foreground: 0xfafafa, background: 0x0a0a0a, cursor: nil, ansi: nil)
    public static let matchAppLight = ColorScheme(id: matchApp, name: "Match app theme", foreground: 0x0a0a0a, background: 0xffffff, cursor: nil, ansi: nil)

    /// `(id, label)` pairs for the settings picker, starting with the app-matched scheme.
    public static var options: [(id: String, name: String)] {
        [(matchApp, "Match app theme")] + all.map { ($0.id, $0.name) }
    }

    /// Ghostty's own themes (several hundred), when the app has found them.
    public static var ghosttyThemes: [ColorScheme] { themes.withLock { $0 } }

    private static let themes = Mutex<[ColorScheme]>([])

    /// Read the themes in Ghostty's `themes` folder (bundled with the app). Ids are
    /// `ghostty:<file name>`.
    public static func loadGhosttyThemes(from folder: URL) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        let loaded = names.compactMap { name -> ColorScheme? in
            guard !name.hasPrefix("."),
                  let text = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
            else { return nil }
            return parseGhosttyTheme(text, id: "ghostty:" + name, name: name)
        }
        themes.withLock { $0 = loaded }
    }

    /// A Ghostty theme file: `palette = N=#rrggbb`, `background`, `foreground`, `cursor-color`.
    public static func parseGhosttyTheme(_ text: String, id: String, name: String) -> ColorScheme? {
        var palette = [UInt32?](repeating: nil, count: 16)
        var background: UInt32?, foreground: UInt32?, cursor: UInt32?
        func color(_ value: Substring) -> UInt32? {
            let hex = value.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            return hex.count == 6 ? UInt32(hex, radix: 16) : nil
        }
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            switch key {
            case "background": background = color(parts[1])
            case "foreground": foreground = color(parts[1])
            case "cursor-color": cursor = color(parts[1])
            case "palette":
                let entry = parts[1].split(separator: "=", maxSplits: 1)
                if entry.count == 2, let index = Int(entry[0].trimmingCharacters(in: .whitespaces)), (0..<16).contains(index) {
                    palette[index] = color(entry[1])
                }
            default: break
            }
        }
        guard let background, let foreground else { return nil }
        let ansi = palette.allSatisfy { $0 != nil } ? palette.compactMap { $0 } : nil
        return ColorScheme(id: id, name: name, foreground: foreground, background: background, cursor: cursor, ansi: ansi)
    }

    /// True when the background is light, so the window chrome should be too.
    public var isLight: Bool { background.luminance > 0.5 }

    init(id: String, name: String, foreground: UInt32, background: UInt32, cursor: UInt32?, ansi: [UInt32]?) {
        precondition(ansi == nil || ansi?.count == 16)
        self.id = id
        self.name = name
        self.foreground = RGB(hex: foreground)
        self.background = RGB(hex: background)
        self.cursor = cursor.map(RGB.init(hex:))
        self.ansi = ansi?.map(RGB.init(hex:))
    }
}

public struct RGB: Equatable, Sendable {
    /// `share` of the way from this color to `other`.
    public func mix(_ other: RGB, _ share: Double) -> RGB {
        func blend(_ a: UInt8, _ b: UInt8) -> UInt32 { UInt32((Double(a) + (Double(b) - Double(a)) * share).rounded()) }
        return RGB(hex: blend(r, other.r) << 16 | blend(g, other.g) << 8 | blend(b, other.b))
    }

    public let r: UInt8
    public let g: UInt8
    public let b: UInt8

    public init(hex: UInt32) {
        r = UInt8((hex >> 16) & 0xff)
        g = UInt8((hex >> 8) & 0xff)
        b = UInt8(hex & 0xff)
    }

    /// `#rrggbb`, the form Ghostty's config takes.
    public var hexString: String {
        "#" + [r, g, b].map { byte in
            let digits = String(byte, radix: 16)
            return digits.count == 1 ? "0" + digits : digits
        }.joined()
    }

    /// Relative luminance in 0...1 (sRGB, Rec. 709 weights).
    public var luminance: Double {
        (0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)) / 255
    }
}

extension ColorScheme {
    /// The built-in schemes, the same ones v1 shipped.
    public static let all: [ColorScheme] = [
        ColorScheme(
            id: "one-dark", name: "One Dark",
            foreground: 0xabb2bf, background: 0x282c34, cursor: 0x528bff,
            ansi: [
                0x282c34, 0xe06c75, 0x98c379, 0xe5c07b, 0x61afef, 0xc678dd, 0x56b6c2, 0xabb2bf,
                0x5c6370, 0xe06c75, 0x98c379, 0xe5c07b, 0x61afef, 0xc678dd, 0x56b6c2, 0xffffff,
            ]),
        ColorScheme(
            id: "dracula", name: "Dracula",
            foreground: 0xf8f8f2, background: 0x282a36, cursor: 0xf8f8f2,
            ansi: [
                0x21222c, 0xff5555, 0x50fa7b, 0xf1fa8c, 0xbd93f9, 0xff79c6, 0x8be9fd, 0xf8f8f2,
                0x6272a4, 0xff6e6e, 0x69ff94, 0xffffa5, 0xd6acff, 0xff92df, 0xa4ffff, 0xffffff,
            ]),
        ColorScheme(
            id: "tokyo-night", name: "Tokyo Night",
            foreground: 0xc0caf5, background: 0x1a1b26, cursor: 0xc0caf5,
            ansi: [
                0x15161e, 0xf7768e, 0x9ece6a, 0xe0af68, 0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xa9b1d6,
                0x414868, 0xf7768e, 0x9ece6a, 0xe0af68, 0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xc0caf5,
            ]),
        ColorScheme(
            id: "catppuccin-mocha", name: "Catppuccin Mocha",
            foreground: 0xcdd6f4, background: 0x1e1e2e, cursor: 0xf5e0dc,
            ansi: [
                0x45475a, 0xf38ba8, 0xa6e3a1, 0xf9e2af, 0x89b4fa, 0xf5c2e7, 0x94e2d5, 0xbac2de,
                0x585b70, 0xf38ba8, 0xa6e3a1, 0xf9e2af, 0x89b4fa, 0xf5c2e7, 0x94e2d5, 0xa6adc8,
            ]),
        ColorScheme(
            id: "gruvbox-dark", name: "Gruvbox Dark",
            foreground: 0xebdbb2, background: 0x282828, cursor: 0xebdbb2,
            ansi: [
                0x282828, 0xcc241d, 0x98971a, 0xd79921, 0x458588, 0xb16286, 0x689d6a, 0xa89984,
                0x928374, 0xfb4934, 0xb8bb26, 0xfabd2f, 0x83a598, 0xd3869b, 0x8ec07c, 0xebdbb2,
            ]),
        ColorScheme(
            id: "nord", name: "Nord",
            foreground: 0xd8dee9, background: 0x2e3440, cursor: 0xd8dee9,
            ansi: [
                0x3b4252, 0xbf616a, 0xa3be8c, 0xebcb8b, 0x81a1c1, 0xb48ead, 0x88c0d0, 0xe5e9f0,
                0x4c566a, 0xbf616a, 0xa3be8c, 0xebcb8b, 0x81a1c1, 0xb48ead, 0x8fbcbb, 0xeceff4,
            ]),
        ColorScheme(
            id: "solarized-dark", name: "Solarized Dark",
            foreground: 0x839496, background: 0x002b36, cursor: 0x93a1a1,
            ansi: [
                0x073642, 0xdc322f, 0x859900, 0xb58900, 0x268bd2, 0xd33682, 0x2aa198, 0xeee8d5,
                0x002b36, 0xcb4b16, 0x586e75, 0x657b83, 0x839496, 0x6c71c4, 0x93a1a1, 0xfdf6e3,
            ]),
        ColorScheme(
            id: "solarized-light", name: "Solarized Light",
            foreground: 0x657b83, background: 0xfdf6e3, cursor: 0x586e75,
            ansi: [
                0x073642, 0xdc322f, 0x859900, 0xb58900, 0x268bd2, 0xd33682, 0x2aa198, 0xeee8d5,
                0x002b36, 0xcb4b16, 0x586e75, 0x657b83, 0x839496, 0x6c71c4, 0x93a1a1, 0xfdf6e3,
            ]),
        ColorScheme(
            id: "github-light", name: "GitHub Light",
            foreground: 0x24292f, background: 0xffffff, cursor: 0x0969da,
            ansi: [
                0x24292f, 0xcf222e, 0x116329, 0x4d2d00, 0x0969da, 0x8250df, 0x1b7c83, 0x6e7781,
                0x57606a, 0xa40e26, 0x1a7f37, 0x633c01, 0x218bff, 0xa475f9, 0x3192aa, 0x8c959f,
            ]),
    ]
}
