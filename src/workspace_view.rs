//! Window content: the title bar, a sidebar of projects and their items (or, in Global mode, the
//! presets every project shares: SSH hosts, port forwards, sandboxes), and the active item.
//!
//! An item of a project is one terminal; adding a terminal beside it makes it a view, a grid of
//! terminals each with a header of its own. An item's terminals only run once it is opened. Leaving
//! it stops the terminals not marked to keep running in the background (after asking), which frees
//! them entirely.

use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    process::Command,
    rc::Rc,
    time::{Duration, Instant},
};

use gpui::{
    AnyElement, App, AppContext as _, BorrowAppContext as _, Bounds, ClickEvent, Context, Corners,
    DragMoveEvent, Entity, Focusable, FontWeight, InteractiveElement, IntoElement, KeyBinding,
    MouseButton, ParentElement, Pixels, Point, Render, SharedString, StatefulInteractiveElement,
    Styled, Subscription, SystemNotification, Task, WeakEntity, Window, actions, div,
    prelude::FluentBuilder as _, px,
};
use gpui_base::Transition;
use gpui_component::{
    ActiveTheme, Icon, Sizable, TitleBar, WindowExt as _,
    button::{Button, ButtonVariants},
    dialog::DialogEntrance,
    h_flex, h_resizable,
    input::{Input, InputEvent, InputState},
    menu::{ContextMenuExt, PopupMenuItem},
    notification::Notification,
    resizable_panel,
    tooltip::Tooltip,
    v_flex, v_resizable,
};

use crate::{
    app,
    global_view::PresetsPanel,
    history_panel,
    icons::IconName,
    profiles::{OnDisconnect, Profiles, SandboxEngine, SshAuth, keychain},
    project_dialog::{self, ProjectForm},
    sandbox,
    settings::{BackgroundEffect, TerminalSettings},
    settings_panel, sheet, shell_integration, ssh, terminal_dialog,
    vault::{self, Vault},
    view::{Launch, TerminalEvent, TerminalView},
    workspace::{
        Id, Isolation, Layout, Project, Projects, Side, SplitAxis, TerminalKind, TerminalSpec,
        View, tilde,
    },
};

actions!(
    workspace,
    [
        NewShell,
        NewOpenShell,
        NewTask,
        OpenFolder,
        OpenGlobal,
        SplitRight,
        SplitDown,
        ClosePane,
        NextView,
        PreviousView,
        NextPane,
        PreviousPane,
        ToggleSidebar,
        OpenSettings,
        SelectView1,
        SelectView2,
        SelectView3,
        SelectView4,
        SelectView5,
        SelectView6,
        SelectView7,
        SelectView8,
        SelectView9,
    ]
);

pub const APP_NAME: &str = "Bridge";
const SIDEBAR_WIDTH: f32 = 248.;
/// The terminal area is a card inset from the chrome, like shadcn's inset sidebar layout.
const CONTENT_GUTTER: f32 = 6.;
const CONTENT_RADIUS: f32 = 10.;
/// The radius of what sits just inside the card's border.
const INNER_RADIUS: f32 = CONTENT_RADIUS - 1.;
/// How often the title catches up with the foreground process (Terminal.app polls too).
const TITLE_POLL: Duration = Duration::from_secs(1);

pub fn bind_keys(cx: &mut App) {
    cx.bind_keys([
        KeyBinding::new("cmd-t", NewShell, None),
        KeyBinding::new("cmd-shift-t", NewOpenShell, None),
        KeyBinding::new("cmd-shift-e", NewTask, None),
        KeyBinding::new("cmd-o", OpenFolder, None),
        KeyBinding::new("cmd-shift-g", OpenGlobal, None),
        KeyBinding::new("cmd-d", SplitRight, None),
        KeyBinding::new("cmd-shift-d", SplitDown, None),
        KeyBinding::new("cmd-w", ClosePane, None),
        KeyBinding::new("ctrl-tab", NextView, None),
        KeyBinding::new("ctrl-shift-tab", PreviousView, None),
        KeyBinding::new("cmd-shift-]", NextView, None),
        KeyBinding::new("cmd-shift-[", PreviousView, None),
        KeyBinding::new("cmd-]", NextPane, None),
        KeyBinding::new("cmd-[", PreviousPane, None),
        KeyBinding::new("cmd-b", ToggleSidebar, None),
        KeyBinding::new("cmd-,", OpenSettings, None),
        KeyBinding::new("cmd-1", SelectView1, None),
        KeyBinding::new("cmd-2", SelectView2, None),
        KeyBinding::new("cmd-3", SelectView3, None),
        KeyBinding::new("cmd-4", SelectView4, None),
        KeyBinding::new("cmd-5", SelectView5, None),
        KeyBinding::new("cmd-6", SelectView6, None),
        KeyBinding::new("cmd-7", SelectView7, None),
        KeyBinding::new("cmd-8", SelectView8, None),
        KeyBinding::new("cmd-9", SelectView9, None),
    ]);
}

/// Shortcut reference shown in the settings panel.
pub const SHORTCUTS: &[(&str, &str)] = &[
    (
        "⌘T / ⌘⇧T",
        "New terminal in the project (a sandboxed / open shell preselected)",
    ),
    ("⌘⇧E", "New task (a terminal bound to one command)"),
    ("⌘O", "Open a folder as a project (in a window of its own)"),
    ("⌘⇧G", "Global: SSH hosts, port forwards, sandboxes"),
    (
        "⌘D / ⌘⇧D",
        "Add a terminal to the right / below, making a view",
    ),
    (
        "⌘W",
        "Close a terminal of a view, else the window (asks while they run)",
    ),
    (
        "Drag a terminal's header",
        "Drop it on an edge of another to split there, or in the middle to swap",
    ),
    ("⌘] / ⌘[", "Next / previous terminal of the view"),
    ("⌃Tab / ⌘⇧] / ⌘⇧[", "Next / previous item of the project"),
    ("⌘1 … ⌘9", "Go to an item of the project"),
    ("⌘B", "Show / hide the sidebar"),
    ("Double-click", "Rename a project, view or terminal"),
    ("Right-click", "More for a project, terminal or view"),
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum RenameTarget {
    Project,
    View(Id),
    Terminal(Id),
}

struct Renaming {
    target: RenameTarget,
    input: Entity<InputState>,
    _subscription: Subscription,
}

/// Where a new terminal goes.
#[derive(Clone, Copy)]
enum Place {
    /// A new item of the project.
    NewItem,
    /// Beside the focused terminal of an item, along an axis.
    Beside(Id, SplitAxis),
}

/// Which edges of the content card a pane touches, to round its corners like the card's.
#[derive(Clone, Copy)]
struct Edges {
    top: bool,
    bottom: bool,
    left: bool,
    right: bool,
}

impl Edges {
    const ALL: Self = Self {
        top: true,
        bottom: true,
        left: true,
        right: true,
    };

    fn radius(touches: bool) -> gpui::Pixels {
        px(if touches { INNER_RADIUS } else { 0. })
    }
}

/// A pane being dragged by its header onto another pane.
#[derive(Clone)]
struct DraggedPane {
    pane: Id,
    label: SharedString,
}

impl Render for DraggedPane {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.theme();
        h_flex()
            .px_2()
            .py_1()
            .gap_1p5()
            .rounded_md()
            .bg(theme.popover)
            .border_1()
            .border_color(theme.border)
            .shadow_md()
            .text_xs()
            .text_color(theme.popover_foreground)
            .child(
                Icon::new(IconName::SquareTerminal)
                    .xsmall()
                    .text_color(theme.muted_foreground),
            )
            .child(self.label.clone())
    }
}

/// A project's window.
pub struct WorkspaceView {
    /// This window's copy of the project; saving puts it back in the [`Projects`] global.
    project: Project,
    /// The Global window: terminals outside any project, beside the presets every project shares.
    global: bool,
    presets: Option<Entity<PresetsPanel>>,
    sidebar_open: bool,
    /// Terminals that exist this session: those of opened views, and background ones.
    panes: HashMap<Id, Entity<TerminalView>>,
    pane_subscriptions: HashMap<Id, Subscription>,
    /// How each exited terminal ended (`None`: unknown), for its status dot.
    exits: HashMap<Id, Option<u32>>,
    renaming: Option<Renaming>,
    /// While a pane is dragged: the pane under it and where it would land (`None`: swap with it).
    drop_target: Option<(Id, Option<Side>)>,
    /// SSH panes reconnecting on their own: attempts so far and when the last one started.
    ssh_retries: HashMap<Id, (u32, Instant)>,
    /// Window title and pane labels as last shown, to repaint only when they change.
    shown_titles: String,
    _title_refresh: Task<()>,
    _title_poll: Task<()>,
    _subscriptions: Vec<Subscription>,
}

impl WorkspaceView {
    pub fn new(
        project: Project,
        first_terminal: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let subscriptions = vec![
            cx.on_app_quit(|this, cx| {
                this.save(cx);
                for pane in this.panes.keys().copied().collect::<Vec<_>>() {
                    this.stop_container(pane, cx);
                }
                async {}
            }),
            // However the vault locks or unlocks, vault-key terminals follow.
            cx.observe_global::<Vault>(|this, cx| this.vault_changed(cx)),
            cx.observe_global::<Profiles>(|_, cx| cx.notify()),
            cx.observe_global::<Projects>(|_, cx| cx.notify()),
            crate::track_appearance(window, cx),
        ];
        // Closing the window ends its terminals: ask first while any of them runs.
        let weak = cx.entity().downgrade();
        window.on_window_should_close(cx, move |window, cx| {
            weak.update(cx, |this, cx| this.should_close(window, cx))
                .unwrap_or(true)
        });
        let global = cx.global::<Projects>().is_global(project.id);
        let mut this = Self {
            project,
            global,
            presets: global.then(|| cx.new(PresetsPanel::new)),
            sidebar_open: cx.global::<Projects>().sidebar_open,
            panes: HashMap::new(),
            pane_subscriptions: HashMap::new(),
            exits: HashMap::new(),
            renaming: None,
            drop_target: None,
            ssh_retries: HashMap::new(),
            shown_titles: String::new(),
            _title_refresh: Task::ready(()),
            _title_poll: Task::ready(()),
            _subscriptions: subscriptions,
        };
        this._title_poll = cx.spawn_in(window, async move |this, cx| {
            loop {
                cx.background_executor().timer(TITLE_POLL).await;
                if this
                    .update_in(cx, |this, window, cx| this.update_window_title(window, cx))
                    .is_err()
                {
                    break;
                }
            }
        });

        // Only the item on screen starts; the others wait until they are opened.
        if this.project.active_view().is_none() {
            this.project.active = this.project.views.first().map(|view| view.id);
        }
        if let Some(view) = this.project.active {
            this.activate_view(view, window, cx);
        } else {
            this.update_window_title(window, cx);
        }
        if first_terminal {
            cx.defer_in(window, move |this, window, cx| {
                this.create_terminal(TerminalSpec::default(), Place::NewItem, window, cx);
            });
        }
        this
    }

