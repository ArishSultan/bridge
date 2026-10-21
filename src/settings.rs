//! User settings: a gpui global persisted as JSON in `~/.config/bridge/settings.json`.
//!
//! Every change goes through [`TerminalSettings::update`], which saves the file and notifies
//! observers (`cx.observe_global::<TerminalSettings>`), so edits apply live.

use std::{fs, io, path::PathBuf};

use gpui::{App, Global};
use serde::{Deserialize, Serialize};

/// Generates `as_str`/`parse`/`OPTIONS` for a settings enum so it round-trips through dropdowns.
macro_rules! setting_enum {
    ($(#[$meta:meta])* $name:ident { $($variant:ident => ($value:literal, $label:literal)),+ $(,)? }) => {
        $(#[$meta])*
        #[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
        #[serde(rename_all = "kebab-case")]
        pub enum $name { #[default] $($variant),+ }

        impl $name {
            /// `(value, label)` pairs in display order.
            pub const OPTIONS: &'static [(&'static str, &'static str)] = &[$(($value, $label)),+];

            pub fn as_str(self) -> &'static str {
                match self { $(Self::$variant => $value),+ }
            }

            pub fn parse(value: &str) -> Option<Self> {
                match value { $($value => Some(Self::$variant),)+ _ => None }
            }
        }
    };
}

setting_enum!(
    /// Light/dark mode of the application chrome.
    AppTheme { System => ("system", "Follow system"), Dark => ("dark", "Dark"), Light => ("light", "Light") }
);

setting_enum!(
    /// Default text cursor shape (applications may override it with DECSCUSR).
    CursorShapeSetting {
        Bar => ("bar", "Bar (editor style)"),
        Block => ("block", "Block"),
        Underline => ("underline", "Underline"),
        BlockHollow => ("hollow", "Hollow block"),
    }
);

setting_enum!(
    /// Mouse pointer shown over the terminal grid.
    PointerStyle { IBeam => ("ibeam", "Text I-beam"), Arrow => ("arrow", "Arrow") }
);

setting_enum!(
    /// Shell prompt shown by the integration scripts (zsh and bash).
    PromptStyle {
        FolderGit => ("folder-git", "Folder and git branch"),
        Starship => ("starship", "Starship"),
        Minimal => ("minimal", "Minimal (❯ only)"),
        Folder => ("folder", "Folder"),
        PathGit => ("path-git", "Full path and git branch"),
        UserHost => ("user-host", "User, host and folder"),
        ShellDefault => ("shell-default", "Keep my shell's prompt"),
        Custom => ("custom", "Custom pattern"),
    }
);

impl PromptStyle {
    /// Prompt pattern for this style; `None` leaves the shell's own prompt alone. For Starship this
    /// is the pattern used until Starship is installed.
    pub fn template(self, custom: &str) -> Option<&str> {
        Some(match self {
            Self::FolderGit | Self::Starship => {
                "{bold}{blue}{dir}{reset}{magenta}{git}{reset} {cyan}{symbol}{reset} "
            }
            Self::Minimal => "{cyan}{symbol}{reset} ",
            Self::Folder => "{bold}{blue}{dir}{reset} {cyan}{symbol}{reset} ",
            Self::PathGit => {
                "{bold}{blue}{path}{reset}{magenta}{git}{reset} {cyan}{symbol}{reset} "
            }
            Self::UserHost => {
                "{green}{user}@{host}{reset} {bold}{blue}{dir}{reset} {cyan}{symbol}{reset} "
            }
            Self::ShellDefault => return None,
            Self::Custom => custom,
        })
    }
}

setting_enum!(
    /// How the window background is composited.
    BackgroundEffect { Opaque => ("opaque", "Opaque"), Transparent => ("transparent", "Transparent"), Blurred => ("blurred", "Blurred") }
);

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct TerminalSettings {
    // Appearance
    pub app_theme: AppTheme,
    pub color_scheme: String,
    pub font_family: String,
    pub font_size: f32,
    pub line_height: f32,
    pub letter_spacing: f32,
    pub font_ligatures: bool,
    pub bold_is_bright: bool,
    pub padding: f32,
    pub background_effect: BackgroundEffect,
    pub background_opacity: f32,

    // Cursor & pointer
    pub cursor_shape: CursorShapeSetting,
    pub cursor_blink: bool,
    pub pointer_style: PointerStyle,
    pub hide_pointer_while_typing: bool,

    // Mouse
    pub copy_on_select: bool,
    pub click_to_move_cursor: bool,
    pub mouse_reporting: bool,
    pub scroll_multiplier: f32,

    // Keyboard
    pub option_as_alt: bool,

    // Shell
    pub shell: String,
    pub working_directory: String,
    pub scrollback_lines: u32,
    pub visual_bell: bool,
    pub paste_protection: bool,
    pub shell_integration: bool,

    // Completions & history
    pub autosuggestions: bool,
    pub tab_completions: bool,
    pub completions_as_you_type: bool,
    pub import_shell_history: bool,

    // Prompt
    pub prompt_style: PromptStyle,
    pub prompt_template: String,
    pub hide_partial_line_marker: bool,
}

impl Default for TerminalSettings {
    fn default() -> Self {
        Self {
            app_theme: AppTheme::System,
            color_scheme: crate::schemes::MATCH_APP.to_owned(),
            font_family: "Menlo".to_owned(),
            font_size: 14.,
            line_height: 1.3,
            letter_spacing: 0.,
            font_ligatures: false,
            bold_is_bright: false,
            padding: 8.,
            background_effect: BackgroundEffect::Opaque,
            background_opacity: 1.,
            cursor_shape: CursorShapeSetting::Bar,
            cursor_blink: true,
            pointer_style: PointerStyle::IBeam,
            hide_pointer_while_typing: true,
            copy_on_select: false,
            click_to_move_cursor: true,
            mouse_reporting: true,
            scroll_multiplier: 1.,
            option_as_alt: false,
            shell: String::new(),
            working_directory: String::new(),
            scrollback_lines: 10_000,
            visual_bell: true,
            paste_protection: true,
            shell_integration: true,
            autosuggestions: true,
            tab_completions: true,
            completions_as_you_type: false,
            import_shell_history: true,
            prompt_style: PromptStyle::FolderGit,
            prompt_template: "{blue}{dir}{reset}{magenta}{git}{reset} {cyan}{symbol}{reset} "
                .to_owned(),
            hide_partial_line_marker: true,
        }
    }
}

impl Global for TerminalSettings {}

impl TerminalSettings {
    pub const MIN_FONT_SIZE: f32 = 6.;
    pub const MAX_FONT_SIZE: f32 = 48.;

    pub fn get(cx: &App) -> &Self {
        cx.global::<Self>()
    }

    /// Mutate the settings, persist them, and notify observers.
    pub fn update(cx: &mut App, f: impl FnOnce(&mut Self)) {
        let mut settings = Self::get(cx).clone();
        f(&mut settings);
        settings.sanitize();
        if &settings == Self::get(cx) {
            return;
        }
        if let Err(err) = settings.save() {
            eprintln!(
                "failed to save settings to {}: {err}",
                Self::path().display()
            );
        }
        cx.set_global(settings);
    }

    /// Load from disk, falling back to defaults when the file is missing or invalid.
    pub fn load() -> Self {
        let path = Self::path();
        let mut settings = match fs::read_to_string(&path) {
            Ok(json) => serde_json::from_str(&json).unwrap_or_else(|err| {
                eprintln!("ignoring invalid settings file {}: {err}", path.display());
                Self::default()
            }),
            Err(err) if err.kind() == io::ErrorKind::NotFound => Self::default(),
            Err(err) => {
                eprintln!("failed to read {}: {err}", path.display());
                Self::default()
            }
        };
        settings.sanitize();
        settings
    }

    pub fn save(&self) -> io::Result<()> {
        let path = Self::path();
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir)?;
        }
        let json = serde_json::to_string_pretty(self).map_err(io::Error::other)?;
        fs::write(path, json)
    }

    pub fn path() -> PathBuf {
        config_dir().join("settings.json")
    }

    /// Clamp numeric values into ranges the renderer can handle.
    fn sanitize(&mut self) {
        self.font_size = self
            .font_size
            .clamp(Self::MIN_FONT_SIZE, Self::MAX_FONT_SIZE);
        self.line_height = self.line_height.clamp(0.8, 3.);
        self.letter_spacing = self.letter_spacing.clamp(-2., 10.);
        self.padding = self.padding.clamp(0., 64.);
        self.background_opacity = self.background_opacity.clamp(0.2, 1.);
        self.scroll_multiplier = self.scroll_multiplier.clamp(0.1, 10.);
        self.scrollback_lines = self.scrollback_lines.min(1_000_000);
        if self.font_family.trim().is_empty() {
            self.font_family = Self::default().font_family;
        }
        if crate::schemes::find(&self.color_scheme).is_none()
            && self.color_scheme != crate::schemes::MATCH_APP
        {
            self.color_scheme = crate::schemes::MATCH_APP.to_owned();
        }
    }
}

