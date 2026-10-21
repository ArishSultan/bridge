//! The app theme. Like Warp's themes, the whole window is derived from the terminal's palette (its
//! background, foreground and an accent), so every color scheme gives a coherent app:
//! - only the terminal is drawn in the scheme's background (near-black in the default dark theme);
//! - everything else (title bar, sidebar, sheets, settings, menus) is one surface a step toward
//!   the foreground;
//! - borders, hovers, the active row and muted text are mixes of the two.
//!
//! gpui-component's light or dark theme is loaded first and then re-tinted, so components keep
//! their shadcn styling and only the colors move.

use gpui::{App, Global, Hsla, Window};
use gpui_component::{ActiveTheme as _, Colorize as _, Theme, ThemeMode};

use crate::{
    schemes,
    settings::{AppTheme, TerminalSettings},
};

/// Steps from the terminal background toward the foreground, as the foreground's share of a mix.
const CHROME: f32 = 0.05;
const HOVER: f32 = 0.08;
const ACTIVE: f32 = 0.11;
const BORDER: f32 = 0.11;
const MUTED_TEXT: f32 = 0.5;

/// The terminal's own background (opaque), which nothing else in the window uses.
#[derive(Clone, Copy)]
pub struct TerminalSurface {
    pub background: Hsla,
}

impl Global for TerminalSurface {}

/// The terminal's background, as the current theme set it.
pub fn terminal_background(cx: &App) -> Hsla {
    cx.try_global::<TerminalSurface>()
        .map_or_else(|| cx.theme().background, |surface| surface.background)
}

/// Colors a group can be marked with: `(id, name, dark-mode shade, light-mode shade)`, Tailwind's
/// 400 and 600 steps so they read on either surface.
pub const GROUP_COLORS: [(&str, &str, u32, u32); 8] = [
    ("red", "Red", 0xf87171, 0xdc2626),
    ("orange", "Orange", 0xfb923c, 0xea580c),
    ("amber", "Amber", 0xfbbf24, 0xd97706),
    ("green", "Green", 0x4ade80, 0x16a34a),
    ("teal", "Teal", 0x2dd4bf, 0x0d9488),
    ("blue", "Blue", 0x60a5fa, 0x2563eb),
    ("violet", "Violet", 0xa78bfa, 0x7c3aed),
    ("pink", "Pink", 0xf472b6, 0xdb2777),
];

/// A group color for the current light or dark mode.
pub fn group_color(id: &str, cx: &App) -> Option<Hsla> {
    let (_, _, dark, light) = GROUP_COLORS
        .iter()
        .find(|(candidate, ..)| *candidate == id)?;
    Some(hex(if cx.theme().is_dark() { *dark } else { *light }))
}

/// The terminal palette everything is derived from.
struct Palette {
    background: Hsla,
    foreground: Hsla,
    /// Focus rings and the active terminal's icon; `None` keeps the theme's own.
    accent: Option<Hsla>,
}

/// Load the light or dark theme for the settings and tint it to the terminal palette.
pub fn apply(window: &mut Window, cx: &mut App) {
    let settings = TerminalSettings::get(cx).clone();
    let scheme = schemes::find(&settings.color_scheme);
    // A color scheme decides light or dark itself; otherwise the app theme setting does.
    let mode = match (scheme, settings.app_theme) {
        (Some(scheme), _) if luminance(scheme.background) < 0.5 => ThemeMode::Dark,
        (Some(_), _) => ThemeMode::Light,
        (None, AppTheme::System) => ThemeMode::from(window.appearance()),
        (None, AppTheme::Dark) => ThemeMode::Dark,
        (None, AppTheme::Light) => ThemeMode::Light,
    };
    Theme::change(mode, Some(window), cx);

    let theme = Theme::global(cx);
    let palette = match scheme {
        Some(scheme) => Palette {
            background: hex(scheme.background),
            foreground: hex(scheme.foreground),
            accent: Some(hex(scheme.ansi[4])),
        },
        None => Palette {
            background: theme.background,
            foreground: theme.foreground,
            accent: None,
        },
    };
    // Set before the theme changes, so views that follow the theme read the new one.
    cx.set_global(TerminalSurface {
        background: palette.background,
    });
    Theme::update(cx, |theme| tint(theme, &palette));
}

fn tint(theme: &mut Theme, palette: &Palette) {
    let (bg, fg) = (palette.background, palette.foreground);
    // `mix(other, factor)` keeps `factor` of `self`.
    let step = |base: Hsla, share: f32| base.mix(fg, 1. - share);
    let surface = step(bg, CHROME);
    let colors = &mut theme.colors;

    // The UI's own background: sheets, settings pages, inputs and menus are all this surface.
    colors.background = surface;
    colors.foreground = fg;
    colors.border = step(bg, BORDER);
    colors.input = colors.border;
    colors.muted = step(bg, HOVER);
    colors.muted_foreground = fg.mix(bg, 1. - MUTED_TEXT);
    colors.accent = step(bg, HOVER);
    colors.accent_foreground = fg;
    colors.secondary = step(bg, HOVER);
    colors.secondary_hover = step(bg, ACTIVE);
    colors.secondary_foreground = fg;
    colors.popover = if theme.mode.is_dark() {
        step(bg, CHROME + 0.02)
    } else {
        bg
    };
    colors.popover_foreground = fg;
    colors.list_hover = step(bg, HOVER);
    // Cards on the surface (settings groups): a step up in dark mode, white on grey in light.
    colors.group_box = if theme.mode.is_dark() {
        step(bg, HOVER)
    } else {
        bg
    };

    colors.title_bar = surface;
    colors.title_bar_border = surface.opacity(0.);
    colors.sidebar = surface;
    colors.sidebar_border = colors.border;
    colors.sidebar_foreground = fg;
    colors.sidebar_accent = step(surface, ACTIVE - CHROME);
    colors.sidebar_accent_foreground = fg;

    if let Some(accent) = palette.accent {
        colors.ring = accent;
        colors.sidebar_primary = accent;
    }
}

fn hex(value: u32) -> Hsla {
    gpui::rgb(value).into()
}

/// Relative luminance of a `0xRRGGBB` color, 0 (black) to 1 (white).
fn luminance(value: u32) -> f32 {
    let channel = |shift: u32| ((value >> shift) & 0xff) as f32 / 255.;
    0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn schemes_pick_their_own_mode() {
        assert!(luminance(0x000000) < 0.5);
        assert!(luminance(0x282a36) < 0.5);
        assert!(luminance(0xfdf6e3) > 0.5);
        assert!(luminance(0xffffff) > 0.99);
    }

    #[test]
    fn chrome_sits_between_background_and_foreground() {
        let (bg, fg) = (hex(0x0a0a0a), hex(0xfafafa));
        let chrome = bg.mix(fg, 1. - CHROME);
        assert!(chrome.l > bg.l && chrome.l < bg.mix(fg, 1. - BORDER).l);
    }
}