    /// Whether the window may close now; with terminals running, ask first and close on "yes".
    fn should_close(&mut self, window: &mut Window, cx: &mut Context<Self>) -> bool {
        let running = self
            .project
            .panes()
            .into_iter()
            .filter(|pane| self.is_running(*pane, cx))
            .count();
        if running == 0 {
            self.save(cx);
            return true;
        }
        let weak = cx.entity().downgrade();
        let handle = window.window_handle();
        confirm(
            window,
            cx,
            format!("Close “{}”?", self.project.name),
            format!(
                "{running} terminal{} still running; closing the window stops {}.",
                if running == 1 { " is" } else { "s are" },
                if running == 1 { "it" } else { "them" }
            ),
            vec![Choice::danger("Stop and close", move |_, cx| {
                let _ = weak.update(cx, |this, cx| this.save(cx));
                let _ = handle.update(cx, |_, window, _| window.remove_window());
            })],
        );
        false
    }

    fn save(&mut self, cx: &mut App) {
        let project = self.project.clone();
        cx.update_global::<Projects, _>(|projects, _| {
            projects.put(project);
            if let Err(err) = projects.save() {
                eprintln!("failed to save projects: {err}");
            }
        });
    }

    /// A fresh id for a terminal, view or split.
    fn next_id(&self, cx: &mut App) -> Id {
        cx.update_global::<Projects, _>(|projects, _| projects.next_id())
    }

    // ----- terminals --------------------------------------------------------------------------

    /// Create a pane's terminal. Shells and SSH sessions start right away; tasks when they are
    /// set to start with their view.
    fn spawn_pane(&mut self, pane: Id, window: &mut Window, cx: &mut Context<Self>) -> bool {
        let Some((project, spec)) = self
            .project
            .terminal(pane)
            .map(|spec| (self.project.clone(), spec.clone()))
        else {
            return false;
        };
        let terminal = match TerminalView::create_terminal(cx) {
            Ok(terminal) => terminal,
            Err(err) => {
                eprintln!("failed to create terminal: {err:?}");
                return false;
            }
        };
        let dir = start_dir(&project, &spec);
        let launch = launch_for(&spec, &project, pane, &dir, cx);
        let start = match spec.kind {
            TerminalKind::Task { auto_start, .. } => auto_start,
            TerminalKind::Shell | TerminalKind::Ssh { .. } => true,
        };
        let view = cx.new(|cx| TerminalView::new(terminal, launch, Some(dir), start, window, cx));
        let subscription = cx.subscribe_in(&view, window, move |this, _, event, window, cx| {
            this.on_terminal_event(pane, event, window, cx)
        });
        self.panes.insert(pane, view);
        self.pane_subscriptions.insert(pane, subscription);
        true
    }

    /// Create the terminals of a view that do not exist yet.
    fn ensure_spawned(&mut self, view: Id, window: &mut Window, cx: &mut Context<Self>) {
        let panes = self.project.view(view).map(View::panes).unwrap_or_default();
        for pane in panes {
            if !self.panes.contains_key(&pane) {
                self.spawn_pane(pane, window, cx);
            }
        }
    }

    /// Drop a pane's terminal, which ends what it runs (and its Docker container, if any).
    fn forget_pane(&mut self, pane: Id, cx: &App) {
        self.stop_container(pane, cx);
        self.panes.remove(&pane);
        self.pane_subscriptions.remove(&pane);
        self.exits.remove(&pane);
        self.ssh_retries.remove(&pane);
    }

    fn stop_container(&self, pane: Id, cx: &App) {
        if let Some(spec) = self.project.terminal(pane)
            && let Isolation::Sandboxed { profile } = spec.effective_isolation()
            && matches!(
                Profiles::get(cx).sandbox_for(profile).engine,
                SandboxEngine::Docker { .. }
            )
            && self.panes.contains_key(&pane)
        {
            sandbox::stop_container(pane);
        }
    }

    fn is_running(&self, pane: Id, cx: &App) -> bool {
        self.panes
            .get(&pane)
            .is_some_and(|view| view.read(cx).is_running())
    }

    /// Running terminals of a view that are not marked to keep running in the background.
    fn stopping_on_leave(&self, view: Id, cx: &App) -> Vec<Id> {
        self.project
            .view(view)
            .map(|view| view.stopping_on_leave(|pane| self.is_running(pane, cx)))
            .unwrap_or_default()
    }

    fn running_count(&self, view: &View, cx: &App) -> usize {
        view.panes()
            .into_iter()
            .filter(|pane| self.is_running(*pane, cx))
            .count()
    }

    fn on_terminal_event(
        &mut self,
        pane: Id,
        event: &TerminalEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match event {
            TerminalEvent::TitleChanged => self.update_window_title(window, cx),
            // The command's process does not exist yet; look again once it has started.
            TerminalEvent::CommandStarted => {
                self._title_refresh = cx.spawn_in(window, async move |this, cx| {
                    cx.background_executor()
                        .timer(Duration::from_millis(150))
                        .await;
                    let _ =
                        this.update_in(cx, |this, window, cx| this.update_window_title(window, cx));
                });
            }
            TerminalEvent::PromptReady => self.update_window_title(window, cx),
            TerminalEvent::Focused => {
                if let Some(view) = self.project.view_of_pane(pane) {
                    if let Some(view) = self.project.view_mut(view) {
                        view.focused = Some(pane);
                    }
                    self.update_window_title(window, cx);
                }
            }
            TerminalEvent::Started => {
                self.exits.remove(&pane);
            }
            TerminalEvent::Exited { code, stopped } => {
                self.exits.insert(pane, *code);
                let kind = self.project.terminal(pane).map(|spec| spec.kind.clone());
                match kind {
                    // A task starts again if asked to, unless it was stopped by hand.
                    Some(TerminalKind::Task {
                        restart_on_exit: true,
                        ..
                    }) if !stopped => {
                        self.restart_after(pane, Duration::from_secs(1), window, cx);
                    }
                    // ssh exits with 255 when the connection fails or drops.
                    Some(TerminalKind::Ssh { host }) if *code == Some(255) && !stopped => {
                        self.ssh_dropped(pane, host, window, cx)
                    }
                    _ => {}
                }
            }
        }
        cx.notify();
    }

    /// An SSH terminal lost its connection: notify or reconnect as its host asks.
    fn ssh_dropped(&mut self, pane: Id, host: Id, window: &mut Window, cx: &mut Context<Self>) {
        let Some(host) = Profiles::get(cx).host(host).cloned() else {
            return;
        };
        match host.on_disconnect {
            OnDisconnect::Nothing => {}
            OnDisconnect::Notify => {
                let body = format!(
                    "{} — press Enter in its terminal to reconnect.",
                    host.address()
                );
                self.notify_disconnect(
                    format!("SSH connection to {} closed", host.name),
                    body,
                    window,
                    cx,
                );
            }
            OnDisconnect::Reconnect => {
                // A session that lasted a while starts the backoff over.
                let (attempts, started) = self
                    .ssh_retries
                    .get(&pane)
                    .copied()
                    .unwrap_or((0, Instant::now()));
                let attempts = if started.elapsed() > Duration::from_secs(60) {
                    0
                } else {
                    attempts
                };
                self.ssh_retries
                    .insert(pane, (attempts + 1, Instant::now()));
                self.restart_after(pane, ssh::forward::backoff(attempts), window, cx);
            }
        }
    }

    /// Tell the user a connection dropped: a system notification and a toast in the window.
    fn notify_disconnect(
        &self,
        title: String,
        body: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        cx.show_system_notification(SystemNotification {
            tag: SharedString::from(format!("disconnect-{title}")),
            title: title.clone().into(),
            body: body.clone().into(),
            actions: Vec::new(),
        });
        window.push_notification(Notification::warning(body).title(title), cx);
    }

    fn restart_after(
        &mut self,
        pane: Id,
        delay: Duration,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        cx.spawn_in(window, async move |this, cx| {
            cx.background_executor().timer(delay).await;
            let _ = this.update(cx, |this, cx| {
                if let Some(view) = this.panes.get(&pane) {
                    view.update(cx, |view, cx| view.start_if_stopped(cx));
                }
            });
        })
        .detach();
    }

    fn focus_pane(&self, pane: Id, window: &mut Window, cx: &mut App) {
        if let Some(view) = self.panes.get(&pane) {
            view.focus_handle(cx).focus(window, cx);
        }
    }

    fn focused_pane(&self) -> Option<Id> {
        self.project.active_view().and_then(|view| view.focused)
    }

    /// Add a terminal: as a new item of its project, or beside the focused terminal of the item on
    /// screen (which makes that item a view).
    fn add_terminal(
        &mut self,
        spec: TerminalSpec,
        place: Place,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let pane = self.next_id(cx);
        match place {
            Place::NewItem => {
                let view = self.next_id(cx);
                self.project.add_view(view, pane, spec);
                self.save(cx);
                self.request_view(view, window, cx);
                return;
            }
            Place::Beside(view_id, axis) => {
                // A terminal becoming a view: the view starts out named after it.
                let first = self
                    .project
                    .view(view_id)
                    .and_then(View::single)
                    .map(|pane| self.pane_label(pane, cx));
                let split = self.next_id(cx);
                let Some(view) = self.project.view_mut(view_id) else {
                    return;
                };
                if let Some(first) = first.filter(|_| view.name.trim().is_empty()) {
                    view.name = first;
                }
                view.add(pane, split, axis, None, spec);
            }
        }
        if self.spawn_pane(pane, window, cx) {
            self.focus_pane(pane, window, cx);
        }
        self.save(cx);
        self.update_window_title(window, cx);
        cx.notify();
    }

    /// Create a terminal: the dialog asks what it is (starting from `preset`), then it is added
    /// where `place` says.
    fn create_terminal(
        &mut self,
        preset: TerminalSpec,
        place: Place,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let root = self.project.root();
        let weak = cx.entity().downgrade();
        terminal_dialog::open(
            false,
            self.global,
            root,
            preset,
            window,
            cx,
            move |spec, window, cx| {
                update(&weak, window, cx, |this, window, cx| {
                    this.add_created(spec, place, window, cx)
                });
            },
        );
    }

