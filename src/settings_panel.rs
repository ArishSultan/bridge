//! Settings sheet built from gpui-component's `Settings` component. Every field reads from and
//! writes to the [`TerminalSettings`] global, so changes apply live and are persisted.

use std::rc::Rc;

use gpui::{App, FontWeight, IntoElement, ParentElement, SharedString, Styled, Window, div, px};
use gpui_component::{
    ActiveTheme, Sizable,
    button::{Button, ButtonVariants},
    h_flex,
    setting::{NumberFieldOptions, SettingField, SettingGroup, SettingItem, SettingPage, Settings},
    v_flex,
};

use crate::{
    schemes,
    settings::{
        AppTheme, BackgroundEffect, CursorShapeSetting, PointerStyle, PromptStyle, TerminalSettings,
    },
    sheet,
    shell_integration::{self, Token},
    view::{ActiveTerminal, SHORTCUTS},
    workspace_view,
};

type Options = Rc<Vec<(SharedString, SharedString)>>;

pub fn open(window: &mut Window, cx: &mut App) {
    let fonts = font_options(cx);
    sheet::open("Settings", px(780.), window, cx, move |_, cx| {
        settings(fonts.clone(), TerminalSettings::get(cx)).into_any_element()
    });
}

fn settings(fonts: Options, current: &TerminalSettings) -> impl IntoElement + use<> {
    Settings::new("terminal-settings").pages([
        appearance_page(fonts),
        prompt_page(current),
        cursor_and_mouse_page(),
        completions_page(),
        keyboard_page(),
        shell_page(),
    ])
}

fn prompt_page(current: &TerminalSettings) -> SettingPage {
    let custom = current.prompt_style == PromptStyle::Custom;
    let mut items = vec![dropdown(
        "Style",
        "Choose what the prompt shows, e.g. hide your user and computer name.",
        options(PromptStyle::OPTIONS),
        |s| s.prompt_style.as_str().into(),
        |s, v| s.prompt_style = PromptStyle::parse(v).unwrap_or_default(),
    )];
    if current.prompt_style == PromptStyle::Starship {
        items.push(SettingItem::render(|_, _, cx| starship_status(cx)));
    }
    SettingPage::new("Prompt").groups([
        SettingGroup::new()
            .title("Prompt")
            .description(
                "Shown before every command in zsh and bash. Changes apply at the next prompt.",
            )
            .items(
                items.into_iter().chain([
                    input(
                        "Custom pattern",
                        "Used when the style is \"Custom pattern\". See the tokens below.",
                        |s| s.prompt_template.clone(),
                        |s, v| s.prompt_template = v,
                    )
                    .disabled(!custom),
                    SettingItem::render(|_, _, cx| prompt_preview(cx)),
                    switch(
                        "Hide the % marker",
                        "zsh marks output that doesn't end in a newline with an inverted %.",
                        |s| s.hide_partial_line_marker,
                        |s, v| s.hide_partial_line_marker = v,
                    ),
                ]),
            ),
        SettingGroup::new()
            .title("Pattern tokens")
            .item(SettingItem::render(|_, _, cx| token_table(cx))),
    ])
}

const BREW_PATHS: &[&str] = &["/opt/homebrew/bin/brew", "/usr/local/bin/brew"];

/// Starship install state, with a one-click Homebrew install when it is missing.
fn starship_status(cx: &App) -> impl IntoElement + use<> {
    let muted = cx.theme().muted_foreground;
    let row = h_flex().w_full().gap_3().justify_between();
    if shell_integration::starship_installed() {
        return row.child(
            div()
                .text_sm()
                .text_color(muted)
                .child("Starship is installed and runs automatically. Its settings live in ~/.config/starship.toml."),
        );
    }
    let message =
        div().flex_1().text_sm().text_color(muted).child(
            "Starship isn't installed yet, so the folder and git prompt is shown until it is.",
        );
    let Some(brew) = BREW_PATHS
        .iter()
        .find(|path| std::path::Path::new(path).is_file())
    else {
        return row.child(message.child(" Install it from starship.rs."));
    };
    let command = format!("{brew} install starship");
    row.child(message).child(
        Button::new("install-starship")
            .small()
            .primary()
            .label("Install Starship")
            .on_click(move |_, window, cx| {
                if let Some(view) = cx
                    .try_global::<ActiveTerminal>()
                    .and_then(|active| active.0.upgrade())
                {
                    view.update(cx, |view, cx| view.run_command(&command, cx));
                }
                sheet::close(window, cx);
            }),
    )
}

