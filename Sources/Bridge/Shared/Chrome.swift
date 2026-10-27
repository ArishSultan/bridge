import AppKit
import BridgeCore
import SwiftUI

/// Window colors from the terminal palette (v1's theme: coss ui's mixes).
struct Chrome {
    let terminal: Color
    let surface: Color
    let border: Color
    let active: Color
    let text: Color
    let mutedText: Color
    let isDark: Bool

    init(_ scheme: BridgeCore.ColorScheme) {
        let bg = scheme.background
        let fg = scheme.foreground
        isDark = !scheme.isLight
        terminal = Color(bg)
        surface = Color(bg.mix(fg, 0.05))
        border = Color(bg.mix(fg, isDark ? 0.06 : 0.08))
        active = Color(bg.mix(fg, 0.08))
        text = Color(fg)
        mutedText = Color(fg.mix(bg, 0.5))
    }

    var nsSurface: NSColor { NSColor(surface) }
}