    /// A new item of the project on screen, starting from `preset`.
    fn new_item(&mut self, preset: TerminalSpec, window: &mut Window, cx: &mut Context<Self>) {
        self.create_terminal(preset, Place::NewItem, window, cx);
    }

    /// Add a terminal made in the dialog; an SSH host signing in with a vault key needs the vault
    /// unlocked first.
    fn add_created(
        &mut self,
        spec: TerminalSpec,
        place: Place,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let needs_vault = match spec.kind {
            TerminalKind::Ssh { host } => Profiles::get(cx)
                .host(host)
                .is_some_and(|host| matches!(host.auth, SshAuth::Vault { .. })),
            _ => false,
        };
        if needs_vault && !Vault::is_unlocked(cx) {
            let weak = cx.entity().downgrade();
            vault::unlock_dialog::open(window, cx, move |window, cx| {
                let spec = spec.clone();
                update(&weak, window, cx, |this, window, cx| {
                    this.add_terminal(spec, place, window, cx)
                });
            });
            return;
        }
        self.add_terminal(spec, place, window, cx);
    }

    /// The folder and isolation of the focused terminal, for one made next to it.
    fn preset_near_focus(&self) -> TerminalSpec {
        self.focused_pane()
            .and_then(|pane| self.project.terminal(pane))
            .map_or_else(TerminalSpec::default, TerminalSpec::for_split)
    }

    /// Split the focused terminal: a new one beside it, in its folder and as isolated. Without an
    /// item on screen it becomes a new item.
    fn split(&mut self, axis: SplitAxis, window: &mut Window, cx: &mut Context<Self>) {
        let preset = self.preset_near_focus();
        match self.project.active {
            Some(view) => self.create_terminal(preset, Place::Beside(view, axis), window, cx),
            None => self.new_item(preset, window, cx),
        }
    }

    fn new_shell(&mut self, isolation: Isolation, window: &mut Window, cx: &mut Context<Self>) {
        let preset = TerminalSpec {
            isolation,
            ..TerminalSpec::default()
        };
        self.new_item(preset, window, cx);
    }

    fn new_task(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let preset = TerminalSpec {
            kind: task_kind(),
            ..TerminalSpec::default()
        };
        self.new_item(preset, window, cx);
    }

    /// Edit a terminal; it starts over with its new settings (and runs if it was running).
    fn edit_terminal(&mut self, pane: Id, window: &mut Window, cx: &mut Context<Self>) {
        let Some((project, spec)) = self
            .project
            .terminal(pane)
            .map(|spec| (self.project.clone(), spec.clone()))
        else {
            return;
        };
        let weak = cx.entity().downgrade();
        terminal_dialog::open(
            true,
            self.global,
            project.root(),
            spec,
            window,
            cx,
            move |spec, window, cx| {
                update(&weak, window, cx, |this, window, cx| {
                    this.replace_terminal(pane, spec, window, cx)
                });
            },
        );
    }

    fn replace_terminal(
        &mut self,
        pane: Id,
        spec: TerminalSpec,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let was_running = self.is_running(pane, cx);
        let only_details = self.project.terminal(pane).is_some_and(|old| {
            (&old.kind, &old.folder, &old.isolation) == (&spec.kind, &spec.folder, &spec.isolation)
        });
        if let Some(terminal) = self.project.terminal_mut(pane) {
            *terminal = spec;
        }
        // A new name, tag or background mark needs no restart.
        if !only_details && self.panes.contains_key(&pane) {
            self.forget_pane(pane, cx);
            self.spawn_pane(pane, window, cx);
            if was_running && let Some(view) = self.panes.get(&pane) {
                view.update(cx, |view, cx| view.start_if_stopped(cx));
            }
        }
        self.save(cx);
        cx.notify();
    }

    fn toggle_background(&mut self, pane: Id, cx: &mut Context<Self>) {
        if let Some(terminal) = self.project.terminal_mut(pane) {
            terminal.background = !terminal.background;
        }
        self.save(cx);
        cx.notify();
    }

    /// Close a terminal of a view, asking first while it runs. An item's only terminal is not
    /// closed: deleting it deletes the item.
    fn request_close(&mut self, pane: Id, window: &mut Window, cx: &mut Context<Self>) {
        let only = self
            .project
            .view_of_pane(pane)
            .and_then(|view| self.project.view(view))
            .is_some_and(|view| view.single().is_some());
        if only {
            return;
        }
        if !self.is_running(pane, cx) {
            self.close_pane(pane, window, cx);
            return;
        }
        let name = self.pane_label(pane, cx);
        let weak = cx.entity().downgrade();
        confirm(
            window,
            cx,
            format!("Stop and close “{name}”?"),
            "It is still running; closing stops it.".into(),
            vec![Choice::danger("Stop and close", move |window, cx| {
                update(&weak, window, cx, |this, window, cx| {
                    this.close_pane(pane, window, cx)
                });
            })],
        );
    }

    fn close_pane(&mut self, pane: Id, window: &mut Window, cx: &mut Context<Self>) {
        let Some(view_id) = self.project.view_of_pane(pane) else {
            return;
        };
        self.forget_pane(pane, cx);
        if let Some(view) = self.project.view_mut(view_id) {
            view.remove(pane);
        }
        if self.project.active == Some(view_id)
            && let Some(focus) = self.focused_pane()
        {
            self.focus_pane(focus, window, cx);
        }
        self.save(cx);
        self.update_window_title(window, cx);
        cx.notify();
    }

    fn cycle_pane(&mut self, offset: isize, window: &mut Window, cx: &mut Context<Self>) {
        let Some(view) = self.project.active_view() else {
            return;
        };
        let panes = view.panes();
        if panes.is_empty() {
            return;
        }
        let current = view
            .focused
            .and_then(|focused| panes.iter().position(|pane| *pane == focused))
            .unwrap_or(0) as isize;
        let next = panes[(current + offset).rem_euclid(panes.len() as isize) as usize];
        self.focus_pane(next, window, cx);
    }

    /// Drop the dragged pane on `target`: beside it on `side`, or (`None`) in its place, with
    /// `target` taking the dragged pane's old place.
    fn drop_pane(
        &mut self,
        dragged: Id,
        target: Id,
        side: Option<Side>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.drop_target = None;
        let Some(side) = side else {
            self.swap_panes(dragged, target, window, cx);
            return;
        };
        let Some(view) = self.project.view_of_pane(target) else {
            return;
        };
        let split = self.next_id(cx);
        let moved = self
            .project
            .view_mut(view)
            .and_then(|view| view.layout.as_mut())
            .is_some_and(|layout| layout.move_to(dragged, target, side, split));
        if moved {
            self.focus_pane(dragged, window, cx);
            self.save(cx);
        }
        cx.notify();
    }

    /// Put the dragged pane where `target` is and `target` where it was.
    fn swap_panes(&mut self, dragged: Id, target: Id, window: &mut Window, cx: &mut Context<Self>) {
        let Some(view) = self.project.view_of_pane(target) else {
            return;
        };
        let swapped = self
            .project
            .view_mut(view)
            .and_then(|view| view.layout.as_mut())
            .is_some_and(|layout| layout.swap(dragged, target));
        if swapped {
            self.focus_pane(dragged, window, cx);
            self.save(cx);
            cx.notify();
        }
    }

    fn start_pane(&mut self, pane: Id, cx: &mut Context<Self>) {
        if let Some(view) = self.panes.get(&pane) {
            view.update(cx, |view, cx| view.start_if_stopped(cx));
        }
    }

    fn stop_pane(&mut self, pane: Id, cx: &mut Context<Self>) {
        if let Some(view) = self.panes.get(&pane) {
            view.update(cx, |view, cx| view.stop(cx));
        }
    }

    fn restart_pane(&mut self, pane: Id, cx: &mut Context<Self>) {
        if let Some(view) = self.panes.get(&pane) {
            view.update(cx, |view, cx| view.restart(cx));
        }
    }

    // ----- views and projects -----------------------------------------------------------------

    /// Show `view`; leaving the current one stops its terminals that are not marked to keep
    /// running in the background, after asking.
    fn request_view(&mut self, target: Id, window: &mut Window, cx: &mut Context<Self>) {
        let Some(current) = self.project.active.filter(|current| *current != target) else {
            self.activate_view(target, window, cx);
            return;
        };
        let stopping = self.stopping_on_leave(current, cx);
        if stopping.is_empty() {
            self.leave_view(current, cx);
            self.activate_view(target, window, cx);
            return;
        }
        let names: Vec<String> = stopping
            .iter()
            .map(|pane| self.pane_label(*pane, cx))
            .collect();
        let (stop, keep) = (cx.entity().downgrade(), cx.entity().downgrade());
        let marked = stopping.clone();
        confirm(
            window,
            cx,
            format!(
                "Stop {} running terminal{}?",
                stopping.len(),
                if stopping.len() == 1 { "" } else { "s" }
            ),
            format!("{} — not set to keep alive.", names.join(", ")),
            vec![
                Choice::plain("Keep alive", move |window, cx| {
                    update(&keep, window, cx, |this, window, cx| {
                        for pane in &marked {
                            if let Some(terminal) = this.project.terminal_mut(*pane) {
                                terminal.background = true;
                            }
                        }
                        this.activate_view(target, window, cx);
                    });
                }),
                Choice::danger("Stop and switch", move |window, cx| {
                    update(&stop, window, cx, |this, window, cx| {
                        this.leave_view(current, cx);
                        this.activate_view(target, window, cx);
                    });
                }),
            ],
        );
    }

    /// Drop a view's terminals, except those marked to keep running in the background.
    fn leave_view(&mut self, view: Id, cx: &App) {
        let Some(view) = self.project.view(view).cloned() else {
            return;
        };
        for pane in view.panes() {
            if view.terminal(pane).is_some_and(|spec| !spec.background) {
                self.forget_pane(pane, cx);
            }
        }
    }

    fn activate_view(&mut self, view: Id, window: &mut Window, cx: &mut Context<Self>) {
        if self.project.view(view).is_none() {
            return;
        }
        self.project.active = Some(view);
        self.ensure_spawned(view, window, cx);
        if let Some(focus) = self.focused_pane() {
            self.focus_pane(focus, window, cx);
        }
        self.save(cx);
        self.update_window_title(window, cx);
        cx.notify();
    }

    fn select_nth_view(&mut self, index: usize, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(view) = self.project.views.get(index).map(|view| view.id) {
            self.request_view(view, window, cx);
        }
    }