/// Render the active prompt pattern with sample values, the way the shell will show it.
fn prompt_preview(cx: &App) -> impl IntoElement + use<> {
    let settings = TerminalSettings::get(cx);
    let theme = cx.theme();
    let row = h_flex()
        .w_full()
        .p_2()
        .rounded_md()
        .bg(theme.muted)
        .font_family(SharedString::from(settings.font_family.clone()))
        .text_sm();
    let starship =
        settings.prompt_style == PromptStyle::Starship && shell_integration::starship_installed();
    let pattern = settings
        .prompt_style
        .template(&settings.prompt_template)
        .filter(|_| !starship);
    let Some(pattern) = pattern else {
        let message = if starship {
            "Starship draws the prompt."
        } else {
            "Your shell's own prompt is used."
        };
        return row.text_color(theme.muted_foreground).child(message);
    };

    let palette = [
        theme.foreground,
        theme.red,
        theme.green,
        theme.yellow,
        theme.blue,
        theme.magenta,
        theme.cyan,
        theme.foreground,
        theme.muted_foreground,
    ];
    let user = std::env::var("USER").unwrap_or_else(|_| "you".to_owned());
    let mut color = theme.foreground;
    let mut bold = false;
    let mut lines = vec![Vec::new()];
    for token in shell_integration::parse(pattern) {
        let text: SharedString = match token {
            Token::Text(text) => text.to_owned().into(),
            Token::User => user.clone().into(),
            Token::Host => "my-mac".into(),
            Token::Dir => "projects".into(),
            Token::Path => "~/projects".into(),
            Token::Git => " main".into(),
            Token::Time => "09:41".into(),
            Token::Symbol => "❯".into(),
            Token::Newline => {
                lines.push(Vec::new());
                continue;
            }
            Token::Color(index) => {
                color = palette[usize::from(index.min(8))];
                continue;
            }
            Token::Bold => {
                bold = true;
                continue;
            }
            Token::Reset => {
                color = theme.foreground;
                bold = false;
                continue;
            }
        };
        let span = div().text_color(color).child(text);
        lines.last_mut().expect("at least one line").push(if bold {
            span.font_weight(FontWeight::BOLD)
        } else {
            span
        });
    }
    // A sample command after the last prompt line shows where typing starts.
    lines
        .last_mut()
        .expect("at least one line")
        .push(div().text_color(theme.foreground).child("ls -la"));
    row.child(
        v_flex().children(
            lines
                .into_iter()
                .map(|spans| h_flex().whitespace_nowrap().children(spans)),
        ),
    )
}

fn token_table(cx: &App) -> impl IntoElement + use<> {
    let muted = cx.theme().muted_foreground;
    v_flex()
        .w_full()
        .gap_1()
        .children(shell_integration::TOKENS.iter().map(|(token, meaning)| {
            h_flex()
                .w_full()
                .justify_between()
                .gap_4()
                .child(div().text_sm().font_family("Menlo").child(*token))
                .child(div().text_sm().text_color(muted).child(*meaning))
        }))
}

