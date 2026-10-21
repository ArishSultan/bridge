//! Bridge: a workspace of projects, terminals, SSH servers and port forwards. gpui windows,
//! gpui-component widgets and the libghostty-vt state machine.

mod app;
mod assist;
mod completion;
mod fuzzy;
mod global_view;
mod glyphs;
mod group_icon;
mod history;
mod history_panel;
mod icons;
mod input;
mod marks;
mod profiles;
mod project_dialog;
mod pty;
mod sandbox;
mod schemes;
mod settings;
mod settings_panel;
mod sheet;
mod shell_integration;
mod ssh;
mod terminal;
mod terminal_dialog;
mod theme;
mod ui;
mod vault;
mod view;
mod welcome_view;
mod workspace;
mod workspace_view;

use gpui::{
    App, Context, CursorHideMode, KeyBinding, Menu, MenuItem, OsAction, Subscription,
    SystemMenuType, Window, WindowBackgroundAppearance, actions,
};

use crate::{
    history::History,
    settings::{AppTheme, BackgroundEffect, TerminalSettings},
};

actions!(
    bridge,
    [Quit, Hide, HideOthers, ShowAll, Minimize, Zoom, ShowWelcome]
);

/// The menu bar. Items show the shortcuts bound to their actions.
fn app_menus() -> Vec<Menu> {
    use workspace_view as workspace;
    vec![
        // macOS names the first menu after the app.
        Menu::new(workspace_view::APP_NAME).items([
            MenuItem::action("Settings", workspace::OpenSettings),
            MenuItem::separator(),
            MenuItem::os_submenu("Services", SystemMenuType::Services),
            MenuItem::separator(),
            MenuItem::action("Hide", Hide),
            MenuItem::action("Hide Others", HideOthers),
            MenuItem::action("Show All", ShowAll),
            MenuItem::separator(),
            MenuItem::action("Quit", Quit),
        ]),
        Menu::new("File").items([
            MenuItem::action("Open Folder", workspace::OpenFolder),
            MenuItem::separator(),
            MenuItem::action("New Terminal", workspace::NewShell),
            MenuItem::action("New Open Terminal", workspace::NewOpenShell),
            MenuItem::action("New Task", workspace::NewTask),
            MenuItem::separator(),
            MenuItem::action("Split Right", workspace::SplitRight),
            MenuItem::action("Split Down", workspace::SplitDown),
            MenuItem::separator(),
            MenuItem::action("Close", workspace::ClosePane),
        ]),
        Menu::new("Edit").items([
            MenuItem::os_action("Cut", view::Cut, OsAction::Cut),
            MenuItem::os_action("Copy", view::Copy, OsAction::Copy),
            MenuItem::os_action("Paste", view::Paste, OsAction::Paste),
            MenuItem::os_action("Select All", view::SelectAll, OsAction::SelectAll),
        ]),
        Menu::new("View").items([
            MenuItem::action("Toggle Sidebar", workspace::ToggleSidebar),
            MenuItem::separator(),
            MenuItem::action("Next Terminal", workspace::NextPane),
            MenuItem::action("Previous Terminal", workspace::PreviousPane),
            MenuItem::action("Next Item", workspace::NextView),
            MenuItem::action("Previous Item", workspace::PreviousView),
        ]),
        Menu::new("Window").items([
            MenuItem::action("Minimize", Minimize),
            MenuItem::action("Zoom", Zoom),
            MenuItem::separator(),
            MenuItem::action("Global", workspace::OpenGlobal),
            MenuItem::action("Welcome", ShowWelcome),
        ]),
    ]
}

/// Apply the theme, window transparency and pointer behavior from the settings.
pub(crate) fn apply_appearance(window: &mut Window, cx: &mut App) {
    theme::apply(window, cx);
    let settings = TerminalSettings::get(cx).clone();
    window.set_background_appearance(match settings.background_effect {
        BackgroundEffect::Opaque => WindowBackgroundAppearance::Opaque,
        BackgroundEffect::Transparent => WindowBackgroundAppearance::Transparent,
        BackgroundEffect::Blurred => WindowBackgroundAppearance::Blurred,
    });
    cx.set_cursor_hide_mode(if settings.hide_pointer_while_typing {
        CursorHideMode::OnTyping
    } else {
        CursorHideMode::Never
    });
    window.refresh();
}

/// Keep a window's appearance in step with the settings and, for the System theme, with macOS.
pub(crate) fn track_appearance<V: 'static>(
    window: &mut Window,
    cx: &mut Context<V>,
) -> Subscription {
    let settings = cx.observe_global_in::<TerminalSettings>(window, |_, window, cx| {
        apply_appearance(window, cx)
    });
    let system = cx.observe_window_appearance(window, |_, window, cx| {
        if TerminalSettings::get(cx).app_theme == AppTheme::System {
            apply_appearance(window, cx);
        }
    });
    Subscription::join(settings, system)
}

fn main() {
    // ssh runs this binary as its askpass helper to read saved passwords from the Keychain.
    if ssh::askpass::run_if_requested() || ssh::guard::run_if_requested() {
        return;
    }
    let application = gpui_platform::application().with_assets(icons::AppAssets);
    application.on_reopen(app::reopen);
    application.run(|cx: &mut App| {
        gpui_component::init(cx);
        settings::migrate_config_dir();
        let settings = TerminalSettings::load();
        if let Err(err) = shell_integration::install(&settings) {
            eprintln!("failed to install shell integration: {err}");
        }
        cx.set_global(History::load(settings.import_shell_history));
        cx.set_global(profiles::Profiles::load());
        cx.set_global(vault::Vault::default());
        cx.set_global(settings);
        // Running shells re-read the prompt file before each prompt, so this applies live.
        cx.observe_global::<TerminalSettings>(|cx| {
            if let Err(err) = shell_integration::write_prompts(TerminalSettings::get(cx)) {
                eprintln!("failed to update prompt settings: {err}");
            }
        })
        .detach();

        cx.bind_keys([
            KeyBinding::new("cmd-q", Quit, None),
            KeyBinding::new("cmd-h", Hide, None),
            KeyBinding::new("alt-cmd-h", HideOthers, None),
            KeyBinding::new("cmd-m", Minimize, None),
        ]);
        view::bind_keys(cx);
        workspace_view::bind_keys(cx);
        history_panel::bind_keys(cx);
        cx.on_action(|_: &Quit, cx| cx.quit());
        cx.on_action(|_: &ShowWelcome, cx| app::open_welcome(cx));
        cx.on_action(|_: &Hide, cx| cx.hide());
        cx.on_action(|_: &HideOthers, cx| cx.hide_other_apps());
        cx.on_action(|_: &ShowAll, cx| cx.unhide_other_apps());
        cx.on_action(|_: &Minimize, cx| {
            if let Some(window) = cx.active_window() {
                let _ = window.update(cx, |_, window, _| window.minimize_window());
            }
        });
        cx.on_action(|_: &Zoom, cx| {
            if let Some(window) = cx.active_window() {
                let _ = window.update(cx, |_, window, _| window.zoom_window());
            }
        });
        cx.set_menus(app_menus());
        app::init(cx);
        cx.activate(true);
    });
}