    fn edit_project(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let form = ProjectForm {
            name: self.project.name.clone(),
            icon: self.project.icon.clone(),
            color: self.project.color.clone(),
            dir: self.project.dir.clone(),
        };
        let weak = cx.entity().downgrade();
        project_dialog::open(form, window, cx, move |form, window, cx| {
            update(&weak, window, cx, |this, window, cx| {
                this.project.name = form.name;
                this.project.dir = form.dir;
                this.project.icon = form.icon;
                this.project.color = form.color;
                this.save(cx);
                this.update_window_title(window, cx);
                cx.notify();
            });
        });
    }

    /// Remove the project from the app (its folder is untouched) and close its window, asking
    /// first.
    fn request_remove_project(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let running = self
            .project
            .panes()
            .into_iter()
            .filter(|pane| self.is_running(*pane, cx))
            .count();
        let weak = cx.entity().downgrade();
        let description = if running > 0 {
            format!(
                "{running} terminal(s) in it are running and will stop. The folder itself is not touched."
            )
        } else {
            "Its terminals go; the folder itself is not touched.".to_owned()
        };
        confirm(
            window,
            cx,
            format!("Remove “{}”?", self.project.name),
            description,
            vec![Choice::danger("Remove project", move |window, cx| {
                update(&weak, window, cx, |this, window, cx| {
                    this.remove_project(window, cx)
                });
            })],
        );
    }

    fn remove_project(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        for pane in self.project.panes() {
            self.forget_pane(pane, cx);
        }
        let id = self.project.id;
        cx.update_global::<Projects, _>(|projects, _| {
            projects.remove_project(id);
            if let Err(err) = projects.save() {
                eprintln!("failed to save projects: {err}");
            }
        });
        window.remove_window();
    }

    /// Delete an item (a terminal, or a view and its terminals), asking first.
    fn request_delete_view(&mut self, view: Id, window: &mut Window, cx: &mut Context<Self>) {
        let Some(found) = self.project.view(view) else {
            return;
        };
        let (name, running) = (self.item_name(found, cx), self.running_count(found, cx));
        let single = found.single().is_some();
        let weak = cx.entity().downgrade();
        let description = match (single, running > 0) {
            (true, true) => "It is still running; deleting stops it.".to_owned(),
            (true, false) => "It is removed from the project.".to_owned(),
            (false, true) => format!("{running} terminal(s) in it are running and will stop."),
            (false, false) => "Its terminals go with it.".to_owned(),
        };
        let (title, label) = if single {
            (format!("Delete terminal “{name}”?"), "Delete terminal")
        } else {
            (format!("Delete view “{name}”?"), "Delete view")
        };
        confirm(
            window,
            cx,
            title,
            description,
            vec![Choice::danger(label, move |window, cx| {
                update(&weak, window, cx, |this, window, cx| {
                    this.delete_view(view, window, cx)
                });
            })],
        );
    }

    fn delete_view(&mut self, view: Id, window: &mut Window, cx: &mut Context<Self>) {
        for pane in self.project.view(view).map(View::panes).unwrap_or_default() {
            self.forget_pane(pane, cx);
        }
        self.project.remove_view(view);
        if let Some(view) = self.project.active {
            self.activate_view(view, window, cx);
        }
        self.save(cx);
        self.update_window_title(window, cx);
        cx.notify();
    }

    /// The vault locked or unlocked: vault-key SSH terminals get their new launch (taking effect
    /// on Enter).
    fn vault_changed(&mut self, cx: &mut Context<Self>) {
        let vault_hosts: Vec<Id> = Profiles::get(cx)
            .hosts
            .iter()
            .filter(|host| matches!(host.auth, SshAuth::Vault { .. }))
            .map(|host| host.id)
            .collect();
        let panes: Vec<Id> = self
            .panes
            .keys()
            .copied()
            .filter(|pane| {
                self.project.terminal(*pane).is_some_and(|spec| matches!(spec.kind, TerminalKind::Ssh { host } if vault_hosts.contains(&host)))
            })
            .collect();
        for pane in panes {
            let Some((project, spec)) = self
                .project
                .terminal(pane)
                .map(|spec| (self.project.clone(), spec.clone()))
            else {
                continue;
            };
            let launch = launch_for(&spec, &project, pane, &start_dir(&project, &spec), cx);
            if let Some(view) = self.panes.get(&pane) {
                view.update(cx, |view, _| view.set_launch(launch));
            }
        }
        cx.notify();
    }

    // ----- renaming ---------------------------------------------------------------------------

    fn start_rename(&mut self, target: RenameTarget, window: &mut Window, cx: &mut Context<Self>) {
        let current = match target {
            RenameTarget::Project => Some(self.project.name.clone()),
            RenameTarget::View(id) => self.project.view(id).map(|view| view.name.clone()),
            RenameTarget::Terminal(pane) => Some(self.pane_label(pane, cx)),
        }
        .unwrap_or_default();
        let input = cx.new(|cx| InputState::new(window, cx).default_value(current));
        let subscription =
            cx.subscribe_in(&input, window, |this, _, event: &InputEvent, window, cx| {
                if matches!(event, InputEvent::PressEnter { .. } | InputEvent::Blur) {
                    this.finish_rename(window, cx);
                }
            });
        input.update(cx, |input, cx| input.focus(window, cx));
        self.renaming = Some(Renaming {
            target,
            input,
            _subscription: subscription,
        });
        cx.notify();
    }

    fn is_renaming(&self, target: RenameTarget) -> bool {
        self.renaming
            .as_ref()
            .is_some_and(|renaming| renaming.target == target)
    }

    fn finish_rename(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(renaming) = self.renaming.take() else {
            return;
        };
        let name = renaming.input.read(cx).value().trim().to_owned();
        match renaming.target {
            RenameTarget::Project => {
                if !name.is_empty() {
                    self.project.name = name;
                }
            }
            RenameTarget::View(id) => {
                if let Some(view) = self.project.view_mut(id).filter(|_| !name.is_empty()) {
                    view.name = name;
                }
            }
            // An empty name goes back to naming it after what it runs.
            RenameTarget::Terminal(pane) => {
                if let Some(terminal) = self.project.terminal_mut(pane) {
                    terminal.name = name;
                }
            }
        }
        self.save(cx);
        if let Some(pane) = self.focused_pane() {
            self.focus_pane(pane, window, cx);
        }
        self.update_window_title(window, cx);
        cx.notify();
    }

    /// The name as text, or an inline editor while it is being renamed.
    fn name_or_editor(
        &self,
        target: RenameTarget,
        name: SharedString,
        label: gpui::Div,
    ) -> AnyElement {
        match &self.renaming {
            Some(renaming) if renaming.target == target => {
                Input::new(&renaming.input).small().into_any_element()
            }
            _ => label.child(name).into_any_element(),
        }
    }

    // ----- naming -----------------------------------------------------------------------------

    /// What an item is called: its terminal's name, or the view's.
    fn item_name(&self, view: &View, cx: &App) -> String {
        match view.single() {
            Some(pane) => self.pane_label(pane, cx),
            None if view.name.trim().is_empty() => "View".to_owned(),
            None => view.name.clone(),
        }
    }

    /// Title set by the pane's program (empty when none).
    fn program_title(&self, pane: Id, cx: &App) -> Option<SharedString> {
        self.panes
            .get(&pane)
            .map(|view| view.read(cx).title().clone())
            .filter(|title| !title.is_empty())
    }

    /// What a terminal is called: its name, else what it runs (the task's command, the SSH host,
    /// or the program's own title, or the folder and foreground process).
    fn pane_label(&self, pane: Id, cx: &App) -> String {
        let project = &self.project;
        let Some(spec) = project.terminal(pane) else {
            return String::new();
        };
        if !spec.name.trim().is_empty() {
            return spec.name.clone();
        }
        match &spec.kind {
            TerminalKind::Task { command, .. } => return command.clone(),
            TerminalKind::Ssh { host } => {
                return Profiles::get(cx)
                    .host(*host)
                    .map_or_else(|| "ssh".to_owned(), |host| host.name.clone());
            }
            TerminalKind::Shell => {}
        }
        if let Some(title) = self.program_title(pane, cx) {
            return title.to_string();
        }
        let dir = self
            .panes
            .get(&pane)
            .and_then(|view| view.read(cx).cwd().map(str::to_owned))
            .unwrap_or_else(|| start_dir(project, spec).to_string_lossy().into_owned());
        let process = self
            .panes
            .get(&pane)
            .and_then(|view| view.read(cx).process_name());
        match process {
            Some(process) => format!("{} — {process}", folder_name(&dir)),
            None => folder_name(&dir),
        }
    }

    /// Bring the window title, title bar and pane headers up to date with what the panes run.
    fn update_window_title(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        // Just the project: the menu bar already names the app.
        let title = self.project.name.clone();
        let mut shown = title.clone();
        for pane in self
            .project
            .active_view()
            .map(View::panes)
            .unwrap_or_default()
        {
            shown.push('\n');
            shown.push_str(&self.pane_label(pane, cx));
        }
        if shown != self.shown_titles {
            window.set_window_title(&title);
            self.shown_titles = shown;
            cx.notify();
        }
    }

    // ----- rendering --------------------------------------------------------------------------

