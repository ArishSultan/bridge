//! Built-in terminal color schemes (foreground, background, cursor and the 16 ANSI colors).

use crate::terminal::Rgb;

/// Pseudo-scheme that derives foreground/background from the gpui-component theme.
pub const MATCH_APP: &str = "match-app";

pub struct ColorScheme {
    pub id: &'static str,
    pub name: &'static str,
    pub foreground: u32,
    pub background: u32,
    pub cursor: Option<u32>,
    pub ansi: [u32; 16],
}

pub const SCHEMES: &[ColorScheme] = &[
    ColorScheme {
        id: "one-dark",
        name: "One Dark",
        foreground: 0xabb2bf,
        background: 0x282c34,
        cursor: Some(0x528bff),
        ansi: [
            0x282c34, 0xe06c75, 0x98c379, 0xe5c07b, 0x61afef, 0xc678dd, 0x56b6c2, 0xabb2bf,
            0x5c6370, 0xe06c75, 0x98c379, 0xe5c07b, 0x61afef, 0xc678dd, 0x56b6c2, 0xffffff,
        ],
    },
    ColorScheme {
        id: "dracula",
        name: "Dracula",
        foreground: 0xf8f8f2,
        background: 0x282a36,
        cursor: Some(0xf8f8f2),
        ansi: [
            0x21222c, 0xff5555, 0x50fa7b, 0xf1fa8c, 0xbd93f9, 0xff79c6, 0x8be9fd, 0xf8f8f2,
            0x6272a4, 0xff6e6e, 0x69ff94, 0xffffa5, 0xd6acff, 0xff92df, 0xa4ffff, 0xffffff,
        ],
    },
    ColorScheme {
        id: "tokyo-night",
        name: "Tokyo Night",
        foreground: 0xc0caf5,
        background: 0x1a1b26,
        cursor: Some(0xc0caf5),
        ansi: [
            0x15161e, 0xf7768e, 0x9ece6a, 0xe0af68, 0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xa9b1d6,
            0x414868, 0xf7768e, 0x9ece6a, 0xe0af68, 0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xc0caf5,
        ],
    },
    ColorScheme {
        id: "catppuccin-mocha",
        name: "Catppuccin Mocha",
        foreground: 0xcdd6f4,
        background: 0x1e1e2e,
        cursor: Some(0xf5e0dc),
        ansi: [
            0x45475a, 0xf38ba8, 0xa6e3a1, 0xf9e2af, 0x89b4fa, 0xf5c2e7, 0x94e2d5, 0xbac2de,
            0x585b70, 0xf38ba8, 0xa6e3a1, 0xf9e2af, 0x89b4fa, 0xf5c2e7, 0x94e2d5, 0xa6adc8,
        ],
    },
    ColorScheme {
        id: "gruvbox-dark",
        name: "Gruvbox Dark",
        foreground: 0xebdbb2,
        background: 0x282828,
        cursor: Some(0xebdbb2),
        ansi: [
            0x282828, 0xcc241d, 0x98971a, 0xd79921, 0x458588, 0xb16286, 0x689d6a, 0xa89984,
            0x928374, 0xfb4934, 0xb8bb26, 0xfabd2f, 0x83a598, 0xd3869b, 0x8ec07c, 0xebdbb2,
        ],
    },
    ColorScheme {
        id: "nord",
        name: "Nord",
        foreground: 0xd8dee9,
        background: 0x2e3440,
        cursor: Some(0xd8dee9),
        ansi: [
            0x3b4252, 0xbf616a, 0xa3be8c, 0xebcb8b, 0x81a1c1, 0xb48ead, 0x88c0d0, 0xe5e9f0,
            0x4c566a, 0xbf616a, 0xa3be8c, 0xebcb8b, 0x81a1c1, 0xb48ead, 0x8fbcbb, 0xeceff4,
        ],
    },
    ColorScheme {
        id: "solarized-dark",
        name: "Solarized Dark",
        foreground: 0x839496,
        background: 0x002b36,
        cursor: Some(0x93a1a1),
        ansi: [
            0x073642, 0xdc322f, 0x859900, 0xb58900, 0x268bd2, 0xd33682, 0x2aa198, 0xeee8d5,
            0x002b36, 0xcb4b16, 0x586e75, 0x657b83, 0x839496, 0x6c71c4, 0x93a1a1, 0xfdf6e3,
        ],
    },
    ColorScheme {
        id: "solarized-light",
        name: "Solarized Light",
        foreground: 0x657b83,
        background: 0xfdf6e3,
        cursor: Some(0x586e75),
        ansi: [
            0x073642, 0xdc322f, 0x859900, 0xb58900, 0x268bd2, 0xd33682, 0x2aa198, 0xeee8d5,
            0x002b36, 0xcb4b16, 0x586e75, 0x657b83, 0x839496, 0x6c71c4, 0x93a1a1, 0xfdf6e3,
        ],
    },
    ColorScheme {
        id: "github-light",
        name: "GitHub Light",
        foreground: 0x24292f,
        background: 0xffffff,
        cursor: Some(0x0969da),
        ansi: [
            0x24292f, 0xcf222e, 0x116329, 0x4d2d00, 0x0969da, 0x8250df, 0x1b7c83, 0x6e7781,
            0x57606a, 0xa40e26, 0x1a7f37, 0x633c01, 0x218bff, 0xa475f9, 0x3192aa, 0x8c959f,
        ],
    },
];

pub fn find(id: &str) -> Option<&'static ColorScheme> {
    SCHEMES.iter().find(|scheme| scheme.id == id)
}

/// `(id, label)` pairs for the settings dropdown, starting with the app-matched scheme.
pub fn options() -> Vec<(&'static str, &'static str)> {
    std::iter::once((MATCH_APP, "Match app theme"))
        .chain(SCHEMES.iter().map(|scheme| (scheme.id, scheme.name)))
        .collect()
}

pub fn rgb(hex: u32) -> Rgb {
    Rgb {
        r: (hex >> 16) as u8,
        g: (hex >> 8) as u8,
        b: hex as u8,
    }
}
