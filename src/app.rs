//! The app's windows: a window per project, the Global window (a project window of its own, for
//! terminals outside any project and the presets every project shares) and a Welcome window, each
//! open at most once. Opening one that is already open brings it to the front. Port forwards belong to the
//! app, not to a window, so they keep running with every window closed.

use std::{collections::HashMap, path::PathBuf};

use gpui::{
    AnyWindowHandle, App, AppContext as _, BorrowAppContext as _, Bounds, Entity, Global,
    PathPromptOptions, Render, SharedString, SystemNotification, Window, WindowBounds,
    WindowOptions, px, size,
};
use gpui_component::{Root, TitleBar};

use crate::{
    profiles::{Profiles, SshAuth},
    project_dialog,
    ssh::forward::{Dropped, ForwardManager},
    vault::Vault,
    welcome_view::WelcomeView,
    workspace::{Id, Projects, tilde},
    workspace_view::{OpenFolder, OpenGlobal, WorkspaceView},
};

#[derive(Default)]
struct Windows {
    projects: HashMap<Id, AnyWindowHandle>,
    welcome: Option<AnyWindowHandle>,
}

impl Global for Windows {}

struct Forwards(Entity<ForwardManager>);

impl Global for Forwards {}

/// The app's port forwards.
pub fn forwards(cx: &App) -> Entity<ForwardManager> {
    cx.global::<Forwards>().0.clone()
}

/// Set up the app-wide state, then open the windows that were open when the app last quit (or
/// the Welcome window).
pub fn init(cx: &mut App) {
    cx.set_global(Projects::load());
    cx.set_global(Windows::default());
    cx.on_action(|_: &OpenFolder, cx| open_folder(cx));
    cx.on_action(|_: &OpenGlobal, cx| open_global(cx));
    // Vaultwarden locks itself after a while unused, with or without a window open.
    cx.spawn(async |cx| {
        loop {
            cx.background_executor()
                .timer(std::time::Duration::from_secs(5))
                .await;
            cx.update(Vault::lock_if_idle);
        }
    })
    .detach();
    let manager = cx.new(ForwardManager::new);
    cx.subscribe(&manager, |_, dropped: &Dropped, cx| {
        if dropped.notify {
            let name = Profiles::get(cx)
                .forward(dropped.forward)
                .map(|(host, forward)| {
                    format!(
                        "{} ({})",
                        crate::global_view::forward_name(forward),
                        host.name
                    )
                })
                .unwrap_or_default();
            notify(
                format!("Port forward stopped: {name}"),
                dropped.reason.clone(),
                cx,
            );
        }
    })
    .detach();
    cx.set_global(Forwards(manager));
    // Forwards signing in with a vault key restart as the vault locks or unlocks.
    cx.observe_global::<Vault>(|cx| {
        let ids: Vec<Id> = Profiles::get(cx)
            .hosts
            .iter()
            .filter(|host| matches!(host.auth, SshAuth::Vault { .. }))
            .flat_map(|host| host.forwards.iter().map(|forward| forward.id))
            .collect();
        forwards(cx).update(cx, |manager, cx| {
            for forward in ids {
                manager.reload(forward, cx);
            }
        });
    })
    .detach();
    cx.on_window_closed(|cx, closed| {
        let windows = cx.global_mut::<Windows>();
        windows
            .projects
            .retain(|_, handle| handle.window_id() != closed);
        if windows
            .welcome
            .is_some_and(|handle| handle.window_id() == closed)
        {
            windows.welcome = None;
        }
    })
    .detach();
    cx.on_app_quit(|cx| {
        remember_open_windows(cx);
        forwards(cx).update(cx, |forwards, _| forwards.stop_all());
        Vault::lock(cx);
        async {}
    })
    .detach();

    let (open, global) = {
        let projects = cx.global::<Projects>();
        (projects.open.clone(), projects.global_open)
    };
    for project in open {
        open_project(project, false, cx);
    }
    if global {
        open_global(cx);
    }
    if cx.windows().is_empty() {
        open_welcome(cx);
    }
}

/// A click on the Dock icon: with every window closed, the Welcome window.
pub fn reopen(cx: &mut App) {
    if cx.windows().is_empty() {
        open_welcome(cx);
    }
}

/// Note which windows are open, for the next launch.
fn remember_open_windows(cx: &mut App) {
    let open: Vec<Id> = cx.global::<Windows>().projects.keys().copied().collect();
    cx.update_global::<Projects, _>(|projects, _| {
        projects.open = open;
        // Kept in `open` now, with the other windows.
        projects.global_open = false;
        if let Err(err) = projects.save() {
            eprintln!("failed to save projects: {err}");
        }
    });
}