    fn render_title_bar(&self, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let root = self.project.root();
        // An item that is one terminal has no header: its controls are here.
        let single = self
            .project
            .active_view()
            .and_then(View::single)
            .map(|pane| {
                let muted = cx.theme().muted_foreground;
                h_flex()
                    .gap_0p5()
                    .child(self.terminal_controls(pane, cx))
                    .child(
                        icon_button(
                            ("title-edit-terminal", pane),
                            IconName::Pencil,
                            "Edit terminal",
                        )
                        .on_click(cx.listener(
                            move |this, _, window, cx| this.edit_terminal(pane, window, cx),
                        )),
                    )
                    .child(div().mx_1().h(px(14.)).w(px(1.)).bg(muted.opacity(0.3)))
            });
        let muted = cx.theme().muted_foreground;
        // The window paints the chrome once behind both the title bar and the sidebar (stacked
        // see-through layers would differ); gpui-component's gradient and bottom edge go.
        TitleBar::new()
            .bg(gpui::transparent_black())
            .border_color(gpui::transparent_black())
            .child(
                h_flex()
                    .w_full()
                    .pr_2()
                    .gap_2()
                    .justify_between()
                    .child(
                        h_flex()
                            .gap_1()
                            .min_w_0()
                            .child(
                                title_buttons("title-sidebar-button").child(
                                    icon_button(
                                        "toggle-sidebar",
                                        if self.sidebar_open {
                                            IconName::PanelLeftClose
                                        } else {
                                            IconName::PanelLeftOpen
                                        },
                                        "Toggle sidebar (⌘B)",
                                    )
                                    .on_click(
                                        cx.listener(|this, _, _, cx| this.toggle_sidebar(cx)),
                                    ),
                                ),
                            )
                            .child(
                                h_flex()
                                    .pl_1()
                                    .min_w_0()
                                    .gap_1p5()
                                    .text_sm()
                                    .child(
                                        div()
                                            .min_w_0()
                                            .truncate()
                                            .font_weight(FontWeight::MEDIUM)
                                            .child(self.project.name.clone()),
                                    ),
                            ),
                    )
                    .child(
                        title_buttons("title-actions")
                            .gap_0p5()
                            .children(single)
                            .child(
                                icon_button(
                                    "title-new-terminal",
                                    IconName::Plus,
                                    "New terminal (⌘T)",
                                )
                                .on_click(cx.listener(
                                    |this, _, window, cx| {
                                        this.new_shell(Isolation::default(), window, cx)
                                    },
                                )),
                            )
                            .child(
                                icon_button(
                                    "title-split-right",
                                    IconName::Columns2,
                                    "Split right (⌘D)",
                                )
                                .on_click(cx.listener(
                                    |this, _, window, cx| {
                                        this.split(SplitAxis::Horizontal, window, cx)
                                    },
                                )),
                            )
                            .child(
                                icon_button(
                                    "title-split-down",
                                    IconName::Rows2,
                                    "Split down (⌘⇧D)",
                                )
                                .on_click(cx.listener(
                                    |this, _, window, cx| {
                                        this.split(SplitAxis::Vertical, window, cx)
                                    },
                                )),
                            )
                            // A project's own: its folder in Zed, and the way to the Global window.
                            .when(!self.global, |actions| {
                                actions
                                    .child(
                                        icon_button("open-in-zed", IconName::Code, "Open the project in Zed")
                                            .on_click(move |_, _, _| open_in_zed(&root)),
                                    )
                                    .child(div().mx_1().h(px(14.)).w(px(1.)).bg(muted.opacity(0.3)))
                                    .child(
                                        icon_button(
                                            "open-global",
                                            IconName::Globe,
                                            "Global: terminals, SSH hosts, port forwards, sandboxes (⌘⇧G)",
                                        )
                                        .on_click(|_, _, cx| app::open_global(cx)),
                                    )
                            })
                            .child(
                                icon_button(
                                    "open-history",
                                    IconName::Clock,
                                    "Command history (⌃R)",
                                )
                                .on_click(|_, window, cx| history_panel::open(window, cx)),
                            )
                            .child(
                                icon_button("open-settings", IconName::Settings, "Settings (⌘,)")
                                    .on_click(|_, window, cx| settings_panel::open(window, cx)),
                            ),
                    ),
            )
    }

    /// Start, or for a running task stop and restart.
    fn terminal_controls(&self, pane: Id, cx: &mut Context<Self>) -> AnyElement {
        let running = self.is_running(pane, cx);
        let is_task = self
            .project
            .terminal(pane)
            .is_some_and(|spec| matches!(spec.kind, TerminalKind::Task { .. }));
        let mut controls = h_flex().flex_none().gap_0p5();
        if !running {
            controls = controls.child(
                icon_button(("start", pane), IconName::Play, "Start")
                    .xsmall()
                    .on_click(cx.listener(move |this, _, _, cx| {
                        cx.stop_propagation();
                        this.start_pane(pane, cx);
                    })),
            );
        } else if is_task {
            controls = controls
                .child(
                    icon_button(("restart", pane), IconName::RotateCw, "Restart")
                        .xsmall()
                        .on_click(cx.listener(move |this, _, _, cx| {
                            cx.stop_propagation();
                            this.restart_pane(pane, cx);
                        })),
                )
                .child(
                    icon_button(("stop", pane), IconName::Square, "Stop")
                        .xsmall()
                        .on_click(cx.listener(move |this, _, _, cx| {
                            cx.stop_propagation();
                            this.stop_pane(pane, cx);
                        })),
                );
        }
        controls.into_any_element()
    }

    fn toggle_sidebar(&mut self, cx: &mut Context<Self>) {
        self.sidebar_open = !self.sidebar_open;
        // New windows open the way the last one was left.
        let open = self.sidebar_open;
        cx.update_global::<Projects, _>(|projects, _| projects.sidebar_open = open);
        self.save(cx);
        cx.notify();
    }