fn appearance_page(fonts: Options) -> SettingPage {
    SettingPage::new("Appearance").default_open(true).groups([
        SettingGroup::new().title("Theme").items([
            dropdown(
                "App theme",
                "Light or dark, when the color scheme matches the app.",
                options(AppTheme::OPTIONS),
                |s| AppTheme::as_str(s.app_theme).into(),
                |s, v| s.app_theme = AppTheme::parse(v).unwrap_or_default(),
            ),
            dropdown(
                "Color scheme",
                "Terminal colors; the window is tinted to match, and a scheme picks light or dark.",
                options(&schemes::options()),
                |s| s.color_scheme.clone().into(),
                |s, v| s.color_scheme = v.to_owned(),
            ),
            switch(
                "Bold is bright",
                "Draw bold text with the bright variant of the 8 basic colors.",
                |s| s.bold_is_bright,
                |s, v| s.bold_is_bright = v,
            ),
        ]),
        SettingGroup::new().title("Font").items([
            SettingItem::new(
                "Font family",
                SettingField::scrollable_dropdown(
                    (*fonts).clone(),
                    |cx| TerminalSettings::get(cx).font_family.clone().into(),
                    |value, cx| TerminalSettings::update(cx, |s| s.font_family = value.to_string()),
                )
                .default_value(SharedString::from(TerminalSettings::default().font_family)),
            )
            .description("Monospace fonts keep the grid aligned."),
            number(
                "Font size",
                "Point size of terminal text (⌘= / ⌘- / ⌘0).",
                (
                    TerminalSettings::MIN_FONT_SIZE.into(),
                    TerminalSettings::MAX_FONT_SIZE.into(),
                    1.,
                ),
                |s| s.font_size,
                |s, v| s.font_size = v,
            ),
            number(
                "Line height",
                "Multiple of the font size.",
                (0.8, 3., 0.05),
                |s| s.line_height,
                |s, v| s.line_height = v,
            ),
            number(
                "Letter spacing",
                "Extra horizontal space per cell, in pixels.",
                (-2., 10., 0.5),
                |s| s.letter_spacing,
                |s, v| s.letter_spacing = v,
            ),
            switch(
                "Ligatures",
                "Enable programming ligatures supported by the font.",
                |s| s.font_ligatures,
                |s, v| s.font_ligatures = v,
            ),
        ]),
        SettingGroup::new().title("Window").items([
            number(
                "Padding",
                "Space between the window edge and the grid, in pixels.",
                (0., 64., 1.),
                |s| s.padding,
                |s, v| s.padding = v,
            ),
            dropdown(
                "Terminal background",
                "Opaque, transparent or blurred (vibrancy) background behind the terminal.",
                options(BackgroundEffect::OPTIONS),
                |s| s.background_effect.as_str().into(),
                |s, v| s.background_effect = BackgroundEffect::parse(v).unwrap_or_default(),
            ),
            number(
                "Background opacity",
                "Used when the terminal background is transparent or blurred.",
                (0.2, 1., 0.05),
                |s| s.background_opacity,
                |s, v| s.background_opacity = v,
            ),
        ]),
    ])
}