/// The app's own folder: settings, projects, presets, history and generated shell scripts.
pub fn config_dir() -> PathBuf {
    let home = std::env::var_os("HOME").map_or_else(|| PathBuf::from("."), PathBuf::from);
    home.join(".config").join("bridge")
}

/// The app used to be called gpu-terminal: move its folder to the new name, once.
pub fn migrate_config_dir() {
    let new = config_dir();
    let Some(old) = new.parent().map(|parent| parent.join("gpu-terminal")) else {
        return;
    };
    if !new.exists()
        && old.is_dir()
        && let Err(err) = std::fs::rename(&old, &new)
    {
        eprintln!(
            "could not move {} to {}: {err}",
            old.display(),
            new.display()
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_through_json() {
        let settings = TerminalSettings {
            cursor_shape: CursorShapeSetting::Underline,
            font_size: 17.,
            ..TerminalSettings::default()
        };
        let json = serde_json::to_string(&settings).unwrap();
        assert_eq!(
            serde_json::from_str::<TerminalSettings>(&json).unwrap(),
            settings
        );
    }

    #[test]
    fn missing_fields_use_defaults_and_values_are_clamped() {
        let mut settings: TerminalSettings = serde_json::from_str(r#"{"font_size": 400}"#).unwrap();
        settings.sanitize();
        assert_eq!(settings.font_size, TerminalSettings::MAX_FONT_SIZE);
        assert_eq!(settings.cursor_shape, CursorShapeSetting::Bar);
    }

    #[test]
    fn enums_round_trip_through_dropdown_values() {
        for (value, _) in CursorShapeSetting::OPTIONS {
            assert_eq!(CursorShapeSetting::parse(value).unwrap().as_str(), *value);
        }
    }
}