    /// The project (its tile and name), its terminals and views, and a button for a new terminal.
    /// In the Global window: its terminals, then SSH hosts and sandboxes.
    fn render_sidebar(&self, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let header = (!self.global).then(|| self.render_project_header(cx));
        let items: Vec<AnyElement> = self
            .project
            .views
            .iter()
            .map(|view| self.render_view_row(view, cx))
            .collect();
        let theme = cx.theme();
        let (hover, muted) = (theme.sidebar_accent.opacity(0.6), theme.muted_foreground);
        let terminals_heading = self.global.then(|| {
            div()
                .h(px(28.))
                .pl_2()
                .flex()
                .items_center()
                .text_xs()
                .font_weight(FontWeight::MEDIUM)
                .text_color(muted)
                .child("TERMINALS")
        });
        let empty = (self.global && items.is_empty()).then(|| {
            div()
                .px_2()
                .pb_1()
                .text_xs()
                .text_color(muted)
                .child("Shells and SSH sessions outside any project.")
        });
        v_flex()
            .w(px(SIDEBAR_WIDTH))
            .h_full()
            .flex_none()
            .text_color(theme.sidebar_foreground)
            .children(header.map(|header| div().flex_none().px_2().pt_1().pb_1().child(header)))
            .child(
                v_flex()
                    .id("sidebar-body")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .px_2()
                    .pb_2()
                    .child(
                        v_flex()
                            .gap_0p5()
                            .children(terminals_heading)
                            .children(items)
                            .children(empty),
                    )
                    .children(
                        self.presets
                            .clone()
                            .map(|presets| div().pt_4().child(presets)),
                    ),
            )
            .child(
                h_flex()
                    .id("new-terminal")
                    .flex_none()
                    .mx_2()
                    .mb_2()
                    .h(px(30.))
                    .px_2()
                    .gap_2()
                    .rounded_md()
                    .cursor_pointer()
                    .text_sm()
                    .text_color(muted)
                    .hover(move |style| style.bg(hover))
                    .tooltip(|window, cx| Tooltip::new("New terminal (⌘T)").build(window, cx))
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.new_shell(Isolation::default(), window, cx)
                    }))
                    .child(Icon::new(IconName::Plus).small())
                    .child("New terminal"),
            )
    }

    /// The project: its tile, name (double-click to rename) and folder; right-click for more.
    fn render_project_header(&self, cx: &mut Context<Self>) -> AnyElement {
        let project = &self.project;
        let color = project
            .color
            .as_deref()
            .and_then(|id| crate::theme::group_color(id, cx));
        let tile = project_dialog::group_tile(project.icon.as_deref(), color, px(20.), cx);
        let theme = cx.theme();
        let weak = cx.entity().downgrade();
        let dir = SharedString::from(project.root().to_string_lossy().into_owned());
        let root = project.root();
        let (foreground, hover) = (theme.sidebar_foreground, theme.sidebar_accent.opacity(0.6));
        h_flex()
            .id("project-header")
            .h(px(32.))
            .px_1p5()
            .gap_2()
            .rounded_md()
            .cursor_pointer()
            .hover(move |style| style.bg(hover))
            .tooltip(move |window, cx| Tooltip::new(dir.clone()).build(window, cx))
            .on_click(cx.listener(move |this, event: &ClickEvent, window, cx| {
                if event.click_count() >= 2 && !this.is_renaming(RenameTarget::Project) {
                    this.start_rename(RenameTarget::Project, window, cx);
                }
            }))
            .child(tile)
            .child(
                div().flex_1().min_w_0().child(
                    self.name_or_editor(
                        RenameTarget::Project,
                        project.name.clone().into(),
                        div()
                            .text_sm()
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(foreground)
                            .truncate(),
                    ),
                ),
            )
            .context_menu(move |menu, _, _| {
                let (zed, finder) = (root.clone(), root.clone());
                let (edit, remove) = (weak.clone(), weak.clone());
                menu.item(
                    PopupMenuItem::new("Open in Zed")
                        .icon(IconName::Code)
                        .on_click(move |_, _, _| open_in_zed(&zed)),
                )
                .item(
                    PopupMenuItem::new("Reveal in Finder")
                        .icon(IconName::FolderOpen)
                        .on_click(move |_, _, _| {
                            let _ = Command::new("open").arg(&finder).spawn();
                        }),
                )
                .separator()
                .item(
                    PopupMenuItem::new("Edit project")
                        .icon(IconName::Pencil)
                        .on_click(move |_, window, cx| {
                            update(&edit, window, cx, |this, window, cx| {
                                this.edit_project(window, cx)
                            });
                        }),
                )
                .separator()
                .item(
                    PopupMenuItem::new("Remove project")
                        .icon(IconName::Trash)
                        .on_click(move |_, window, cx| {
                            update(&remove, window, cx, |this, window, cx| {
                                this.request_remove_project(window, cx)
                            });
                        }),
                )
            })
            .into_any_element()
    }

    /// An item: one terminal (its kind, name and whether it runs), or a view of several (its name
    /// and how many run).
    fn render_view_row(&self, view: &View, cx: &mut Context<Self>) -> AnyElement {
        let theme = cx.theme();
        let id = view.id;
        let single = view.single();
        let active = self.project.active == Some(id);
        let running = self.running_count(view, cx);
        let total = view.panes().len();
        let weak = cx.entity().downgrade();
        let hover = theme.sidebar_accent.opacity(0.6);
        let (text, icon_color) = if active {
            (
                theme.sidebar_accent_foreground,
                theme.sidebar_accent_foreground,
            )
        } else {
            (
                theme.sidebar_foreground.opacity(0.85),
                theme.muted_foreground,
            )
        };
        let (muted, success, warning) = (theme.muted_foreground, theme.success, theme.warning);
        let spec = single.and_then(|pane| view.terminal(pane)).cloned();
        let open = spec
            .as_ref()
            .is_some_and(|spec| spec.effective_isolation() == Isolation::Open);
        let icon = match spec.as_ref().map(|spec| &spec.kind) {
            None => IconName::LayoutGrid,
            Some(TerminalKind::Shell) => IconName::SquareTerminal,
            Some(TerminalKind::Task { .. }) => IconName::Play,
            Some(TerminalKind::Ssh { .. }) => IconName::Server,
        };
        let tooltip: SharedString = match &spec {
            Some(spec) => {
                let state = if running > 0 {
                    "running"
                } else {
                    "not running"
                };
                let isolation = if open { "open" } else { "sandboxed" };
                let background = if spec.background { ", kept alive" } else { "" };
                format!("{state}, {isolation}{background}").into()
            }
            None => format!("View of {total} terminals, {running} running").into(),
        };
        let rename = match single {
            Some(pane) => RenameTarget::Terminal(pane),
            None => RenameTarget::View(id),
        };
        let name: SharedString = self.item_name(view, cx).into();
        h_flex()
            .id(("view", id))
            .h(px(28.))
            .ml(px(4.))
            .pl_2()
            .pr_2()
            .gap_2()
            .rounded_md()
            .cursor_pointer()
            .text_sm()
            .text_color(text)
            .when(active, |row| {
                row.bg(theme.sidebar_accent).font_weight(FontWeight::MEDIUM)
            })
            .when(!active, |row| row.hover(move |style| style.bg(hover)))
            .tooltip(move |window, cx| Tooltip::new(tooltip.clone()).build(window, cx))
            .on_click(cx.listener(move |this, event: &ClickEvent, window, cx| {
                if this.is_renaming(rename) {
                    return;
                }
                if event.click_count() >= 2 {
                    this.start_rename(rename, window, cx);
                } else {
                    this.request_view(id, window, cx);
                }
            }))
            // Open terminals are amber here too.
            .child(
                Icon::new(icon)
                    .small()
                    .text_color(if open { warning } else { icon_color }),
            )
            .child(div().flex_1().min_w_0().child(self.name_or_editor(
                rename,
                name,
                div().truncate(),
            )))
            .when(running > 0, |row| {
                row.child(
                    h_flex()
                        .flex_none()
                        .gap_1()
                        .text_xs()
                        .text_color(muted)
                        .child(div().size(px(6.)).rounded_full().bg(success))
                        .when(single.is_none(), |count| count.child(running.to_string())),
                )
            })
            .context_menu(move |menu, _, _| {
                let (rename_item, delete) = (weak.clone(), weak.clone());
                let menu = match (single, &spec) {
                    (Some(pane), Some(spec)) => {
                        let (edit, background) = (weak.clone(), weak.clone());
                        menu.item(
                            PopupMenuItem::new("Edit terminal")
                                .icon(IconName::Pencil)
                                .on_click(move |_, window, cx| {
                                    update(&edit, window, cx, |this, window, cx| {
                                        this.edit_terminal(pane, window, cx)
                                    });
                                }),
                        )
                        .item(
                            PopupMenuItem::new("Rename")
                                .icon(IconName::TextCursorInput)
                                .on_click(move |_, window, cx| {
                                    update(&rename_item, window, cx, |this, window, cx| {
                                        this.start_rename(rename, window, cx)
                                    });
                                }),
                        )
                        .item(
                            PopupMenuItem::new("Keep alive")
                                .checked(spec.background)
                                .on_click(move |_, window, cx| {
                                    update(&background, window, cx, |this, _, cx| {
                                        this.toggle_background(pane, cx)
                                    });
                                }),
                        )
                    }
                    _ => menu.item(
                        PopupMenuItem::new("Rename")
                            .icon(IconName::TextCursorInput)
                            .on_click(move |_, window, cx| {
                                update(&rename_item, window, cx, |this, window, cx| {
                                    this.start_rename(rename, window, cx)
                                });
                            }),
                    ),
                };
                menu.separator().item(
                    PopupMenuItem::new(if single.is_some() {
                        "Delete terminal"
                    } else {
                        "Delete view"
                    })
                    .icon(IconName::Trash)
                    .on_click(move |_, window, cx| {
                        update(&delete, window, cx, |this, window, cx| {
                            this.request_delete_view(id, window, cx)
                        });
                    }),
                )
            })
            .into_any_element()
    }

    fn render_layout(
        &self,
        view: &View,
        layout: &Layout,
        edges: Edges,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        match layout {
            Layout::Pane { id, terminal } => self.render_pane(view, *id, terminal, edges, cx),
            Layout::Split {
                id,
                axis,
                first,
                second,
            } => {
                let (group, first_edges, second_edges) = match axis {
                    SplitAxis::Horizontal => (
                        h_resizable(("split", *id)),
                        Edges {
                            right: false,
                            ..edges
                        },
                        Edges {
                            left: false,
                            ..edges
                        },
                    ),
                    SplitAxis::Vertical => (
                        v_resizable(("split", *id)),
                        Edges {
                            bottom: false,
                            ..edges
                        },
                        Edges {
                            top: false,
                            ..edges
                        },
                    ),
                };
                group
                    .child(resizable_panel().child(self.render_layout(
                        view,
                        first,
                        first_edges,
                        cx,
                    )))
                    .child(resizable_panel().child(self.render_layout(
                        view,
                        second,
                        second_edges,
                        cx,
                    )))
                    .into_any_element()
            }
        }
    }

    /// A terminal. In a view of several it has a header (drag grip, status, name, tag, isolation,
    /// task controls, edit, close; right-click for more); an item's only terminal has none. Open
    /// terminals carry an amber edge. While a header is dragged, every other pane becomes a drop
    /// target that swaps with it. Corners on the card's edge are rounded like the card.
    fn render_pane(
        &self,
        view: &View,
        pane: Id,
        spec: &TerminalSpec,
        edges: Edges,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let with_header = view.single().is_none();
        let focused = view.focused == Some(pane);
        let label: SharedString = self.pane_label(pane, cx).into();
        let running = self.is_running(pane, cx);
        let exit = self.exits.get(&pane).copied();
        let isolation = spec.effective_isolation();
        let (top_left, top_right) = (
            Edges::radius(edges.top && edges.left),
            Edges::radius(edges.top && edges.right),
        );
        let (bottom_left, bottom_right) = (
            Edges::radius(edges.bottom && edges.left),
            Edges::radius(edges.bottom && edges.right),
        );
        if let Some(terminal) = self.panes.get(&pane) {
            let corners = Corners {
                top_left: if with_header { px(0.) } else { top_left },
                top_right: if with_header { px(0.) } else { top_right },
                bottom_right,
                bottom_left,
            };
            terminal.update(cx, |terminal, cx| terminal.set_corners(corners, cx));
        }
        let theme = cx.theme();
        let (ring, muted, warning) = (theme.ring, theme.muted_foreground, theme.warning);
        let (border, background, foreground) = (theme.border, theme.background, theme.foreground);
        let dot = match (running, exit) {
            (true, _) => theme.success,
            (false, Some(Some(code))) if code != 0 => theme.danger,
            _ => muted.opacity(0.5),
        };

        let header = with_header.then(|| {
            let status: SharedString = match (running, exit) {
                (true, _) => "Running".into(),
                (false, Some(Some(code))) => format!("Exited with code {code}").into(),
                (false, Some(None)) => "Stopped".into(),
                (false, None) => "Not started".into(),
            };
            let isolation_badge = match &isolation {
                Isolation::Sandboxed { profile } => {
                    let name = Profiles::get(cx).sandbox_for(*profile).name;
                    let tooltip =
                        SharedString::from(format!("Sandboxed ({name}): sees only the project"));
                    div()
                        .id(("isolation", pane))
                        .flex_none()
                        .tooltip(move |window, cx| Tooltip::new(tooltip.clone()).build(window, cx))
                        .child(Icon::new(IconName::Shield).xsmall().text_color(muted))
                        .into_any_element()
                }
                Isolation::Open => div()
                    .id(("isolation", pane))
                    .flex_none()
                    .px_1()
                    .rounded_sm()
                    .text_color(warning)
                    .bg(warning.opacity(0.12))
                    .tooltip(|window, cx| {
                        Tooltip::new("Open terminal: not sandboxed").build(window, cx)
                    })
                    .child("open")
                    .into_any_element(),
            };
            let weak = cx.entity().downgrade();
            let row_group = SharedString::from(format!("pane-header-{pane}"));
            let background_mark = spec.background;
            h_flex()
                .id(("pane-header", pane))
                .group(row_group.clone())
                .relative()
                .flex_none()
                .h(px(28.))
                .pl_1p5()
                .pr_1()
                .gap_1p5()
                .rounded_tl(top_left)
                .rounded_tr(top_right)
                .border_b_1()
                // The focused terminal: its header tinted with the accent.
                .border_color(if focused {
                    background.blend(ring.opacity(0.45))
                } else {
                    border
                })
                .bg(if focused {
                    background.blend(ring.opacity(0.2))
                } else {
                    background
                })
                .text_xs()
                .text_color(if focused { foreground } else { muted })
                .cursor_grab()
                .on_click(cx.listener(move |this, event: &ClickEvent, window, cx| {
                    if event.click_count() >= 2 {
                        this.start_rename(RenameTarget::Terminal(pane), window, cx);
                    } else {
                        this.focus_pane(pane, window, cx);
                    }
                }))
                .on_drag(
                    DraggedPane {
                        pane,
                        label: label.clone(),
                    },
                    |dragged, _, _, cx| cx.new(|_| dragged.clone()),
                )
                .child(
                    Icon::new(IconName::GripVertical)
                        .xsmall()
                        .text_color(muted.opacity(0.7)),
                )
                .child(
                    div()
                        .id(("pane-status", pane))
                        .flex_none()
                        .size(px(7.))
                        .rounded_full()
                        .bg(dot)
                        .tooltip(move |window, cx| Tooltip::new(status.clone()).build(window, cx)),
                )
                .child(div().min_w_0().child(self.name_or_editor(
                    RenameTarget::Terminal(pane),
                    label.clone(),
                    div().truncate(),
                )))
                .when_some(spec.tag.clone(), |header, tag| {
                    header.child(
                        div()
                            .flex_none()
                            .px_1()
                            .rounded_sm()
                            .bg(muted.opacity(0.15))
                            .child(tag),
                    )
                })
                .child(isolation_badge)
                .child(div().flex_1())
                .child(self.terminal_controls(pane, cx))
                .child(
                    div()
                        .when(!focused, |close| {
                            close
                                .opacity(0.)
                                .group_hover(row_group, |style| style.opacity(1.))
                        })
                        .child(
                            icon_button(("close-pane", pane), IconName::X, "Close (⌘W)")
                                .xsmall()
                                .on_click(cx.listener(move |this, _, window, cx| {
                                    cx.stop_propagation();
                                    this.request_close(pane, window, cx);
                                })),
                        ),
                )
                .context_menu(move |menu, _, _| {
                    let (edit, rename, background, close) =
                        (weak.clone(), weak.clone(), weak.clone(), weak.clone());
                    menu.item(
                        PopupMenuItem::new("Edit terminal")
                            .icon(IconName::Pencil)
                            .on_click(move |_, window, cx| {
                                update(&edit, window, cx, |this, window, cx| {
                                    this.edit_terminal(pane, window, cx)
                                });
                            }),
                    )
                    .item(
                        PopupMenuItem::new("Rename")
                            .icon(IconName::TextCursorInput)
                            .on_click(move |_, window, cx| {
                                update(&rename, window, cx, |this, window, cx| {
                                    this.start_rename(RenameTarget::Terminal(pane), window, cx)
                                });
                            }),
                    )
                    .item(
                        PopupMenuItem::new("Keep alive")
                            .checked(background_mark)
                            .on_click(move |_, window, cx| {
                                update(&background, window, cx, |this, _, cx| {
                                    this.toggle_background(pane, cx)
                                });
                            }),
                    )
                    .separator()
                    .item(
                        PopupMenuItem::new("Close").icon(IconName::X).on_click(
                            move |_, window, cx| {
                                update(&close, window, cx, |this, window, cx| {
                                    this.request_close(pane, window, cx)
                                });
                            },
                        ),
                    )
                })
        });

        // The amber edge of an open terminal stays clear of rounded corners.
        let edge_top = if with_header { px(0.) } else { top_left };
        v_flex()
            .relative()
            .size_full()
            .children(header)
            .child(
                div()
                    .flex_1()
                    .min_h_0()
                    .children(self.panes.get(&pane).cloned()),
            )
            // Open terminals: an amber edge, so they are never mistaken for sandboxed ones.
            .when(isolation == Isolation::Open, |pane| {
                pane.child(
                    div()
                        .absolute()
                        .top(edge_top)
                        .bottom(bottom_left)
                        .left_0()
                        .w(px(2.))
                        .bg(warning.opacity(0.8)),
                )
            })
            // While a header is dragged: where the pane would land, from where the pointer is
            // (an edge splits there, the middle swaps).
            .when(with_header && cx.has_active_drag(), |body| {
                let zone = self
                    .drop_target
                    .filter(|(target, _)| *target == pane)
                    .map(|(_, side)| side);
                let highlight = zone.map(|side| {
                    let area = div()
                        .absolute()
                        .bg(ring.opacity(0.14))
                        .border_2()
                        .border_color(ring.opacity(0.7))
                        .rounded_md();
                    match side {
                        None => area.inset(px(6.)),
                        Some(Side::Left) => area.top_0().bottom_0().left_0().w_1_2(),
                        Some(Side::Right) => area.top_0().bottom_0().right_0().w_1_2(),
                        Some(Side::Top) => area.left_0().right_0().top_0().h_1_2(),
                        Some(Side::Bottom) => area.left_0().right_0().bottom_0().h_1_2(),
                    }
                });
                body.child(
                    div()
                        .absolute()
                        .inset_0()
                        .children(highlight)
                        .on_drag_move(cx.listener(
                            move |this, event: &DragMoveEvent<DraggedPane>, _, cx| {
                                let inside = event.bounds.contains(&event.event.position);
                                let target = (inside && event.drag(cx).pane != pane)
                                    .then(|| (pane, drop_side(event.bounds, event.event.position)));
                                let changed = match target {
                                    Some(target) => this.drop_target != Some(target),
                                    // Leaving this pane clears it, unless another pane took over.
                                    None => {
                                        this.drop_target.is_some_and(|(current, _)| current == pane)
                                    }
                                };
                                if changed {
                                    this.drop_target = target;
                                    cx.notify();
                                }
                            },
                        ))
                        .on_drop(cx.listener(move |this, dragged: &DraggedPane, window, cx| {
                            let side = this
                                .drop_target
                                .filter(|(target, _)| *target == pane)
                                .and_then(|(_, side)| side);
                            this.drop_pane(dragged.pane, pane, side, window, cx);
                        })),
                )
            })
            .into_any_element()
    }

    /// What the main area shows without terminals: a button for the first one.
    fn render_empty(&self, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let muted = cx.theme().muted_foreground;
        let (message, buttons) = (
            "No terminals in this project yet",
            h_flex().gap_2().child(
                Button::new("empty-terminal")
                    .primary()
                    .small()
                    .icon(IconName::Plus)
                    .label("New terminal")
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.new_shell(Isolation::default(), window, cx)
                    })),
            ),
        );
        v_flex()
            .size_full()
            .items_center()
            .justify_center()
            .gap_4()
            .child(
                Icon::new(IconName::SquareTerminal)
                    .size(px(40.))
                    .text_color(muted.opacity(0.6)),
            )
            .child(div().text_color(muted).child(message))
            .child(buttons)
    }
}