/// Tell the user something happened in the background.
pub fn notify(title: String, body: String, cx: &mut App) {
    cx.show_system_notification(SystemNotification {
        tag: SharedString::from(format!("bridge-{title}")),
        title: title.into(),
        body: body.into(),
        actions: Vec::new(),
    });
}

fn options(width: f32, height: f32, cx: &App) -> WindowOptions {
    WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
            None,
            size(px(width), px(height)),
            cx,
        ))),
        window_min_size: Some(size(px(360.), px(240.))),
        ..TitleBar::window_options()
    }
}

/// Open a window showing `build`'s view.
fn open<V: Render + 'static>(
    width: f32,
    height: f32,
    cx: &mut App,
    build: impl FnOnce(&mut Window, &mut gpui::Context<V>) -> V,
) -> Option<AnyWindowHandle> {
    let opened = cx.open_window(options(width, height, cx), |window, cx| {
        crate::apply_appearance(window, cx);
        let view = cx.new(|cx| build(window, cx));
        cx.new(|cx| Root::new(view, window, cx))
    });
    match opened {
        Ok(handle) => Some(handle.into()),
        Err(err) => {
            eprintln!("failed to open window: {err:?}");
            None
        }
    }
}

/// Bring an open window to the front.
fn activate(handle: AnyWindowHandle, cx: &mut App) -> bool {
    handle
        .update(cx, |_, window, _| window.activate_window())
        .is_ok()
}

/// Open a project's window, or bring it to the front. `first_terminal` asks for its first
/// terminal right away (a project just added).
pub fn open_project(project: Id, first_terminal: bool, cx: &mut App) {
    if let Some(handle) = cx.global::<Windows>().projects.get(&project).copied()
        && activate(handle, cx)
    {
        return;
    }
    let Some(found) = cx.global::<Projects>().project(project).cloned() else {
        return;
    };
    if let Some(handle) = open(1080., 700., cx, |window, cx| {
        WorkspaceView::new(found, first_terminal, window, cx)
    }) {
        cx.global_mut::<Windows>().projects.insert(project, handle);
        close_welcome(cx);
        cx.activate(true);
    }
}

/// Pick a folder and open it as a project (added the first time).
pub fn open_folder(cx: &mut App) {
    let paths = cx.prompt_for_paths(PathPromptOptions {
        files: false,
        directories: true,
        multiple: false,
        prompt: Some("Open".into()),
    });
    cx.spawn(async move |cx| {
        if let Ok(Ok(Some(paths))) = paths.await
            && let Some(dir) = paths.into_iter().next()
        {
            cx.update(|cx| open_dir(dir, cx));
        }
    })
    .detach();
}

fn open_dir(dir: PathBuf, cx: &mut App) {
    let existing = cx.global::<Projects>().find_dir(&dir);
    let (project, added) = match existing {
        Some(project) => (project, false),
        None => {
            let name = project_dialog::folder_name(&dir);
            let project = cx.update_global::<Projects, _>(|projects, _| {
                let project = projects.add_project(name, tilde(&dir.to_string_lossy()));
                if let Err(err) = projects.save() {
                    eprintln!("failed to save projects: {err}");
                }
                project
            });
            (project, true)
        }
    };
    open_project(project, added, cx);
}

/// Open the Global window, or bring it to the front.
pub fn open_global(cx: &mut App) {
    let global = cx.update_global::<Projects, _>(|projects, _| projects.global_id());
    open_project(global, false, cx);
}

/// Open the Welcome window (recent projects, Open Folder, Global), or bring it to the front.
pub fn open_welcome(cx: &mut App) {
    if let Some(handle) = cx.global::<Windows>().welcome
        && activate(handle, cx)
    {
        return;
    }
    if let Some(handle) = open(560., 460., cx, WelcomeView::new) {
        cx.global_mut::<Windows>().welcome = Some(handle);
        cx.activate(true);
    }
}

fn close_welcome(cx: &mut App) {
    if let Some(handle) = cx.global_mut::<Windows>().welcome.take() {
        let _ = handle.update(cx, |_, window, _| window.remove_window());
    }
}

/// Whether a project's window is open.
pub fn is_open(project: Id, cx: &App) -> bool {
    cx.global::<Windows>().projects.contains_key(&project)
}
