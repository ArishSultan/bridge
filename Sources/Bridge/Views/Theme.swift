import BridgeCore
import SwiftUI

/// Window chrome colors, derived from the terminal's color scheme so the tab bar and dividers
/// match the terminals they surround.
struct ChromeTheme {
    let background: Color
    let foreground: Color
    let tabBar: Color
    let selectedTab: Color
    let border: Color
    let secondaryText: Color
    let accent: Color
    let isLight: Bool

    init(_ scheme: BridgeCore.ColorScheme) {
        isLight = scheme.isLight
        background = Color(scheme.background)
        foreground = Color(scheme.foreground)
        // The tab bar sits slightly away from the background: darker on light schemes,
        // lighter on dark ones would compete with the terminal, so darker on both.
        tabBar = Color(scheme.background).mix(with: .black, by: isLight ? 0.05 : 0.18)
        selectedTab = Color(scheme.background)
        border = Color(scheme.foreground).opacity(isLight ? 0.14 : 0.12)
        secondaryText = Color(scheme.foreground).opacity(0.6)
        accent = Color(scheme.cursor ?? scheme.ansi[4])
    }
}

extension Color {
    init(_ rgb: RGB) {
        self.init(
            .sRGB,
            red: Double(rgb.r) / 255,
            green: Double(rgb.g) / 255,
            blue: Double(rgb.b) / 255)
    }
}