/// What a confirmation button does.
type Action = Rc<dyn Fn(&mut Window, &mut App)>;

/// A button in a confirmation.
struct Choice {
    label: &'static str,
    danger: bool,
    run: Action,
}

impl Choice {
    fn plain(label: &'static str, run: impl Fn(&mut Window, &mut App) + 'static) -> Self {
        Self {
            label,
            danger: false,
            run: Rc::new(run),
        }
    }

    fn danger(label: &'static str, run: impl Fn(&mut Window, &mut App) + 'static) -> Self {
        Self {
            label,
            danger: true,
            run: Rc::new(run),
        }
    }
}

/// Ask before something that stops running terminals: Cancel, then the given choices.
fn confirm(
    window: &mut Window,
    cx: &mut App,
    title: String,
    description: String,
    choices: Vec<Choice>,
) {
    let choices = Rc::new(choices);
    window.open_dialog(cx, move |dialog, _, _| {
        let buttons = choices.iter().enumerate().map(|(index, choice)| {
            let run = choice.run.clone();
            Button::new(("confirm", index))
                .label(choice.label)
                .when(choice.danger, |button| button.danger())
                .on_click(move |_, window, cx| {
                    window.close_dialog(cx);
                    let run = run.clone();
                    window.defer(cx, move |window, cx| run(window, cx));
                })
        });
        dialog
            .title(title.clone())
            .w(px(420.))
            .entrance(DialogEntrance::FadeSlide)
            .child(div().text_sm().child(description.clone()))
            .footer(
                h_flex()
                    .w_full()
                    .justify_end()
                    .gap_2()
                    .child(
                        Button::new("confirm-cancel")
                            .label("Cancel")
                            .on_click(|_, window, cx| window.close_dialog(cx)),
                    )
                    .children(buttons),
            )
    });
}

/// Where a pane dropped at `position` lands on the pane at `bounds`: beside it, on the edge the
/// pointer is nearest when within a third of it, or (`None`) in its place.
fn drop_side(bounds: Bounds<Pixels>, position: Point<Pixels>) -> Option<Side> {
    let width = f32::from(bounds.size.width).max(1.);
    let height = f32::from(bounds.size.height).max(1.);
    let x = f32::from(position.x - bounds.left()) / width;
    let y = f32::from(position.y - bounds.top()) / height;
    let (distance, side) = [
        (x, Side::Left),
        (1. - x, Side::Right),
        (y, Side::Top),
        (1. - y, Side::Bottom),
    ]
    .into_iter()
    .min_by(|a, b| a.0.total_cmp(&b.0))?;
    (distance < 1. / 3.).then_some(side)
}

/// Holder for title bar buttons. Clicks on them stop here: the title bar zooms the window on a
/// double click and starts a window drag on mouse down, and quick repeated clicks on a button must
/// not do either.
pub(crate) fn title_buttons(id: &'static str) -> gpui::Stateful<gpui::Div> {
    h_flex()
        .id(id)
        .flex_none()
        .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
        .on_click(|_, _, cx| cx.stop_propagation())
}

/// A compact icon-only toolbar button.
pub(crate) fn icon_button(
    id: impl Into<gpui::ElementId>,
    icon: IconName,
    tooltip: &'static str,
) -> Button {
    Button::new(id).ghost().small().icon(icon).tooltip(tooltip)
}

/// Run `f` on the workspace from a menu callback.
pub(crate) fn update<V: 'static>(
    weak: &WeakEntity<V>,
    window: &mut Window,
    cx: &mut App,
    f: impl FnOnce(&mut V, &mut Window, &mut Context<V>),
) {
    let _ = weak.update(cx, |this, cx| f(this, window, cx));
}

/// A task with nothing filled in yet, for the terminal dialog.
fn task_kind() -> TerminalKind {
    TerminalKind::Task {
        command: String::new(),
        auto_start: false,
        restart_on_exit: false,
    }
}

/// Open a folder in Zed: with its `zed` command when installed, else through the app.
fn open_in_zed(dir: &Path) {
    let (program, args) = zed_command(dir, which("zed"));
    if let Err(err) = Command::new(program).args(args).spawn() {
        eprintln!("could not open Zed: {err}");
    }
}

fn zed_command(dir: &Path, cli: bool) -> (&'static str, Vec<String>) {
    let dir = dir.to_string_lossy().into_owned();
    if cli {
        ("zed", vec![dir])
    } else {
        ("open", vec!["-a".to_owned(), "Zed".to_owned(), dir])
    }
}

/// Whether `program` is on PATH.
fn which(program: &str) -> bool {
    std::env::var_os("PATH")
        .is_some_and(|path| std::env::split_paths(&path).any(|dir| dir.join(program).is_file()))
}

/// Where a terminal starts: its folder in the project, or the project folder if that is gone.
fn start_dir(project: &Project, spec: &TerminalSpec) -> PathBuf {
    let dir = project.folder(&spec.folder);
    if dir.is_dir() { dir } else { project.root() }
}