fn cursor_and_mouse_page() -> SettingPage {
    SettingPage::new("Cursor & Mouse").groups([
        SettingGroup::new().title("Text cursor").items([
            dropdown(
                "Cursor style",
                "Default shape; programs like vim may change it while running.",
                options(CursorShapeSetting::OPTIONS),
                |s| s.cursor_shape.as_str().into(),
                |s, v| s.cursor_shape = CursorShapeSetting::parse(v).unwrap_or_default(),
            ),
            switch(
                "Blink",
                "Blink the cursor while the window is focused.",
                |s| s.cursor_blink,
                |s, v| s.cursor_blink = v,
            ),
        ]),
        SettingGroup::new().title("Mouse pointer").items([
            dropdown(
                "Pointer style",
                "Pointer shown over the terminal.",
                options(PointerStyle::OPTIONS),
                |s| s.pointer_style.as_str().into(),
                |s, v| s.pointer_style = PointerStyle::parse(v).unwrap_or_default(),
            ),
            switch(
                "Hide while typing",
                "Hide the pointer until the mouse moves.",
                |s| s.hide_pointer_while_typing,
                |s, v| s.hide_pointer_while_typing = v,
            ),
        ]),
        SettingGroup::new().title("Mouse").items([
            switch(
                "Click to move cursor",
                "Clicking on the prompt line moves the shell cursor there.",
                |s| s.click_to_move_cursor,
                |s, v| s.click_to_move_cursor = v,
            ),
            switch(
                "Copy on select",
                "Copy selected text to the clipboard automatically.",
                |s| s.copy_on_select,
                |s, v| s.copy_on_select = v,
            ),
            switch(
                "Mouse reporting",
                "Let programs like vim, htop and tmux receive mouse events (hold ⇧ to select).",
                |s| s.mouse_reporting,
                |s, v| s.mouse_reporting = v,
            ),
            number(
                "Scroll speed",
                "Multiplier for wheel and trackpad scrolling.",
                (0.1, 10., 0.1),
                |s| s.scroll_multiplier,
                |s, v| s.scroll_multiplier = v,
            ),
        ]),
    ])
}

fn completions_page() -> SettingPage {
    SettingPage::new("Completions").groups([
        SettingGroup::new()
            .title("While typing")
            .description("Works in zsh and bash with shell integration turned on.")
            .items([
                switch(
                    "History suggestions",
                    "Show the most recent matching command in gray after the cursor; press → to accept it.",
                    |s| s.autosuggestions,
                    |s, v| s.autosuggestions = v,
                ),
                switch(
                    "Tab opens completions",
                    "Tab shows a menu of commands, subcommands, branches, scripts and files.",
                    |s| s.tab_completions,
                    |s, v| s.tab_completions = v,
                ),
                switch(
                    "Show completions as you type",
                    "Open the completion menu automatically instead of waiting for Tab.",
                    |s| s.completions_as_you_type,
                    |s, v| s.completions_as_you_type = v,
                ),
            ]),
        SettingGroup::new().title("History").items([switch(
            "Include shell history",
            "Also list commands from ~/.zsh_history and ~/.bash_history (applies after restarting the app).",
            |s| s.import_shell_history,
            |s, v| s.import_shell_history = v,
        )]),
    ])
}

fn keyboard_page() -> SettingPage {
    SettingPage::new("Keyboard").groups([
        SettingGroup::new().title("Input").items([switch(
            "Option as Alt",
            "Send Option+key as Alt (Esc prefix) instead of typing special characters.",
            |s| s.option_as_alt,
            |s, v| s.option_as_alt = v,
        )]),
        SettingGroup::new()
            .title("Tabs and panes")
            .item(SettingItem::render(|_, _, cx| {
                shortcut_table(workspace_view::SHORTCUTS, cx)
            })),
        SettingGroup::new()
            .title("Editing")
            .item(SettingItem::render(|_, _, cx| {
                shortcut_table(SHORTCUTS, cx)
            })),
    ])
}

fn shell_page() -> SettingPage {
    SettingPage::new("Shell").groups([
        SettingGroup::new()
            .title("Session")
            .description(
                "Shell, directory and scrollback apply to the next session (⌘⇧R restarts).",
            )
            .items([
                input(
                    "Shell command",
                    "Program and arguments; leave empty for your login shell.",
                    |s| s.shell.clone(),
                    |s, v| s.shell = v,
                ),
                input(
                    "Working directory",
                    "Starting directory; leave empty for your home folder.",
                    |s| s.working_directory.clone(),
                    |s, v| s.working_directory = v,
                ),
                number(
                    "Scrollback lines",
                    "Lines of history kept above the screen.",
                    (0., 1_000_000., 1000.),
                    |s| s.scrollback_lines as f32,
                    |s, v| s.scrollback_lines = v.max(0.) as u32,
                ),
            ]),
        SettingGroup::new().title("Behavior").items([
            switch(
                "Shell integration",
                "Load prompt settings and key fixes into zsh and bash (applies to new sessions).",
                |s| s.shell_integration,
                |s, v| s.shell_integration = v,
            ),
            switch(
                "Visual bell",
                "Flash the terminal on the bell character.",
                |s| s.visual_bell,
                |s, v| s.visual_bell = v,
            ),
            switch(
                "Paste protection",
                "Ask before pasting text that could run commands immediately.",
                |s| s.paste_protection,
                |s, v| s.paste_protection = v,
            ),
        ]),
    ])
}