/// What a terminal runs, started in `dir`: its shell, task or SSH session, inside its sandbox
/// unless it is open.
fn launch_for(spec: &TerminalSpec, project: &Project, pane: Id, dir: &Path, cx: &App) -> Launch {
    let isolation = spec.effective_isolation();
    let mut extra_writable = Vec::new();
    let (program, args, env, again) = match &spec.kind {
        TerminalKind::Shell => {
            if isolation == Isolation::Open {
                return Launch::Shell;
            }
            // The user's shell, with shell integration, keeping a history of its own: the user's
            // history is out of the sandbox's reach.
            let integration = shell_integration::launch(TerminalSettings::get(cx));
            let (program, args) = match integration.program {
                Some(program) => (program, integration.args),
                None => (login_shell(cx), vec!["-l".to_owned()]),
            };
            let mut env = integration.env;
            let history = sandbox_history(project.id);
            env.push((
                shell_integration::HISTFILE_ENV.to_owned(),
                history.to_string_lossy().into_owned(),
            ));
            extra_writable.push(history);
            (program, args, env, "restart")
        }
        TerminalKind::Task { command, .. } => (
            login_shell(cx),
            vec!["-lc".to_owned(), command.clone()],
            Vec::new(),
            "start",
        ),
        TerminalKind::Ssh { host } => return ssh_launch(*host, cx),
    };
    let Isolation::Sandboxed { profile } = isolation else {
        return Launch::Program {
            program,
            args,
            env,
            env_remove: Vec::new(),
            again,
        };
    };
    let profile = Profiles::get(cx).sandbox_for(profile);
    let wrapped = sandbox::wrap(
        &profile,
        pane,
        &project.root(),
        dir,
        &program,
        &args,
        &extra_writable,
    );
    let docker = matches!(profile.engine, SandboxEngine::Docker { .. });
    Launch::Program {
        program: wrapped.program,
        args: wrapped.args,
        env: if docker { Vec::new() } else { env },
        env_remove: wrapped.env_remove,
        again,
    }
}

/// A project's sandboxed shells share a history of their own, kept with the app's settings.
fn sandbox_history(project: Id) -> PathBuf {
    let dir = TerminalSettings::path().parent().map_or_else(
        || PathBuf::from("sandbox-history"),
        |dir| dir.join("sandbox-history"),
    );
    if let Err(err) = std::fs::create_dir_all(&dir) {
        eprintln!("could not create {}: {err}", dir.display());
    }
    dir.join(format!("project-{project}.history"))
}

/// An SSH session to a global host, with its saved password or vault key.
fn ssh_launch(host: Id, cx: &App) -> Launch {
    let message = |text: &str, again: &'static str| Launch::Program {
        program: "/bin/sh".to_owned(),
        args: vec!["-c".to_owned(), format!("echo '{text}'; exit 1")],
        env: Vec::new(),
        env_remove: Vec::new(),
        again,
    };
    let Some(host) = Profiles::get(cx).host(host) else {
        return message("This SSH host is no longer registered.", "try again");
    };
    let saved = host.auth == SshAuth::Password && keychain::has_password(host.id);
    let vault = match &host.auth {
        SshAuth::Vault { item, .. } => match Vault::identity(item, cx) {
            Some(identity) => Some(identity),
            None => {
                return message(
                    "Vaultwarden is locked. Unlock it in Global (the lock next to SSH hosts), then press Enter.",
                    "connect",
                );
            }
        },
        _ => None,
    };
    let command = ssh::interactive(host, saved, vault.as_ref());
    Launch::Program {
        program: command.program,
        args: command.args,
        env: command.env,
        env_remove: Vec::new(),
        again: "reconnect",
    }
}

/// The shell commands run through: the configured one, else `$SHELL`.
fn login_shell(cx: &App) -> String {
    let configured = TerminalSettings::get(cx)
        .shell
        .split_whitespace()
        .next()
        .map(str::to_owned);
    configured
        .or_else(|| std::env::var("SHELL").ok())
        .unwrap_or_else(|| "/bin/zsh".to_owned())
}

/// The last component of a folder path (`~` for home, `/` for the root).
fn folder_name(dir: &str) -> String {
    if dir == "/" {
        "/".to_owned()
    } else {
        tilde(dir)
            .trim_end_matches("/.")
            .rsplit('/')
            .next()
            .unwrap_or("~")
            .to_owned()
    }
}

impl Render for WorkspaceView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let main = match self.project.active_view().cloned() {
            Some(view) => match &view.layout {
                Some(layout) => self.render_layout(&view, layout, Edges::ALL, cx),
                None => self.render_empty(cx).into_any_element(),
            },
            None => self.render_empty(cx).into_any_element(),
        };
        // The sidebar slides: its width animates while its content keeps full width and is clipped.
        let motion = cx.theme().motion_tokens();
        let slide = Transition::new(motion.duration_normal).easing(motion.easing_move.clone());
        let sidebar_width = gpui_base::transition(
            "sidebar-width",
            if self.sidebar_open { SIDEBAR_WIDTH } else { 0. },
            slide,
            window,
            cx,
        );
        let sidebar = (sidebar_width > 0.5).then(|| {
            div()
                .w(px(sidebar_width))
                .h_full()
                .flex_none()
                .overflow_hidden()
                .child(self.render_sidebar(cx))
        });
        let sheet = sheet::render(window, cx);
        let theme = cx.theme();
        let (chrome, border) = (theme.title_bar, theme.border);
        // The shell is the only solid surface. A see-through terminal paints its own background,
        // and a card background under it would double its opacity.
        let settings = TerminalSettings::get(cx);
        let card = match settings.background_effect {
            BackgroundEffect::Opaque => crate::theme::terminal_background(cx),
            _ if settings.background_opacity >= 1. => crate::theme::terminal_background(cx),
            _ => gpui::transparent_black(),
        };
        // The gutter left of the card appears as the sidebar closes.
        let left_gutter = (CONTENT_GUTTER - sidebar_width).max(0.);

        v_flex()
            .relative()
            .size_full()
            .bg(chrome)
            .on_action(
                cx.listener(|_, _: &OpenSettings, window, cx| settings_panel::open(window, cx)),
            )
            .on_action(cx.listener(|this, _: &NewShell, window, cx| {
                this.new_shell(Isolation::default(), window, cx)
            }))
            .on_action(cx.listener(|this, _: &NewOpenShell, window, cx| {
                this.new_shell(Isolation::Open, window, cx)
            }))
            .on_action(cx.listener(|this, _: &NewTask, window, cx| this.new_task(window, cx)))
            .on_action(cx.listener(|this, _: &SplitRight, window, cx| {
                this.split(SplitAxis::Horizontal, window, cx)
            }))
            .on_action(cx.listener(|this, _: &SplitDown, window, cx| {
                this.split(SplitAxis::Vertical, window, cx)
            }))
            // ⌘W closes a terminal of a view; with nothing to close in the window, the window.
            .on_action(cx.listener(|this, _: &ClosePane, window, cx| {
                let in_view = this
                    .project
                    .active_view()
                    .is_some_and(|view| view.single().is_none());
                match this.focused_pane().filter(|_| in_view) {
                    Some(pane) => this.request_close(pane, window, cx),
                    None => {
                        if this.should_close(window, cx) {
                            window.remove_window();
                        }
                    }
                }
            }))
            .on_action(cx.listener(|this, _: &NextView, window, cx| {
                if let Some(view) = this.project.cycle_view(1) {
                    this.request_view(view, window, cx);
                }
            }))
            .on_action(cx.listener(|this, _: &PreviousView, window, cx| {
                if let Some(view) = this.project.cycle_view(-1) {
                    this.request_view(view, window, cx);
                }
            }))
            .on_action(cx.listener(|this, _: &NextPane, window, cx| this.cycle_pane(1, window, cx)))
            .on_action(
                cx.listener(|this, _: &PreviousPane, window, cx| this.cycle_pane(-1, window, cx)),
            )
            .on_action(cx.listener(|this, _: &ToggleSidebar, _, cx| this.toggle_sidebar(cx)))
            .on_action(
                cx.listener(|this, _: &SelectView1, window, cx| {
                    this.select_nth_view(0, window, cx)
                }),
            )
            .on_action(
                cx.listener(|this, _: &SelectView2, window, cx| {
                    this.select_nth_view(1, window, cx)
                }),
            )
            .on_action(
                cx.listener(|this, _: &SelectView3, window, cx| {
                    this.select_nth_view(2, window, cx)
                }),
            )
            .on_action(
                cx.listener(|this, _: &SelectView4, window, cx| {
                    this.select_nth_view(3, window, cx)
                }),
            )
            .on_action(
                cx.listener(|this, _: &SelectView5, window, cx| {
                    this.select_nth_view(4, window, cx)
                }),
            )
            .on_action(
                cx.listener(|this, _: &SelectView6, window, cx| {
                    this.select_nth_view(5, window, cx)
                }),
            )
            .on_action(
                cx.listener(|this, _: &SelectView7, window, cx| {
                    this.select_nth_view(6, window, cx)
                }),
            )
            .on_action(
                cx.listener(|this, _: &SelectView8, window, cx| {
                    this.select_nth_view(7, window, cx)
                }),
            )
            .on_action(
                cx.listener(|this, _: &SelectView9, window, cx| {
                    this.select_nth_view(8, window, cx)
                }),
            )
            .child(self.render_title_bar(cx))
            .child(
                h_flex()
                    .flex_1()
                    .min_h_0()
                    .w_full()
                    .children(sidebar)
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .h_full()
                            .pl(px(left_gutter))
                            .pr(px(CONTENT_GUTTER))
                            .pb(px(CONTENT_GUTTER))
                            .child(
                                // gpui clips only to rectangles: panes in the corners round their
                                // own corners to match the card (see `Edges`).
                                div()
                                    .size_full()
                                    .rounded(px(CONTENT_RADIUS))
                                    .border_1()
                                    .border_color(border)
                                    .bg(card)
                                    .child(div().size_full().overflow_hidden().child(main)),
                            ),
                    ),
            )
            .children(sheet)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn opens_zed_with_its_cli_or_through_the_app() {
        let dir = Path::new("/work/rooster");
        assert_eq!(
            zed_command(dir, true),
            ("zed", vec!["/work/rooster".to_owned()])
        );
        assert_eq!(
            zed_command(dir, false),
            (
                "open",
                vec![
                    "-a".to_owned(),
                    "Zed".to_owned(),
                    "/work/rooster".to_owned()
                ]
            )
        );
    }

    #[test]
    fn drops_split_on_the_nearest_edge_and_swap_in_the_middle() {
        let bounds = Bounds {
            origin: gpui::point(px(100.), px(100.)),
            size: gpui::size(px(300.), px(300.)),
        };
        let at = |x: f32, y: f32| drop_side(bounds, gpui::point(px(100. + x), px(100. + y)));
        assert_eq!(at(150., 280.), Some(Side::Bottom));
        assert_eq!(at(150., 10.), Some(Side::Top));
        assert_eq!(at(20., 150.), Some(Side::Left));
        assert_eq!(at(290., 150.), Some(Side::Right));
        assert_eq!(at(150., 150.), None);
        // In a corner, the nearer edge wins.
        assert_eq!(at(10., 290.), Some(Side::Left));
    }

    #[test]
    fn names_folders_by_their_last_component() {
        assert_eq!(folder_name("/work/rooster/apps/api"), "api");
        assert_eq!(folder_name("/work/rooster/."), "rooster");
        assert_eq!(folder_name("/"), "/");
    }
}