fn shortcut_table(
    shortcuts: &'static [(&'static str, &'static str)],
    cx: &App,
) -> impl IntoElement + use<> {
    let muted = cx.theme().muted_foreground;
    v_flex()
        .w_full()
        .gap_1()
        .children(shortcuts.iter().map(|(keys, action)| {
            h_flex()
                .w_full()
                .justify_between()
                .child(div().text_sm().child(*action))
                .child(div().text_sm().text_color(muted).child(*keys))
        }))
}

fn switch(
    title: &'static str,
    description: &'static str,
    get: fn(&TerminalSettings) -> bool,
    set: fn(&mut TerminalSettings, bool),
) -> SettingItem {
    SettingItem::new(
        title,
        SettingField::switch(
            move |cx| get(TerminalSettings::get(cx)),
            move |value, cx| TerminalSettings::update(cx, |s| set(s, value)),
        )
        .default_value(get(&TerminalSettings::default())),
    )
    .description(description)
}

fn number(
    title: &'static str,
    description: &'static str,
    (min, max, step): (f64, f64, f64),
    get: fn(&TerminalSettings) -> f32,
    set: fn(&mut TerminalSettings, f32),
) -> SettingItem {
    SettingItem::new(
        title,
        SettingField::number_input(
            NumberFieldOptions { min, max, step },
            move |cx| f64::from(get(TerminalSettings::get(cx))),
            move |value, cx| TerminalSettings::update(cx, |s| set(s, value as f32)),
        )
        .default_value(f64::from(get(&TerminalSettings::default()))),
    )
    .description(description)
}

fn dropdown(
    title: &'static str,
    description: &'static str,
    options: Options,
    get: fn(&TerminalSettings) -> SharedString,
    set: fn(&mut TerminalSettings, &str),
) -> SettingItem {
    SettingItem::new(
        title,
        SettingField::dropdown(
            (*options).clone(),
            move |cx| get(TerminalSettings::get(cx)),
            move |value, cx| TerminalSettings::update(cx, |s| set(s, &value)),
        )
        .default_value(get(&TerminalSettings::default())),
    )
    .description(description)
}

fn input(
    title: &'static str,
    description: &'static str,
    get: fn(&TerminalSettings) -> String,
    set: fn(&mut TerminalSettings, String),
) -> SettingItem {
    SettingItem::new(
        title,
        SettingField::input(
            move |cx| get(TerminalSettings::get(cx)).into(),
            move |value, cx| TerminalSettings::update(cx, |s| set(s, value.to_string())),
        )
        .default_value(SharedString::from(get(&TerminalSettings::default()))),
    )
    .description(description)
}

fn options(pairs: &[(&'static str, &'static str)]) -> Options {
    Rc::new(
        pairs
            .iter()
            .map(|(value, label)| {
                (
                    SharedString::new_static(value),
                    SharedString::new_static(label),
                )
            })
            .collect(),
    )
}

/// Every installed font family, with the configured one guaranteed to be present.
fn font_options(cx: &App) -> Options {
    let mut names = cx.text_system().all_font_names();
    names.push(TerminalSettings::get(cx).font_family.clone());
    names.sort_by_key(|name| name.to_lowercase());
    names.dedup();
    Rc::new(
        names
            .into_iter()
            .filter(|name| !name.starts_with('.'))
            .map(|name| {
                let name = SharedString::from(name);
                (name.clone(), name)
            })
            .collect(),
    )
}
