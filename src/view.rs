//! The terminal view: runs the shell session, turns gpui input into terminal bytes, and paints the
//! cell grid with a custom GPU element.

use std::{
    ops::Range,
    path::PathBuf,
    time::{Duration, Instant},
};

use futures::StreamExt as _;
use gpui::{
    App, BorderStyle, Bounds, ClipboardItem, Context, Corners, CursorStyle, DispatchPhase, Element,
    ElementId, ElementInputHandler, Entity, EntityInputHandler, EventEmitter, FocusHandle,
    Focusable, Font, FontFeatures, FontStyle, FontWeight, Global, GlobalElementId, Hsla,
    InspectorElementId, IntoElement, KeyBinding, KeyDownEvent, LayoutId, Modifiers, MouseButton,
    MouseDownEvent, MouseMoveEvent, MouseUpEvent, NoAction, PaintQuad, Pixels, Point, Render, Rgba,
    ScrollWheelEvent, ShapedLine, SharedString, StrikethroughStyle, Style, Subscription, Task,
    TextAlign, TextRun, TouchPhase, UTF16Selection, UnderlineStyle, WeakEntity, Window, actions,
    div, fill, font, outline, point, prelude::*, px, relative, size,
};
use gpui_component::{ActiveTheme, Icon, Sizable as _, Theme, WindowExt as _, h_flex, v_flex};
use libghostty_vt::{
    key::{Key, Mods},
    mouse,
};

use crate::{
    assist::{self, PromptAssist},
    completion::{self, Candidate},
    glyphs,
    history::History,
    history_panel,
    input::{self, PromptKey},
    marks::{MarkScanner, Segment, ShellMark},
    pty::{Pty, PtyEvent, ShellConfig},
    schemes,
    settings::{CursorShapeSetting, PointerStyle, TerminalSettings},
    shell_integration,
    terminal::{
        Cell, CellStyle, ColorConfig, Cursor, CursorShape, Frame, GridPoint, KeyInput, Result, Rgb,
        SelectionAutoscroll, SurfacePoint, Terminal, TerminalConfig, UnderlineKind, WheelOutcome,
    },
    ui,
    workspace::expand_home,
};

actions!(
    terminal_view,
    [
        Copy,
        Cut,
        Paste,
        SelectAll,
        SelectLeft,
        SelectRight,
        SelectWordLeft,
        SelectWordRight,
        SelectToLineStart,
        SelectToLineEnd,
        ClearScreen,
        DeleteWordBackward,
        DeleteWordForward,
        MoveWordBackward,
        MoveWordForward,
        MoveToLineStart,
        MoveToLineEnd,
        DeleteToLineStart,
        DeleteToLineEnd,
        ScrollPageUp,
        ScrollPageDown,
        ScrollToTop,
        ScrollToBottom,
        IncreaseFontSize,
        DecreaseFontSize,
        ResetFontSize,
        RestartShell,
        ShowHistory,
    ]
);

const CONTEXT: &str = "Terminal";
const BLINK_INTERVAL: Duration = Duration::from_millis(530);
const AUTOSCROLL_INTERVAL: Duration = Duration::from_millis(50);
const BELL_DURATION: Duration = Duration::from_millis(150);
/// After Enter, the cursor stays hidden until the next prompt is drawn, or until output has been
/// quiet this long (for shells without integration and for programs waiting for input).
const CURSOR_SETTLE: Duration = Duration::from_millis(200);
/// Longest time a frame is held back for an application's synchronized update (mode 2026).
const SYNC_OUTPUT_TIMEOUT: Duration = Duration::from_millis(500);
/// Frames slower than this are logged when `GPU_TERMINAL_PROFILE` is set.
const SLOW_FRAME: Duration = Duration::from_millis(4);
const FAINT_ALPHA: f32 = 0.55;
const SELECTION_ALPHA: f32 = 0.3;

/// Editor-style shortcuts. Word and line edits send the readline/zle sequences shells understand.
pub fn bind_keys(cx: &mut App) {
    let context = Some(CONTEXT);
    cx.bind_keys([
        // gpui-component's Root uses tab/shift-tab for focus cycling; the shell needs them.
        KeyBinding::new("tab", NoAction, context),
        KeyBinding::new("shift-tab", NoAction, context),
        KeyBinding::new("cmd-c", Copy, context),
        KeyBinding::new("cmd-x", Cut, context),
        KeyBinding::new("cmd-v", Paste, context),
        KeyBinding::new("cmd-a", SelectAll, context),
        KeyBinding::new("shift-left", SelectLeft, context),
        KeyBinding::new("shift-right", SelectRight, context),
        KeyBinding::new("shift-alt-left", SelectWordLeft, context),
        KeyBinding::new("shift-ctrl-left", SelectWordLeft, context),
        KeyBinding::new("shift-alt-right", SelectWordRight, context),
        KeyBinding::new("shift-ctrl-right", SelectWordRight, context),
        KeyBinding::new("shift-cmd-left", SelectToLineStart, context),
        KeyBinding::new("shift-home", SelectToLineStart, context),
        KeyBinding::new("shift-up", SelectToLineStart, context),
        KeyBinding::new("shift-cmd-right", SelectToLineEnd, context),
        KeyBinding::new("shift-end", SelectToLineEnd, context),
        KeyBinding::new("shift-down", SelectToLineEnd, context),
        KeyBinding::new("cmd-k", ClearScreen, context),
        KeyBinding::new("alt-backspace", DeleteWordBackward, context),
        KeyBinding::new("ctrl-backspace", DeleteWordBackward, context),
        KeyBinding::new("alt-delete", DeleteWordForward, context),
        KeyBinding::new("ctrl-delete", DeleteWordForward, context),
        KeyBinding::new("alt-left", MoveWordBackward, context),
        KeyBinding::new("ctrl-left", MoveWordBackward, context),
        KeyBinding::new("alt-right", MoveWordForward, context),
        KeyBinding::new("ctrl-right", MoveWordForward, context),
        KeyBinding::new("cmd-left", MoveToLineStart, context),
        KeyBinding::new("cmd-right", MoveToLineEnd, context),
        KeyBinding::new("cmd-backspace", DeleteToLineStart, context),
        KeyBinding::new("cmd-delete", DeleteToLineEnd, context),
        KeyBinding::new("shift-pageup", ScrollPageUp, context),
        KeyBinding::new("shift-pagedown", ScrollPageDown, context),
        KeyBinding::new("cmd-up", ScrollToTop, context),
        KeyBinding::new("cmd-down", ScrollToBottom, context),
        KeyBinding::new("cmd-=", IncreaseFontSize, context),
        KeyBinding::new("cmd--", DecreaseFontSize, context),
        KeyBinding::new("cmd-0", ResetFontSize, context),
        KeyBinding::new("cmd-shift-r", RestartShell, context),
        KeyBinding::new("ctrl-r", ShowHistory, context),
    ]);
}

/// Shortcut reference shown in the settings panel.
pub const SHORTCUTS: &[(&str, &str)] = &[
    ("⇧← / ⇧→", "Select characters on the command line"),
    ("⇧⌥← / ⇧⌥→", "Select words"),
    ("⇧⌘← / ⇧⌘→", "Select to line start / end"),
    (
        "Type / ⌫ with a selection",
        "Replace / delete the selected text",
    ),
    ("⌘X", "Cut selected command-line text"),
    ("⌥⌫ / ⌃⌫", "Delete word backward"),
    ("⌥⌦ / ⌃⌦", "Delete word forward"),
    ("⌥← / ⌥→", "Move by word"),
    ("⌘← / ⌘→", "Line start / end"),
    ("⌘⌫ / ⌘⌦", "Delete to line start / end"),
    ("⌘C / ⌘V", "Copy / paste"),
    ("⌘A", "Select all"),
    ("⌘K", "Clear screen and scrollback"),
    ("⇧PgUp / ⇧PgDn", "Scroll a page"),
    ("⌘↑ / ⌘↓", "Scroll to top / bottom"),
    ("PgUp / PgDn", "Scroll a page (at the prompt)"),
    ("⌘= / ⌘- / ⌘0", "Font size bigger / smaller / reset"),
    ("⌘⇧R", "Restart shell"),
    (
        "Tab",
        "Completion menu (↑↓ choose, Tab/⏎ accept, Esc close)",
    ),
    ("→ / ⌃F / ⌘→", "Accept the gray history suggestion"),
    ("⌥→", "Accept the next word of the suggestion"),
    ("⌃R", "Search command history"),
    ("⌘,", "Settings"),
    ("Click", "Move the cursor on the prompt line"),
    ("Double / triple click", "Select word / line"),
    ("⇧ + mouse", "Select even when an app captures the mouse"),
];

/// What a terminal runs.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum Launch {
    /// The configured shell, with shell integration.
    #[default]
    Shell,
    /// A program of its own (a command, an ssh session), without shell integration.
    Program {
        program: String,
        args: Vec<String>,
        env: Vec<(String, String)>,
        /// Inherited variables to leave out.
        env_remove: Vec<String>,
        /// What pressing Enter after it exits does: "run it again", "reconnect", …
        again: &'static str,
    },
}

pub enum TerminalEvent {
    /// The running program set a window title (empty when it was cleared).
    TitleChanged,
    /// The shell is back at a prompt (its working directory may have changed).
    PromptReady,
    /// The shell is about to run a command line.
    CommandStarted,
    Focused,
    /// The shell (or program) started.
    Started,
    /// It exited with this status; `stopped` when that was asked for with [`TerminalView::stop`].
    Exited {
        code: Option<u32>,
        stopped: bool,
    },
}

/// The terminal that app-level UI (e.g. the settings sheet) acts on.
pub struct ActiveTerminal(pub WeakEntity<TerminalView>);

impl Global for ActiveTerminal {}

/// Cursor motions that extend the keyboard selection.
#[derive(Clone, Copy, Debug)]
enum SelectMotion {
    Left,
    Right,
    WordLeft,
    WordRight,
    LineStart,
    LineEnd,
}

impl SelectMotion {
    /// The shifted key a full-screen application would expect for this motion.
    fn app_key(self) -> KeyInput {
        match self {
            Self::Left => key_with(Key::ArrowLeft, Mods::SHIFT),
            Self::Right => key_with(Key::ArrowRight, Mods::SHIFT),
            Self::WordLeft => key_with(Key::ArrowLeft, Mods::SHIFT | Mods::ALT),
            Self::WordRight => key_with(Key::ArrowRight, Mods::SHIFT | Mods::ALT),
            Self::LineStart => key_with(Key::Home, Mods::SHIFT),
            Self::LineEnd => key_with(Key::End, Mods::SHIFT),
        }
    }
}

fn key_with(key: Key, mods: Mods) -> KeyInput {
    KeyInput {
        mods,
        ..KeyInput::named(key)
    }
}

/// Cell geometry resolved from the element bounds, font metrics and settings during prepaint.
#[derive(Clone, Copy, Debug, PartialEq)]
struct GridLayout {
    bounds: Bounds<Pixels>,
    /// Top-left corner of cell (0, 0) in window coordinates.
    origin: Point<Pixels>,
    cell_width: Pixels,
    line_height: Pixels,
    cols: u16,
    rows: u16,
    scale: f32,
}

impl GridLayout {
    fn cell_origin(&self, col: u16, row: u16) -> Point<Pixels> {
        point(
            self.origin.x + self.cell_width * f32::from(col),
            self.origin.y + self.line_height * f32::from(row),
        )
    }

    fn cell_bounds(&self, col: u16, row: u16, width: u16) -> Bounds<Pixels> {
        let origin = self.cell_origin(col, row);
        Bounds::new(
            point(origin.x.floor(), origin.y),
            size(
                (self.cell_width * f32::from(width)).ceil(),
                self.line_height,
            ),
        )
    }

    fn cell_px(&self) -> (u32, u32) {
        let device = |value: Pixels| ((f32::from(value) * self.scale).round() as u32).max(1);
        (device(self.cell_width), device(self.line_height))
    }

    /// Map a window position to the (clamped) cell under it and its surface-pixel position.
    /// The surface y is left unclamped so drags above/below the grid can trigger autoscroll.
    fn locate(&self, position: Point<Pixels>) -> (GridPoint, SurfacePoint) {
        let local = position - self.origin;
        let fx = f32::from(local.x) / f32::from(self.cell_width);
        let fy = f32::from(local.y) / f32::from(self.line_height);
        let col = fx.floor().clamp(0., f32::from(self.cols - 1));
        let row = fy.floor().clamp(0., f32::from(self.rows - 1));
        let (cell_w, cell_h) = self.cell_px();
        let x = (col + (fx - col).clamp(0., 0.999)) * cell_w as f32;
        let y = fy * cell_h as f32;
        (
            GridPoint {
                col: col as u16,
                row: row as u16,
            },
            SurfacePoint { x, y },
        )
    }
}

#[derive(Default)]
struct MouseState {
    /// A selection gesture is in progress (left button held).
    selecting: bool,
    autoscrolling: bool,
    /// Button currently held down and reported to the application.
    reported_button: Option<MouseButton>,
    last_position: Option<Point<Pixels>>,
    _autoscroll_task: Option<Task<()>>,
}

pub struct TerminalView {
    terminal: Terminal,
    pty: Option<Pty>,
    exited: bool,
    /// A stop was asked for and the process has not exited yet.
    stopping: bool,
    _stop_task: Task<()>,
    focus_handle: FocusHandle,
    focused: bool,
    layout: Option<GridLayout>,
    /// Title set by the running program (empty when none).
    title: SharedString,
    launch: Launch,
    /// Directory the next shell starts in.
    start_dir: Option<PathBuf>,
    /// Blink phase; the cursor is drawn while this is `true`.
    cursor_on: bool,
    bell_flash: bool,
    /// Fractional wheel lines carried over between scroll events (trackpads report pixels).
    scroll_remainder: f32,
    /// Uncommitted IME composition text.
    marked_text: Option<String>,
    mouse: MouseState,
    epoch: Instant,
    /// When the running application started a synchronized update, if one is in progress.
    sync_output_since: Option<Instant>,
    marks: MarkScanner,
    assist: PromptAssist,
    /// While set (and in the future), the cursor is hidden because a command is producing output.
    cursor_hidden_until: Option<Instant>,
    _cursor_task: Task<()>,
    profile: bool,
    /// Rounded corners of the background, where the terminal meets a rounded edge of the window.
    corners: Corners<Pixels>,
    _sync_output_task: Task<()>,
    _io_task: Task<()>,
    _blink_task: Task<()>,
    _bell_task: Task<()>,
    _subscriptions: Vec<Subscription>,
}

impl EventEmitter<TerminalEvent> for TerminalView {}

impl TerminalView {
    /// Create the VT state machine for a new session.
    pub fn create_terminal(cx: &App) -> Result<Terminal> {
        let scrollback = TerminalSettings::get(cx).scrollback_lines as usize;
        Terminal::new(TerminalConfig {
            scrollback,
            ..TerminalConfig::default()
        })
    }

    /// `cwd` is where it starts; `None` uses the configured working directory. Without `start` it
    /// waits for [`Self::start`] (or Enter).
    pub fn new(
        terminal: Terminal,
        launch: Launch,
        cwd: Option<PathBuf>,
        start: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let focus_handle = cx.focus_handle();
        let subscriptions = vec![
            cx.on_focus(&focus_handle, window, |this, _, cx| {
                this.focus_changed(true, cx)
            }),
            cx.on_blur(&focus_handle, window, |this, _, cx| {
                this.focus_changed(false, cx)
            }),
            cx.observe_global::<TerminalSettings>(|this, cx| {
                this.apply_settings(cx);
                cx.notify();
            }),
            cx.observe_global::<Theme>(|this, cx| {
                this.apply_settings(cx);
                cx.notify();
            }),
        ];

        let mut view = Self {
            terminal,
            pty: None,
            exited: false,
            stopping: false,
            _stop_task: Task::ready(()),
            focused: focus_handle.is_focused(window),
            focus_handle,
            layout: None,
            title: SharedString::default(),
            launch,
            start_dir: cwd,
            cursor_on: true,
            bell_flash: false,
            scroll_remainder: 0.,
            marked_text: None,
            mouse: MouseState::default(),
            epoch: Instant::now(),
            sync_output_since: None,
            marks: MarkScanner::default(),
            assist: PromptAssist::default(),
            cursor_hidden_until: None,
            _cursor_task: Task::ready(()),
            profile: std::env::var_os("GPU_TERMINAL_PROFILE").is_some(),
            corners: Corners::default(),
            _sync_output_task: Task::ready(()),
            _io_task: Task::ready(()),
            _blink_task: Task::ready(()),
            _bell_task: Task::ready(()),
            _subscriptions: subscriptions,
        };
        view.apply_settings(cx);
        if start {
            view.start(cx);
        } else {
            view.exited = true;
            view.terminal
                .write(b"\x1b[2m[Not started. Press Enter or \xe2\x96\xb6 to start.]\x1b[0m\r\n");
        }
        view.reset_blink(cx);
        view
    }

    /// The shell's working directory as of its last prompt.
    pub fn cwd(&self) -> Option<&str> {
        self.assist.cwd()
    }

    /// Title set by the running program (empty when none).
    pub fn title(&self) -> &SharedString {
        &self.title
    }

    pub fn set_corners(&mut self, corners: Corners<Pixels>, cx: &mut Context<Self>) {
        if self.corners != corners {
            self.corners = corners;
            cx.notify();
        }
    }

    /// Name of the foreground process: the shell at a prompt, else the program it is running.
    pub fn process_name(&self) -> Option<String> {
        self.pty.as_ref()?.foreground_process()
    }

    /// Push the current settings and theme into the VT state machine.
    fn apply_settings(&mut self, cx: &mut Context<Self>) {
        let settings = TerminalSettings::get(cx);
        let theme = cx.theme();
        let (colors, dark) = match schemes::find(&settings.color_scheme) {
            Some(scheme) => {
                let background = schemes::rgb(scheme.background);
                let colors = ColorConfig {
                    foreground: schemes::rgb(scheme.foreground),
                    background,
                    cursor: scheme.cursor.map(schemes::rgb),
                    ansi: Some(scheme.ansi.map(schemes::rgb)),
                };
                (colors, luminance(background) < 0.5)
            }
            None => {
                let colors = ColorConfig {
                    foreground: rgb_from_hsla(theme.foreground),
                    background: rgb_from_hsla(crate::theme::terminal_background(cx)),
                    cursor: None,
                    ansi: None,
                };
                (colors, theme.is_dark())
            }
        };
        let cursor_shape = match settings.cursor_shape {
            CursorShapeSetting::Bar => CursorShape::Bar,
            CursorShapeSetting::Block => CursorShape::Block,
            CursorShapeSetting::Underline => CursorShape::Underline,
            CursorShapeSetting::BlockHollow => CursorShape::BlockHollow,
        };
        let (blink, bold_is_bright, option_as_alt) = (
            settings.cursor_blink,
            settings.bold_is_bright,
            settings.option_as_alt,
        );

        let terminal = &mut self.terminal;
        let result = terminal
            .set_colors(&colors)
            .and_then(|()| terminal.set_default_cursor(cursor_shape, blink));
        if let Err(err) = result {
            eprintln!("failed to apply terminal settings: {err:?}");
        }
        terminal.set_dark_mode(dark);
        terminal.set_bold_is_bright(bold_is_bright);
        terminal.set_option_as_alt(option_as_alt);
    }

    /// Spawn the shell (or program) on a fresh PTY and start pumping its output into the VT.
    fn start(&mut self, cx: &mut Context<Self>) {
        self.stopping = false;
        self._stop_task = Task::ready(());
        let settings = TerminalSettings::get(cx);
        let (cols, rows) = self.terminal.size().unwrap_or((80, 24));
        let configured = settings.working_directory.trim();
        let working_directory = self
            .start_dir
            .clone()
            .or_else(|| (!configured.is_empty()).then(|| expand_home(configured)));
        let (program, args, env, env_remove) = match &self.launch {
            Launch::Shell => {
                let launch = shell_integration::launch(settings);
                (launch.program, launch.args, launch.env, Vec::new())
            }
            Launch::Program {
                program,
                args,
                env,
                env_remove,
                ..
            } => (
                Some(program.clone()),
                args.clone(),
                env.clone(),
                env_remove.clone(),
            ),
        };
        let config = ShellConfig {
            program,
            args,
            env,
            env_remove,
            working_directory,
            cols,
            rows,
        };

        let (events_tx, mut events) = futures::channel::mpsc::unbounded();
        let pty = match Pty::spawn(&config, events_tx) {
            Ok(pty) => pty,
            Err(err) => {
                let message = format!("\x1b[31mFailed to start: {err}\x1b[0m\r\n");
                self.terminal.write(message.as_bytes());
                self.exited = true;
                return;
            }
        };
        if let Some(layout) = self.layout {
            let (cell_w, cell_h) = layout.cell_px();
            pty.resize(layout.cols, layout.rows, cell_w, cell_h);
        }
        self.pty = Some(pty);
        self.exited = false;
        cx.emit(TerminalEvent::Started);

        self._io_task = cx.spawn(async move |this, cx| {
            while let Some(first) = events.next().await {
                // Drain whatever else is queued so a burst of output costs one repaint.
                let mut batch = vec![first];
                while batch.len() < 256 {
                    match events.try_recv() {
                        Ok(event) => batch.push(event),
                        Err(_) => break,
                    }
                }
                if this
                    .update(cx, |view, cx| view.handle_pty_events(batch, cx))
                    .is_err()
                {
                    break;
                }
            }
        });
    }

    /// Start the shell (or program) again, where the shell last was.
    pub fn restart(&mut self, cx: &mut Context<Self>) {
        if let Some(cwd) = self.assist.cwd() {
            self.start_dir = Some(PathBuf::from(cwd));
        }
        self.pty = None;
        self.assist = PromptAssist::default();
        self.terminal.reset();
        self.apply_settings(cx);
        self.start(cx);
        cx.notify();
    }

    /// What it runs from the next (re)start on, e.g. once a vault key became available.
    pub fn set_launch(&mut self, launch: Launch) {
        self.launch = launch;
    }

    /// Whether the shell (or program) is running.
    pub fn is_running(&self) -> bool {
        !self.exited
    }

    /// Start it if it is not running (output so far is cleared).
    pub fn start_if_stopped(&mut self, cx: &mut Context<Self>) {
        if self.exited {
            self.restart(cx);
        }
    }

    /// Ask it to stop like Ctrl-C does; kill it if it is still running a few seconds later.
    pub fn stop(&mut self, cx: &mut Context<Self>) {
        if self.exited || self.stopping {
            return;
        }
        self.stopping = true;
        self.send_to_pty(b"\x03");
        self._stop_task = cx.spawn(async move |this, cx| {
            cx.background_executor().timer(Duration::from_secs(3)).await;
            let _ = this.update(cx, |this, _| {
                if this.stopping {
                    // Dropping the PTY kills the process; its exit arrives as usual.
                    this.pty = None;
                }
            });
        });
        cx.notify();
    }

    fn handle_pty_events(&mut self, events: Vec<PtyEvent>, cx: &mut Context<Self>) {
        for event in events {
            match event {
                PtyEvent::Output(bytes) => {
                    for segment in self.marks.feed(&bytes) {
                        match segment {
                            Segment::Output(output) => {
                                self.terminal.write(&output);
                                if self.cursor_hidden_until.is_some() {
                                    self.hide_cursor_while_busy(cx);
                                }
                            }
                            Segment::Mark(ShellMark::Command(command)) => {
                                self.hide_cursor_while_busy(cx);
                                self.assist.command_started(command);
                                cx.emit(TerminalEvent::CommandStarted);
                            }
                            Segment::Mark(ShellMark::Prompt { status, cwd }) => {
                                self.show_cursor(cx);
                                let start = self.terminal.cursor_anchor().ok();
                                let assist = &mut self.assist;
                                cx.update_global::<History, _>(|history, _| {
                                    assist.prompt_ready(status, cwd, start, history);
                                });
                                cx.emit(TerminalEvent::PromptReady);
                            }
                            Segment::Mark(ShellMark::Path(path)) => self.assist.set_path(path),
                        }
                    }
                }
                PtyEvent::Exited(code) => {
                    self.pty = None;
                    self.exited = true;
                    let stopped = std::mem::take(&mut self.stopping);
                    self._stop_task = Task::ready(());
                    let again = match &self.launch {
                        Launch::Shell => "restart",
                        Launch::Program { again, .. } => again,
                    };
                    let message = if stopped {
                        format!("\r\n\x1b[2m[Stopped. Press Enter to {again}.]\x1b[0m\r\n")
                    } else {
                        let status =
                            code.map_or_else(|| "unknown".to_owned(), |code| code.to_string());
                        format!(
                            "\r\n\x1b[2m[Process exited with code {status}. Press Enter to {again}.]\x1b[0m\r\n"
                        )
                    };
                    self.terminal.write(message.as_bytes());
                    cx.emit(TerminalEvent::Exited { code, stopped });
                }
            }
        }

        self.track_synchronized_output(cx);
        let effects = self.terminal.take_effects();
        self.send_to_pty(&effects.replies);
        if let Some(title) = effects.title {
            self.title = title.into();
            cx.emit(TerminalEvent::TitleChanged);
        }
        if let Some(text) = effects.clipboard {
            cx.write_to_clipboard(ClipboardItem::new_string(text));
        }
        if effects.bell && TerminalSettings::get(cx).visual_bell {
            self.flash_bell(cx);
        }
        self.refresh_assist(cx);
        cx.notify();
    }

    /// Re-read the command line after the shell echoed something, updating the inline
    /// suggestion and the completion menu.
    fn refresh_assist(&mut self, cx: &mut Context<Self>) {
        if !self.assist.is_at_prompt() || self.holding_frame() {
            return;
        }
        if let Err(err) = self.terminal.sync() {
            eprintln!("failed to read terminal render state: {err:?}");
            return;
        }
        let settings = TerminalSettings::get(cx);
        let (suggestions, as_you_type) =
            (settings.autosuggestions, settings.completions_as_you_type);
        let history = cx.global::<History>();
        self.assist
            .refresh(&self.terminal, history, suggestions, as_you_type);
    }

    /// Replace the partial word with a completion (typing only the missing part when possible).
    fn accept_completion(&mut self, candidate: Candidate, word: &str, cx: &mut Context<Self>) {
        let mut bytes = Vec::new();
        match candidate.replacement.strip_prefix(word) {
            Some(rest) => bytes.extend_from_slice(rest.as_bytes()),
            None => {
                let Ok(backspace) = self.terminal.encode_key(&KeyInput::named(Key::Backspace))
                else {
                    return;
                };
                bytes.extend(backspace.repeat(word.chars().count()));
                bytes.extend_from_slice(candidate.replacement.as_bytes());
            }
        }
        bytes.extend_from_slice(candidate.suffix().as_bytes());
        self.assist.close_menu();
        if candidate.kind == completion::Kind::Directory {
            self.assist.reopen_menu_after_echo();
        }
        self.send_input(&bytes, cx);
    }

    fn accept_menu_selection(&mut self, index: Option<usize>, cx: &mut Context<Self>) {
        let Some(menu) = self.assist.menu.as_mut() else {
            return;
        };
        if let Some(index) = index {
            menu.selected = index;
        }
        let word = menu.completions.word.clone();
        if let Some(candidate) = menu.selected_candidate().cloned() {
            self.accept_completion(candidate, &word, cx);
        }
    }

    /// Tab at the prompt: complete a single match directly, otherwise open the menu. Returns
    /// `false` when there is nothing to complete (the key then goes to the shell).
    fn complete_at_prompt(&mut self, cx: &mut Context<Self>) -> bool {
        let history = cx.global::<History>();
        let Some(completions) = self.assist.complete_current(history) else {
            return false;
        };
        match completions.candidates.len() {
            0 => false,
            1 => {
                let candidate = completions.candidates[0].clone();
                self.accept_completion(candidate, &completions.word, cx);
                true
            }
            _ => {
                self.assist.open_menu(completions);
                cx.notify();
                true
            }
        }
    }

    /// Type (part of) the inline history suggestion.
    fn accept_suggestion(&mut self, whole: bool, cx: &mut Context<Self>) -> bool {
        let Some(suggestion) = self.assist.suggestion() else {
            return false;
        };
        let text = if whole {
            suggestion
        } else {
            assist::next_word(suggestion)
        }
        .to_owned();
        self.send_input(text.as_bytes(), cx);
        true
    }

    /// Put a command on the prompt (replacing what was typed), optionally running it.
    pub fn insert_command(&mut self, command: &str, run: bool, cx: &mut Context<Self>) {
        if self.exited {
            return;
        }
        // End of line, then kill the line (works in zsh, bash and fish).
        let mut bytes = b"\x05\x15".to_vec();
        match self.terminal.encode_paste(command) {
            Ok(paste) => bytes.extend(paste),
            Err(err) => {
                eprintln!("failed to encode command: {err:?}");
                return;
            }
        }
        if run {
            bytes.push(b'\r');
        }
        self.send_input(&bytes, cx);
        if run {
            self.assist.command_started(command.to_owned());
            self.hide_cursor_while_busy(cx);
        }
    }

    fn show_history(&mut self, _: &ShowHistory, window: &mut Window, cx: &mut Context<Self>) {
        if self.at_prompt() {
            history_panel::open(window, cx);
            return;
        }
        // Full-screen apps (vim's redo, etc.) keep Ctrl+R.
        let key = KeyInput {
            text: Some("r".into()),
            unshifted: Some('r'),
            ..key_with(Key::R, Mods::CTRL)
        };
        if let Ok(bytes) = self.terminal.encode_key(&key) {
            self.send_input(&bytes, cx);
        }
    }

    /// Applications wrap full-screen redraws in synchronized-update mode; hold frames until the
    /// update ends (or times out) so a half-drawn screen is never shown.
    fn track_synchronized_output(&mut self, cx: &mut Context<Self>) {
        if !self.terminal.is_synchronized_output() {
            self.sync_output_since = None;
            return;
        }
        if self.sync_output_since.is_some() {
            return;
        }
        self.sync_output_since = Some(Instant::now());
        self._sync_output_task = cx.spawn(async move |this, cx| {
            cx.background_executor().timer(SYNC_OUTPUT_TIMEOUT).await;
            let _ = this.update(cx, |_, cx| cx.notify());
        });
    }

    /// Whether to keep showing the previous frame for an in-progress synchronized update.
    fn holding_frame(&self) -> bool {
        self.sync_output_since.is_some_and(|since| {
            since.elapsed() < SYNC_OUTPUT_TIMEOUT && self.terminal.is_synchronized_output()
        })
    }

    /// Type a command at the prompt and run it (replacing any partially typed line).
    pub fn run_command(&mut self, command: &str, cx: &mut Context<Self>) {
        if self.exited {
            return;
        }
        let mut bytes = b"\x15".to_vec();
        bytes.extend_from_slice(command.as_bytes());
        bytes.push(b'\r');
        self.send_input(&bytes, cx);
        self.hide_cursor_while_busy(cx);
    }

    /// Hide the cursor while a command runs so it doesn't visibly jump from the line below the
    /// command to the end of its output. Each burst of output extends the hidden period.
    fn hide_cursor_while_busy(&mut self, cx: &mut Context<Self>) {
        self.cursor_hidden_until = Some(Instant::now() + CURSOR_SETTLE);
        self._cursor_task = cx.spawn(async move |this, cx| {
            cx.background_executor().timer(CURSOR_SETTLE).await;
            let _ = this.update(cx, |this, cx| {
                if this
                    .cursor_hidden_until
                    .is_some_and(|until| Instant::now() >= until)
                {
                    this.cursor_hidden_until = None;
                    cx.notify();
                }
            });
        });
    }

    fn show_cursor(&mut self, cx: &mut Context<Self>) {
        if self.cursor_hidden_until.take().is_some() {
            self._cursor_task = Task::ready(());
            self.reset_blink(cx);
        }
    }

    fn cursor_hidden(&self) -> bool {
        self.cursor_hidden_until
            .is_some_and(|until| Instant::now() < until)
    }

    fn send_to_pty(&self, bytes: &[u8]) {
        if let Some(pty) = &self.pty {
            pty.write(bytes);
        }
    }

    /// Send user input: snaps the viewport back to the live screen and drops the selection.
    fn send_input(&mut self, bytes: &[u8], cx: &mut Context<Self>) {
        if bytes.is_empty() {
            return;
        }
        self.terminal.scroll_to_bottom();
        self.terminal.clear_input_selection();
        self.terminal.clear_selection();
        self.send_to_pty(bytes);
        // Typing (e.g. into a running program) always brings the cursor back.
        self.show_cursor(cx);
        self.reset_blink(cx);
        cx.notify();
    }

    /// Whether a shell prompt (rather than a full-screen or mouse-driven app) has the keyboard.
    fn at_prompt(&self) -> bool {
        !self.exited && !self.terminal.is_alternate_screen() && !self.terminal.is_mouse_tracking()
    }

    /// Bytes that delete the keyboard selection, or nothing when there is none.
    fn take_selection_deletion(&mut self) -> Vec<u8> {
        match self.terminal.take_input_selection_deletion() {
            Ok(bytes) => bytes.unwrap_or_default(),
            Err(err) => {
                eprintln!("failed to delete selection: {err:?}");
                Vec::new()
            }
        }
    }

    /// Run a line-editing command: readline/zle bytes at the prompt, the equivalent key otherwise.
    fn edit(
        &mut self,
        at_prompt: &'static [u8],
        app_key: Option<KeyInput>,
        cx: &mut Context<Self>,
    ) {
        if self.at_prompt() {
            self.send_input(at_prompt, cx);
        } else if let Some(key) = app_key {
            match self.terminal.encode_key(&key) {
                Ok(bytes) => self.send_input(&bytes, cx),
                Err(err) => eprintln!("failed to encode key: {err:?}"),
            }
        }
    }

    /// Extend the keyboard selection by moving the shell cursor; full-screen apps get the key.
    fn select(&mut self, motion: SelectMotion, cx: &mut Context<Self>) {
        if !self.at_prompt() {
            match self.terminal.encode_key(&motion.app_key()) {
                Ok(bytes) => self.send_input(&bytes, cx),
                Err(err) => eprintln!("failed to encode key: {err:?}"),
            }
            return;
        }
        self.terminal.scroll_to_bottom();
        if let Err(err) = self.terminal.begin_input_selection() {
            eprintln!("failed to start selection: {err:?}");
            return;
        }
        let bytes = match motion {
            SelectMotion::Left => self.terminal.encode_key(&KeyInput::named(Key::ArrowLeft)),
            SelectMotion::Right => self.terminal.encode_key(&KeyInput::named(Key::ArrowRight)),
            SelectMotion::WordLeft => Ok(b"\x1bb".to_vec()),
            SelectMotion::WordRight => Ok(b"\x1bf".to_vec()),
            SelectMotion::LineStart => Ok(b"\x01".to_vec()),
            SelectMotion::LineEnd => Ok(b"\x05".to_vec()),
        };
        match bytes {
            Ok(bytes) => self.send_to_pty(&bytes),
            Err(err) => eprintln!("failed to encode selection motion: {err:?}"),
        }
        self.reset_blink(cx);
        cx.notify();
    }

    /// Apply the grid geometry computed by the element, resizing the VT grid and PTY on change.
    fn apply_layout(&mut self, layout: GridLayout) {
        self.layout = Some(layout);
        let (cell_w, cell_h) = layout.cell_px();
        match self
            .terminal
            .resize(layout.cols, layout.rows, cell_w, cell_h)
        {
            Ok(true) => {
                if let Some(pty) = &self.pty {
                    pty.resize(layout.cols, layout.rows, cell_w, cell_h);
                }
            }
            Ok(false) => {}
            Err(err) => eprintln!(
                "terminal resize to {}x{} failed: {err:?}",
                layout.cols, layout.rows
            ),
        }
    }

    fn focus_changed(&mut self, focused: bool, cx: &mut Context<Self>) {
        self.focused = focused;
        if focused {
            cx.set_global(ActiveTerminal(cx.entity().downgrade()));
            cx.emit(TerminalEvent::Focused);
        }
        if let Some(report) = self.terminal.encode_focus(focused) {
            self.send_to_pty(&report);
        }
        self.reset_blink(cx);
        cx.notify();
    }

    fn reset_blink(&mut self, cx: &mut Context<Self>) {
        self.cursor_on = true;
        self._blink_task = cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor().timer(BLINK_INTERVAL).await;
                if this.update(cx, |this, cx| this.blink(cx)).is_err() {
                    break;
                }
            }
        });
    }

    fn blink(&mut self, cx: &mut Context<Self>) {
        let blinking = self.focused
            && self
                .terminal
                .frame()
                .cursor
                .is_some_and(|cursor| cursor.blinking);
        if blinking {
            self.cursor_on = !self.cursor_on;
            cx.notify();
        } else if !self.cursor_on {
            self.cursor_on = true;
            cx.notify();
        }
    }

    fn flash_bell(&mut self, cx: &mut Context<Self>) {
        self.bell_flash = true;
        self._bell_task = cx.spawn(async move |this, cx| {
            cx.background_executor().timer(BELL_DURATION).await;
            let _ = this.update(cx, |this, cx| {
                this.bell_flash = false;
                cx.notify();
            });
        });
    }

    // ----- keyboard -------------------------------------------------------------------------

    fn on_key_down(&mut self, event: &KeyDownEvent, _window: &mut Window, cx: &mut Context<Self>) {
        let keystroke = &event.keystroke;
        // Unbound Cmd chords belong to the application.
        if keystroke.modifiers.platform {
            return;
        }
        if self.exited {
            if keystroke.key == "enter" {
                self.restart(cx);
            }
            cx.stop_propagation();
            return;
        }
        let option_as_alt = TerminalSettings::get(cx).option_as_alt;
        // Plain text arrives through the input handler (`replace_text_in_range`).
        let Some(key) = input::key_input(keystroke, event.is_held, option_as_alt) else {
            return;
        };
        cx.stop_propagation();

        if !self.at_prompt() {
            match self.terminal.encode_key(&key) {
                Ok(bytes) => self.send_input(&bytes, cx),
                Err(err) => eprintln!("failed to encode {keystroke}: {err:?}"),
            }
            return;
        }

        if self.terminal.has_input_selection() {
            match key.key {
                // Backspace/Delete remove the selection, like in an editor.
                Key::Backspace | Key::Delete => {
                    let deletion = self.take_selection_deletion();
                    self.send_input(&deletion, cx);
                    return;
                }
                Key::Escape => {
                    self.terminal.clear_input_selection();
                    cx.notify();
                    return;
                }
                _ => {}
            }
        }

        let plain = key.mods.is_empty();
        if let Some(menu) = self.assist.menu.as_mut() {
            match key.key {
                Key::ArrowUp if plain => {
                    menu.move_selection(-1);
                    cx.notify();
                    return;
                }
                Key::Tab if key.mods == Mods::SHIFT => {
                    menu.move_selection(-1);
                    cx.notify();
                    return;
                }
                Key::ArrowDown if plain => {
                    menu.move_selection(1);
                    cx.notify();
                    return;
                }
                Key::Tab | Key::Enter if plain => {
                    self.accept_menu_selection(None, cx);
                    return;
                }
                Key::Escape => {
                    self.assist.close_menu();
                    cx.notify();
                    return;
                }
                _ => {}
            }
        }
        let settings = TerminalSettings::get(cx);
        if key.key == Key::Tab
            && plain
            && settings.tab_completions
            && self.assist.is_at_prompt()
            && self.complete_at_prompt(cx)
        {
            return;
        }
        let accepts_suggestion = (plain && matches!(key.key, Key::ArrowRight | Key::End))
            || (key.key == Key::F && key.mods == Mods::CTRL);
        if accepts_suggestion && self.accept_suggestion(true, cx) {
            return;
        }

        let runs_command = key.key == Key::Enter;
        if runs_command {
            self.assist.enter_pressed();
        }
        let bytes = match input::prompt_key(key) {
            PromptKey::Send(key) => self.terminal.encode_key(&key),
            PromptKey::Bytes(bytes) => Ok(bytes.to_vec()),
            PromptKey::ScrollPage { up } => {
                self.scroll_page(up, cx);
                return;
            }
            PromptKey::Ignore => return,
        };
        match bytes {
            Ok(bytes) => {
                self.send_input(&bytes, cx);
                if runs_command {
                    self.hide_cursor_while_busy(cx);
                }
            }
            Err(err) => eprintln!("failed to encode {keystroke}: {err:?}"),
        }
    }

    fn cut(&mut self, _: &Cut, _window: &mut Window, cx: &mut Context<Self>) {
        self.copy_selection(cx);
        if self.terminal.has_input_selection() {
            let deletion = self.take_selection_deletion();
            self.send_input(&deletion, cx);
        }
    }

    fn copy(&mut self, _: &Copy, _window: &mut Window, cx: &mut Context<Self>) {
        self.copy_selection(cx);
    }

    fn copy_selection(&self, cx: &mut Context<Self>) {
        if let Some(text) = self.terminal.selection_text() {
            cx.write_to_clipboard(ClipboardItem::new_string(text));
        }
    }

    fn paste(&mut self, _: &Paste, window: &mut Window, cx: &mut Context<Self>) {
        let Some(text) = cx.read_from_clipboard().and_then(|item| item.text()) else {
            return;
        };
        if TerminalSettings::get(cx).paste_protection && !self.terminal.is_paste_safe(&text) {
            self.confirm_paste(text, window, cx);
        } else {
            self.paste_text(&text, cx);
        }
    }

    fn paste_text(&mut self, text: &str, cx: &mut Context<Self>) {
        let mut bytes = self.take_selection_deletion();
        match self.terminal.encode_paste(text) {
            Ok(paste) => {
                bytes.extend(paste);
                self.send_input(&bytes, cx);
            }
            Err(err) => eprintln!("failed to encode paste: {err:?}"),
        }
    }

    fn confirm_paste(&mut self, text: String, window: &mut Window, cx: &mut Context<Self>) {
        let view = cx.entity().downgrade();
        let lines = text.lines().count();
        window.open_alert_dialog(cx, move |alert, _, _| {
            let view = view.clone();
            let text = text.clone();
            alert
                .title("Paste potentially unsafe text?")
                .description(format!(
                    "The clipboard contains {lines} line(s) or control characters that may run \
                     commands immediately."
                ))
                .ok_text("Paste")
                .show_cancel(true)
                .on_ok(move |_, _, cx| {
                    let _ = view.update(cx, |view, cx| view.paste_text(&text, cx));
                    true
                })
        });
    }

    fn select_all(&mut self, _: &SelectAll, _window: &mut Window, cx: &mut Context<Self>) {
        if let Err(err) = self.terminal.select_all() {
            eprintln!("failed to select all: {err:?}");
        }
        cx.notify();
    }

    fn clear_screen(&mut self, _: &ClearScreen, _window: &mut Window, cx: &mut Context<Self>) {
        self.terminal.clear_screen_and_history();
        // Form feed makes the shell (or full-screen app) redraw its prompt/screen.
        self.send_input(b"\x0c", cx);
    }

    fn scroll_page(&mut self, up: bool, cx: &mut Context<Self>) {
        let page = self
            .layout
            .map_or(1, |layout| layout.rows.saturating_sub(1).max(1) as isize);
        self.terminal.scroll_viewport(if up { -page } else { page });
        cx.notify();
    }

    fn change_font_size(&mut self, delta: Option<f32>, cx: &mut Context<Self>) {
        let default = TerminalSettings::default().font_size;
        TerminalSettings::update(cx, |settings| {
            settings.font_size = delta.map_or(default, |delta| settings.font_size + delta);
        });
    }

    // ----- mouse ----------------------------------------------------------------------------

    /// Whether mouse events go to the application instead of driving local selection.
    fn reports_mouse(&self, modifiers: &Modifiers, cx: &App) -> bool {
        TerminalSettings::get(cx).mouse_reporting
            && !modifiers.shift
            && self.terminal.is_mouse_tracking()
    }

    fn on_mouse_down(
        &mut self,
        event: &MouseDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.focus_handle.focus(window, cx);
        self.terminal.clear_input_selection();
        let Some(layout) = self.layout else {
            return;
        };
        let (cell, surface) = layout.locate(event.position);
        self.mouse.last_position = Some(event.position);
        cx.stop_propagation();

        if self.reports_mouse(&event.modifiers, cx) {
            let mods = input::mods(&event.modifiers);
            match self.terminal.encode_mouse(
                mouse::Action::Press,
                Some(mouse_button(event.button)),
                surface,
                mods,
                true,
            ) {
                Ok(bytes) => self.send_to_pty(&bytes),
                Err(err) => eprintln!("failed to encode mouse press: {err:?}"),
            }
            self.mouse.reported_button = Some(event.button);
            return;
        }

        if event.button != MouseButton::Left {
            return;
        }
        match self
            .terminal
            .selection_press(cell, surface, self.epoch.elapsed())
        {
            Ok(()) => self.mouse.selecting = true,
            Err(err) => eprintln!("failed to start selection: {err:?}"),
        }
        cx.notify();
    }

    fn on_global_mouse_move(&mut self, event: &MouseMoveEvent, cx: &mut Context<Self>) {
        let Some(layout) = self.layout else {
            return;
        };
        self.mouse.last_position = Some(event.position);
        let (cell, surface) = layout.locate(event.position);

        if self.mouse.selecting {
            match self.terminal.selection_drag(cell, surface) {
                Ok(autoscroll) => self.update_autoscroll(autoscroll, cx),
                Err(err) => eprintln!("failed to extend selection: {err:?}"),
            }
            cx.notify();
            return;
        }

        let held = self.mouse.reported_button;
        let hovering = self.focused && layout.bounds.contains(&event.position);
        if (held.is_some() || hovering) && self.reports_mouse(&event.modifiers, cx) {
            let mods = input::mods(&event.modifiers);
            match self.terminal.encode_mouse(
                mouse::Action::Motion,
                held.map(mouse_button),
                surface,
                mods,
                held.is_some(),
            ) {
                Ok(bytes) => self.send_to_pty(&bytes),
                Err(err) => eprintln!("failed to encode mouse motion: {err:?}"),
            }
        }
    }

    fn on_global_mouse_up(&mut self, event: &MouseUpEvent, cx: &mut Context<Self>) {
        let Some(layout) = self.layout else {
            return;
        };
        let (cell, surface) = layout.locate(event.position);

        if let Some(button) = self
            .mouse
            .reported_button
            .filter(|button| *button == event.button)
        {
            self.mouse.reported_button = None;
            let mods = input::mods(&event.modifiers);
            match self.terminal.encode_mouse(
                mouse::Action::Release,
                Some(mouse_button(button)),
                surface,
                mods,
                false,
            ) {
                Ok(bytes) => self.send_to_pty(&bytes),
                Err(err) => eprintln!("failed to encode mouse release: {err:?}"),
            }
            return;
        }

        if !self.mouse.selecting || event.button != MouseButton::Left {
            return;
        }
        self.mouse.selecting = false;
        self.mouse.autoscrolling = false;
        self.mouse._autoscroll_task = None;
        match self.terminal.selection_release(cell) {
            Ok((1, false)) => {
                self.terminal.clear_selection();
                self.click_to_move(cell, cx);
            }
            Ok(_) => {
                if TerminalSettings::get(cx).copy_on_select {
                    self.copy_selection(cx);
                }
            }
            Err(err) => eprintln!("failed to finish selection: {err:?}"),
        }
        cx.notify();
    }

    fn click_to_move(&mut self, cell: GridPoint, cx: &mut Context<Self>) {
        let enabled = TerminalSettings::get(cx).click_to_move_cursor;
        let terminal = &self.terminal;
        if !enabled
            || self.exited
            || terminal.is_alternate_screen()
            || terminal.is_mouse_tracking()
            || terminal.is_scrolled_back()
        {
            return;
        }
        match self.terminal.click_to_move(cell) {
            Ok(Some(bytes)) => self.send_input(&bytes, cx),
            Ok(None) => {}
            Err(err) => eprintln!("failed to move cursor: {err:?}"),
        }
    }

    fn update_autoscroll(&mut self, autoscroll: SelectionAutoscroll, cx: &mut Context<Self>) {
        if autoscroll == SelectionAutoscroll::None || self.mouse.autoscrolling {
            return;
        }
        self.mouse.autoscrolling = true;
        self.mouse._autoscroll_task = Some(cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor().timer(AUTOSCROLL_INTERVAL).await;
                let keep_going = this
                    .update(cx, |view, cx| view.autoscroll_tick(cx))
                    .unwrap_or(false);
                if !keep_going {
                    break;
                }
            }
        }));
    }

    fn autoscroll_tick(&mut self, cx: &mut Context<Self>) -> bool {
        let (Some(layout), Some(position)) = (self.layout, self.mouse.last_position) else {
            self.mouse.autoscrolling = false;
            return false;
        };
        if !self.mouse.selecting {
            self.mouse.autoscrolling = false;
            return false;
        }
        let (cell, surface) = layout.locate(position);
        let keep_going = matches!(
            self.terminal.selection_autoscroll(cell, surface),
            Ok(SelectionAutoscroll::Up | SelectionAutoscroll::Down)
        );
        self.mouse.autoscrolling = keep_going;
        cx.notify();
        keep_going
    }

    fn on_scroll_wheel(
        &mut self,
        event: &ScrollWheelEvent,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(layout) = self.layout else {
            return;
        };
        if event.touch_phase == TouchPhase::Started {
            self.scroll_remainder = 0.;
        }
        let multiplier = TerminalSettings::get(cx).scroll_multiplier;
        let delta = event.delta.pixel_delta(layout.line_height);
        self.scroll_remainder += f32::from(delta.y) / f32::from(layout.line_height) * multiplier;
        let lines = self.scroll_remainder.trunc();
        self.scroll_remainder -= lines;
        cx.stop_propagation();
        if lines == 0. {
            return;
        }

        let (_, surface) = layout.locate(event.position);
        let mods = input::mods(&event.modifiers);
        let report = self.reports_mouse(&event.modifiers, cx);
        match self.terminal.wheel(lines as i32, surface, mods, report) {
            Ok(WheelOutcome::Report(bytes)) => self.send_to_pty(&bytes),
            Ok(WheelOutcome::Scrolled) => cx.notify(),
            Err(err) => eprintln!("failed to handle scroll: {err:?}"),
        }
    }

    fn cursor_bounds(&self) -> Option<Bounds<Pixels>> {
        let layout = self.layout?;
        let (col, row) = self
            .terminal
            .frame()
            .cursor
            .map_or((0, 0), |cursor| (cursor.col, cursor.row));
        Some(layout.cell_bounds(col, row, 1))
    }

    /// The completion menu, anchored under the word being completed (or above it when there is
    /// no room below).
    fn render_completion_menu(&self, cx: &mut Context<Self>) -> Option<impl IntoElement + use<>> {
        const VISIBLE: usize = 8;
        const ROW_HEIGHT: f32 = 26.;
        const CHROME: f32 = 34.;

        let menu = self.assist.menu.as_ref()?;
        let layout = self.layout?;
        let cursor = self.terminal.frame().cursor?;
        let theme = cx.theme();
        let font_family = SharedString::from(TerminalSettings::get(cx).font_family.clone());

        let count = menu.completions.candidates.len();
        let first = menu
            .selected
            .saturating_sub(VISIBLE - 1)
            .min(count.saturating_sub(VISIBLE));
        let visible = first..(first + VISIBLE).min(count);
        let height = px(visible.len() as f32 * ROW_HEIGHT + CHROME);
        let width = px(480.)
            .min(layout.bounds.size.width - px(16.))
            .max(px(200.));

        // Align with the start of the word being completed.
        let word_cells = menu.completions.word.chars().count() as u16;
        let cell = layout.cell_bounds(cursor.col.saturating_sub(word_cells), cursor.row, 1);
        let local = cell.origin - layout.bounds.origin;
        let below = local.y + layout.line_height + px(2.);
        let top = if below + height <= layout.bounds.size.height {
            below
        } else {
            (local.y - height - px(2.)).max(px(0.))
        };
        let left = local
            .x
            .min(layout.bounds.size.width - width - px(8.))
            .max(px(0.));

        let rows = visible.map(|index| {
            let candidate = &menu.completions.candidates[index];
            let selected = index == menu.selected;
            let (text_color, row_bg) = if selected {
                (theme.accent_foreground, theme.accent)
            } else {
                (theme.popover_foreground, theme.popover)
            };
            h_flex()
                .id(("completion", index))
                .h(px(ROW_HEIGHT))
                .px_2()
                .gap_2()
                .rounded_sm()
                .bg(row_bg)
                .text_color(text_color)
                .cursor_pointer()
                .on_mouse_down(
                    MouseButton::Left,
                    cx.listener(move |this, _: &MouseDownEvent, _, cx| {
                        cx.stop_propagation();
                        this.accept_menu_selection(Some(index), cx);
                    }),
                )
                .child(
                    Icon::new(candidate.kind.icon())
                        .small()
                        .text_color(if selected {
                            theme.accent_foreground
                        } else {
                            theme.muted_foreground
                        }),
                )
                .child(
                    h_flex()
                        .flex_none()
                        .font_family(font_family.clone())
                        .text_sm()
                        .children(highlight(
                            &candidate.display,
                            &candidate.positions,
                            theme.primary,
                        )),
                )
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .truncate()
                        .text_xs()
                        .text_right()
                        .text_color(theme.muted_foreground)
                        .child(candidate.description.clone().unwrap_or_default()),
                )
        });

        Some(
            v_flex()
                .absolute()
                .left(left)
                .top(top)
                .w(width)
                .p_1()
                .gap_0p5()
                .rounded_md()
                .border_1()
                .border_color(theme.border)
                .bg(theme.popover)
                .shadow_lg()
                .children(rows)
                .child(
                    h_flex()
                        .px_2()
                        .pt_1()
                        .gap_3()
                        .text_xs()
                        .text_color(theme.muted_foreground)
                        .child(div().flex_1().child(format!("{count} matches")))
                        .child(ui::key_hint(&["up", "down"], "choose"))
                        .child(ui::key_hint(&["tab"], "accept"))
                        .child(ui::key_hint(&["escape"], "close")),
                ),
        )
    }
}

/// Split `text` into spans, coloring the fuzzy-matched characters.
fn highlight(text: &str, positions: &[usize], color: Hsla) -> Vec<gpui::Div> {
    let mut spans = Vec::new();
    let mut current = String::new();
    let mut current_matched = false;
    for (index, ch) in text.chars().enumerate() {
        let matched = positions.contains(&index);
        if matched != current_matched && !current.is_empty() {
            spans.push(highlight_span(
                std::mem::take(&mut current),
                current_matched,
                color,
            ));
        }
        current_matched = matched;
        current.push(ch);
    }
    if !current.is_empty() {
        spans.push(highlight_span(current, current_matched, color));
    }
    spans
}

fn highlight_span(text: String, matched: bool, color: Hsla) -> gpui::Div {
    let span = div().whitespace_nowrap().child(text);
    if matched {
        span.text_color(color).font_weight(FontWeight::BOLD)
    } else {
        span
    }
}

impl Focusable for TerminalView {
    fn focus_handle(&self, _cx: &App) -> FocusHandle {
        self.focus_handle.clone()
    }
}

impl Render for TerminalView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let settings = TerminalSettings::get(cx);
        let background = hsla(self.terminal.frame().background).opacity(background_alpha(settings));
        let pointer = if self.terminal.is_mouse_tracking() && settings.mouse_reporting {
            CursorStyle::Arrow
        } else {
            match settings.pointer_style {
                PointerStyle::IBeam => CursorStyle::IBeam,
                PointerStyle::Arrow => CursorStyle::Arrow,
            }
        };

        div()
            .id("terminal")
            .relative()
            .key_context(CONTEXT)
            .track_focus(&self.focus_handle)
            .size_full()
            .overflow_hidden()
            .bg(background)
            .rounded_tl(self.corners.top_left)
            .rounded_tr(self.corners.top_right)
            .rounded_br(self.corners.bottom_right)
            .rounded_bl(self.corners.bottom_left)
            .cursor(pointer)
            .on_key_down(cx.listener(Self::on_key_down))
            .on_scroll_wheel(cx.listener(Self::on_scroll_wheel))
            .on_mouse_down(MouseButton::Left, cx.listener(Self::on_mouse_down))
            .on_mouse_down(MouseButton::Right, cx.listener(Self::on_mouse_down))
            .on_mouse_down(MouseButton::Middle, cx.listener(Self::on_mouse_down))
            .on_action(cx.listener(Self::copy))
            .on_action(cx.listener(Self::cut))
            .on_action(cx.listener(Self::paste))
            .on_action(cx.listener(Self::select_all))
            .on_action(cx.listener(Self::clear_screen))
            .on_action(
                cx.listener(|this, _: &SelectLeft, _, cx| this.select(SelectMotion::Left, cx)),
            )
            .on_action(
                cx.listener(|this, _: &SelectRight, _, cx| this.select(SelectMotion::Right, cx)),
            )
            .on_action(cx.listener(|this, _: &SelectWordLeft, _, cx| {
                this.select(SelectMotion::WordLeft, cx)
            }))
            .on_action(cx.listener(|this, _: &SelectWordRight, _, cx| {
                this.select(SelectMotion::WordRight, cx)
            }))
            .on_action(cx.listener(|this, _: &SelectToLineStart, _, cx| {
                this.select(SelectMotion::LineStart, cx)
            }))
            .on_action(cx.listener(|this, _: &SelectToLineEnd, _, cx| {
                this.select(SelectMotion::LineEnd, cx)
            }))
            .on_action(cx.listener(|this, _: &DeleteWordBackward, _, cx| {
                if this.at_prompt() && this.terminal.has_input_selection() {
                    let deletion = this.take_selection_deletion();
                    this.send_input(&deletion, cx);
                } else {
                    this.edit(b"\x1b\x7f", Some(key_with(Key::Backspace, Mods::ALT)), cx);
                }
            }))
            .on_action(cx.listener(|this, _: &DeleteWordForward, _, cx| {
                this.edit(b"\x1bd", Some(key_with(Key::Delete, Mods::ALT)), cx)
            }))
            .on_action(cx.listener(|this, _: &MoveWordBackward, _, cx| {
                this.edit(b"\x1bb", Some(key_with(Key::ArrowLeft, Mods::ALT)), cx)
            }))
            .on_action(cx.listener(|this, _: &MoveWordForward, _, cx| {
                if !this.accept_suggestion(false, cx) {
                    this.edit(b"\x1bf", Some(key_with(Key::ArrowRight, Mods::ALT)), cx)
                }
            }))
            .on_action(cx.listener(|this, _: &MoveToLineStart, _, cx| {
                this.edit(b"\x01", Some(KeyInput::named(Key::Home)), cx)
            }))
            .on_action(cx.listener(|this, _: &MoveToLineEnd, _, cx| {
                if !this.accept_suggestion(true, cx) {
                    this.edit(b"\x05", Some(KeyInput::named(Key::End)), cx)
                }
            }))
            .on_action(cx.listener(Self::show_history))
            .on_action(
                cx.listener(|this, _: &DeleteToLineStart, _, cx| this.edit(b"\x15", None, cx)),
            )
            .on_action(cx.listener(|this, _: &DeleteToLineEnd, _, cx| this.edit(b"\x0b", None, cx)))
            .on_action(cx.listener(|this, _: &ScrollPageUp, _, cx| this.scroll_page(true, cx)))
            .on_action(cx.listener(|this, _: &ScrollPageDown, _, cx| this.scroll_page(false, cx)))
            .on_action(cx.listener(|this, _: &ScrollToTop, _, cx| {
                this.terminal.scroll_to_top();
                cx.notify();
            }))
            .on_action(cx.listener(|this, _: &ScrollToBottom, _, cx| {
                this.terminal.scroll_to_bottom();
                cx.notify();
            }))
            .on_action(
                cx.listener(|this, _: &IncreaseFontSize, _, cx| {
                    this.change_font_size(Some(1.), cx)
                }),
            )
            .on_action(
                cx.listener(|this, _: &DecreaseFontSize, _, cx| {
                    this.change_font_size(Some(-1.), cx)
                }),
            )
            .on_action(
                cx.listener(|this, _: &ResetFontSize, _, cx| this.change_font_size(None, cx)),
            )
            .on_action(cx.listener(|this, _: &RestartShell, _, cx| this.restart(cx)))
            .child(TerminalElement {
                view: cx.entity(),
                focus_handle: self.focus_handle.clone(),
            })
            .children(self.render_completion_menu(cx))
    }
}

impl EntityInputHandler for TerminalView {
    fn text_for_range(
        &mut self,
        _range: Range<usize>,
        _adjusted_range: &mut Option<Range<usize>>,
        _window: &mut Window,
        _cx: &mut Context<Self>,
    ) -> Option<String> {
        None
    }

    fn selected_text_range(
        &mut self,
        _ignore_disabled_input: bool,
        _window: &mut Window,
        _cx: &mut Context<Self>,
    ) -> Option<UTF16Selection> {
        Some(UTF16Selection {
            range: 0..0,
            reversed: false,
        })
    }

    fn marked_text_range(
        &self,
        _window: &mut Window,
        _cx: &mut Context<Self>,
    ) -> Option<Range<usize>> {
        self.marked_text
            .as_ref()
            .map(|text| 0..text.encode_utf16().count())
    }

    fn unmark_text(&mut self, _window: &mut Window, cx: &mut Context<Self>) {
        if self.marked_text.take().is_some() {
            cx.notify();
        }
    }

    fn replace_text_in_range(
        &mut self,
        _range: Option<Range<usize>>,
        text: &str,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.marked_text = None;
        if !self.exited {
            // Typing over a keyboard selection replaces it.
            let mut bytes = self.take_selection_deletion();
            bytes.extend_from_slice(text.as_bytes());
            self.send_input(&bytes, cx);
        }
        cx.notify();
    }

    fn replace_and_mark_text_in_range(
        &mut self,
        _range: Option<Range<usize>>,
        new_text: &str,
        _new_selected_range: Option<Range<usize>>,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.marked_text = (!new_text.is_empty()).then(|| new_text.to_owned());
        cx.notify();
    }

    fn bounds_for_range(
        &mut self,
        _range_utf16: Range<usize>,
        _element_bounds: Bounds<Pixels>,
        _window: &mut Window,
        _cx: &mut Context<Self>,
    ) -> Option<Bounds<Pixels>> {
        self.cursor_bounds()
    }

    fn character_index_for_point(
        &mut self,
        _point: Point<Pixels>,
        _window: &mut Window,
        _cx: &mut Context<Self>,
    ) -> Option<usize> {
        None
    }
}

/// Custom element that lays out and paints the terminal grid on the GPU.
struct TerminalElement {
    view: Entity<TerminalView>,
    focus_handle: FocusHandle,
}

/// Everything computed in prepaint, ready to be emitted as GPU primitives.
struct GridPaint {
    line_height: Pixels,
    background: PaintQuad,
    cell_quads: Vec<PaintQuad>,
    text: Vec<(Point<Pixels>, ShapedLine)>,
    /// Box-drawing and block characters, drawn as shapes in their foreground color.
    shapes: Vec<(glyphs::Shape, Hsla)>,
    cursor_quad: Option<PaintQuad>,
    cursor_text: Option<(Point<Pixels>, ShapedLine)>,
    marked_text: Option<(PaintQuad, Point<Pixels>, ShapedLine)>,
    bell: Option<PaintQuad>,
}

/// Inputs that shape glyph runs.
struct TextContext<'a> {
    window: &'a Window,
    font: &'a Font,
    font_size: Pixels,
    layout: GridLayout,
}

impl TextContext<'_> {
    fn color(&self, style: &CellStyle) -> Hsla {
        if style.faint {
            hsla(style.fg).opacity(FAINT_ALPHA)
        } else {
            hsla(style.fg)
        }
    }

    fn run(&self, len: usize, style: &CellStyle) -> TextRun {
        let mut font = self.font.clone();
        if style.bold {
            font.weight = FontWeight::BOLD;
        }
        if style.italic {
            font.style = FontStyle::Italic;
        }
        let color = self.color(style);
        TextRun {
            len,
            font,
            color,
            background_color: None,
            underline: style.underline.map(|(kind, color)| UnderlineStyle {
                thickness: if kind == UnderlineKind::Double {
                    px(2.)
                } else {
                    px(1.)
                },
                color: Some(hsla(color)),
                wavy: kind == UnderlineKind::Curly,
            }),
            strikethrough: style.strikethrough.then(|| StrikethroughStyle {
                thickness: px(1.),
                color: Some(color),
            }),
        }
    }

    fn shape(&self, text: String, style: &CellStyle, cell_width: Option<Pixels>) -> ShapedLine {
        let run = self.run(text.len(), style);
        self.window.text_system().shape_line(
            SharedString::from(text),
            self.font_size,
            &[run],
            cell_width,
        )
    }
}

/// A horizontal run of same-styled narrow cells shaped as one line of text.
struct Batch {
    col: u16,
    cols: u16,
    text: String,
    style: CellStyle,
}

impl IntoElement for TerminalElement {
    type Element = Self;

    fn into_element(self) -> Self::Element {
        self
    }
}

impl Element for TerminalElement {
    type RequestLayoutState = ();
    type PrepaintState = GridPaint;

    fn id(&self) -> Option<ElementId> {
        None
    }

    fn source_location(&self) -> Option<&'static std::panic::Location<'static>> {
        None
    }

    fn request_layout(
        &mut self,
        _id: Option<&GlobalElementId>,
        _inspector_id: Option<&InspectorElementId>,
        window: &mut Window,
        cx: &mut App,
    ) -> (LayoutId, Self::RequestLayoutState) {
        let mut style = Style::default();
        style.size.width = relative(1.).into();
        style.size.height = relative(1.).into();
        (window.request_layout(style, [], cx), ())
    }

    fn prepaint(
        &mut self,
        _id: Option<&GlobalElementId>,
        _inspector_id: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        _request_layout: &mut Self::RequestLayoutState,
        window: &mut Window,
        cx: &mut App,
    ) -> Self::PrepaintState {
        let settings = TerminalSettings::get(cx).clone();
        let font = terminal_font(&settings);
        let font_size = px(settings.font_size);
        let layout = grid_layout(bounds, &font, &settings, window);
        let focused = self.focus_handle.is_focused(window);

        self.view.update(cx, |view, _cx| {
            let started = Instant::now();
            view.apply_layout(layout);
            if !view.holding_frame()
                && let Err(err) = view.terminal.sync()
            {
                eprintln!("failed to read terminal render state: {err:?}");
            }
            let synced = started.elapsed();
            let text = TextContext {
                window,
                font: &font,
                font_size,
                layout,
            };
            let options = PaintOptions {
                focused,
                cursor_visible: (view.cursor_on || !focused) && !view.cursor_hidden(),
                ghost: (!view.cursor_hidden() && view.marked_text.is_none())
                    .then(|| view.assist.suggestion().map(str::to_owned))
                    .flatten(),
                bell: view.bell_flash,
                background_alpha: background_alpha(&settings),
                corners: view.corners,
            };
            let paint = build_paint(
                view.terminal.frame(),
                &text,
                &options,
                view.marked_text.as_deref(),
            );
            let total = started.elapsed();
            if view.profile && total > SLOW_FRAME {
                eprintln!(
                    "slow frame: {total:?} (vt sync {synced:?}, layout {:?})",
                    total - synced
                );
            }
            paint
        })
    }

    fn paint(
        &mut self,
        _id: Option<&GlobalElementId>,
        _inspector_id: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        _request_layout: &mut Self::RequestLayoutState,
        paint: &mut Self::PrepaintState,
        window: &mut Window,
        cx: &mut App,
    ) {
        window.with_content_mask(Some(gpui::ContentMask { bounds }), |window| {
            window.paint_quad(paint.background.clone());
            for quad in paint.cell_quads.drain(..) {
                window.paint_quad(quad);
            }
            for (origin, line) in &paint.text {
                line.paint(
                    *origin,
                    paint.line_height,
                    TextAlign::Left,
                    None,
                    window,
                    cx,
                )
                .ok();
            }
            for (shape, color) in paint.shapes.drain(..) {
                match shape {
                    glyphs::Shape::Rect(bounds, alpha) => {
                        window.paint_quad(fill(bounds, color.opacity(color.a * alpha)))
                    }
                    glyphs::Shape::Path(path) => window.paint_path(path, color),
                }
            }
            if let Some(quad) = paint.cursor_quad.take() {
                window.paint_quad(quad);
            }
            if let Some((origin, line)) = &paint.cursor_text {
                line.paint(
                    *origin,
                    paint.line_height,
                    TextAlign::Left,
                    None,
                    window,
                    cx,
                )
                .ok();
            }
            if let Some((quad, origin, line)) = paint.marked_text.take() {
                window.paint_quad(quad);
                line.paint(origin, paint.line_height, TextAlign::Left, None, window, cx)
                    .ok();
            }
            if let Some(quad) = paint.bell.take() {
                window.paint_quad(quad);
            }
        });

        // Window-level listeners so drags and releases outside the grid still reach the view.
        let view = self.view.clone();
        window.on_mouse_event(move |event: &MouseMoveEvent, phase, _window, cx| {
            if phase == DispatchPhase::Bubble {
                view.update(cx, |view, cx| view.on_global_mouse_move(event, cx));
            }
        });
        let view = self.view.clone();
        window.on_mouse_event(move |event: &MouseUpEvent, phase, _window, cx| {
            if phase == DispatchPhase::Bubble {
                view.update(cx, |view, cx| view.on_global_mouse_up(event, cx));
            }
        });

        window.handle_input(
            &self.focus_handle,
            ElementInputHandler::new(bounds, self.view.clone()),
            cx,
        );
    }
}

struct PaintOptions {
    focused: bool,
    cursor_visible: bool,
    /// Inline history suggestion drawn faintly after the cursor.
    ghost: Option<String>,
    bell: bool,
    background_alpha: f32,
    corners: Corners<Pixels>,
}

fn terminal_font(settings: &TerminalSettings) -> Font {
    let mut font = font(SharedString::from(settings.font_family.clone()));
    if !settings.font_ligatures {
        font.features = FontFeatures::disable_ligatures();
    }
    font
}

fn background_alpha(settings: &TerminalSettings) -> f32 {
    match settings.background_effect {
        crate::settings::BackgroundEffect::Opaque => 1.,
        _ => settings.background_opacity,
    }
}

/// Derive cell metrics from the font and the number of rows/columns that fit in `bounds`.
fn grid_layout(
    bounds: Bounds<Pixels>,
    font: &Font,
    settings: &TerminalSettings,
    window: &Window,
) -> GridLayout {
    let font_size = px(settings.font_size);
    let text_system = window.text_system();
    let font_id = text_system.resolve_font(font);
    let advance = text_system
        .advance(font_id, font_size, 'm')
        .map(|advance| advance.width)
        .unwrap_or(font_size * 0.6);
    let cell_width = (advance + px(settings.letter_spacing)).max(px(1.));
    let scale = window.scale_factor();
    let snap = |value: Pixels| px((f32::from(value) * scale).round() / scale);
    let line_height = snap(font_size * settings.line_height).max(px(1.));
    let padding = settings.padding;

    let usable = |extent: Pixels| (f32::from(extent) - 2. * padding).max(0.);
    let cols = (usable(bounds.size.width) / f32::from(cell_width))
        .floor()
        .clamp(1., u16::MAX as f32);
    let rows = (usable(bounds.size.height) / f32::from(line_height))
        .floor()
        .clamp(1., u16::MAX as f32);

    GridLayout {
        bounds,
        origin: point(
            snap(bounds.origin.x + px(padding)),
            snap(bounds.origin.y + px(padding)),
        ),
        cell_width,
        line_height,
        cols: cols as u16,
        rows: rows as u16,
        scale,
    }
}

fn build_paint(
    frame: &Frame,
    text: &TextContext<'_>,
    options: &PaintOptions,
    marked_text: Option<&str>,
) -> GridPaint {
    let layout = text.layout;
    let mut paint = GridPaint {
        line_height: layout.line_height,
        background: fill(
            layout.bounds,
            hsla(frame.background).opacity(options.background_alpha),
        )
        .corner_radii(options.corners),
        cell_quads: Vec::new(),
        text: Vec::new(),
        shapes: Vec::new(),
        cursor_quad: None,
        cursor_text: None,
        marked_text: None,
        bell: options
            .bell
            .then(|| fill(layout.bounds, hsla(frame.foreground).opacity(0.12))),
    };

    let selection = hsla(frame.foreground).opacity(SELECTION_ALPHA);
    for (row, line) in frame
        .lines
        .iter()
        .enumerate()
        .take(usize::from(layout.rows))
    {
        let row = row as u16;
        push_runs(&mut paint.cell_quads, line, row, &layout, |cell| {
            cell.bg.map(hsla)
        });
        push_runs(&mut paint.cell_quads, line, row, &layout, |cell| {
            cell.selected.then_some(selection)
        });
        push_text(&mut paint.text, &mut paint.shapes, line, row, text);
    }

    if let (Some(ghost), Some(cursor)) = (&options.ghost, frame.cursor) {
        // Clip to the rest of the row; suggestions are hints, not wrapped text.
        let room = usize::from(frame.cols.saturating_sub(cursor.col));
        let visible: String = ghost.chars().take(room).collect();
        if !visible.is_empty() {
            let style = CellStyle {
                fg: frame.foreground,
                bold: false,
                italic: false,
                faint: true,
                strikethrough: false,
                underline: None,
            };
            let line = text.shape(visible, &style, Some(layout.cell_width));
            paint
                .text
                .push((layout.cell_origin(cursor.col, cursor.row), line));
        }
    }

    if let Some(cursor) = frame.cursor.filter(|_| options.cursor_visible) {
        let cell = frame
            .lines
            .get(usize::from(cursor.row))
            .and_then(|line| line.get(usize::from(cursor.col)));
        let (quad, glyph) = cursor_paint(&cursor, cell, frame, text, options.focused);
        paint.cursor_quad = Some(quad);
        paint.cursor_text = glyph;
    }

    if let Some(marked) = marked_text {
        let (col, row) = frame
            .cursor
            .map_or((0, 0), |cursor| (cursor.col, cursor.row));
        let style = CellStyle {
            fg: frame.foreground,
            bold: false,
            italic: false,
            faint: false,
            strikethrough: false,
            underline: Some((UnderlineKind::Single, frame.foreground)),
        };
        let line = text.shape(marked.to_owned(), &style, None);
        let origin = layout.cell_origin(col, row);
        let backdrop = fill(
            Bounds::new(
                origin,
                size(line.width.max(layout.cell_width), layout.line_height),
            ),
            hsla(frame.background),
        );
        paint.marked_text = Some((backdrop, origin, line));
    }

    paint
}

/// Merge horizontally adjacent cells that map to the same color into single quads.
fn push_runs(
    quads: &mut Vec<PaintQuad>,
    line: &[Cell],
    row: u16,
    layout: &GridLayout,
    color_of: impl Fn(&Cell) -> Option<Hsla>,
) {
    let mut run: Option<(u16, u16, Hsla)> = None;
    for (col, cell) in line.iter().enumerate() {
        let col = col as u16;
        let color = color_of(cell);
        match (run, color) {
            (Some((start, len, current)), Some(color))
                if current == color && start + len == col =>
            {
                run = Some((start, len + 1, current));
            }
            (_, color) => {
                if let Some((start, len, current)) = run.take() {
                    quads.push(fill(layout.cell_bounds(start, row, len), current));
                }
                run = color.map(|color| (col, 1, color));
            }
        }
    }
    if let Some((start, len, color)) = run {
        quads.push(fill(layout.cell_bounds(start, row, len), color));
    }
}

/// Batch runs of same-styled narrow cells into shaped lines; wide glyphs are shaped on their own,
/// and box-drawing and block characters become shapes.
fn push_text(
    out: &mut Vec<(Point<Pixels>, ShapedLine)>,
    shapes: &mut Vec<(glyphs::Shape, Hsla)>,
    line: &[Cell],
    row: u16,
    text: &TextContext<'_>,
) {
    let layout = text.layout;
    let mut batch: Option<Batch> = None;
    let flush = |batch: Option<Batch>, out: &mut Vec<(Point<Pixels>, ShapedLine)>| {
        if let Some(batch) = batch {
            debug_assert!(batch.cols > 0);
            let shaped = text.shape(batch.text, &batch.style, Some(layout.cell_width));
            out.push((layout.cell_origin(batch.col, row), shaped));
        }
    };

    for (col, cell) in line.iter().enumerate() {
        let col = col as u16;
        let decorated = cell.style.underline.is_some() || cell.style.strikethrough;
        if cell.width == 0 || (cell.text.is_empty() && !decorated) {
            if cell.width != 0 {
                flush(batch.take(), out);
            }
            continue;
        }
        let glyph = if cell.text.is_empty() {
            " "
        } else {
            cell.text.as_str()
        };

        let mut chars = glyph.chars();
        if let (Some(ch), None) = (chars.next(), chars.next())
            && glyphs::is_drawn(ch)
        {
            flush(batch.take(), out);
            let color = text.color(&cell.style);
            // Exact (unrounded) cell edges: `draw` snaps them, so neighbors share edges.
            let bounds = Bounds::new(
                layout.cell_origin(col, row),
                size(
                    layout.cell_width * f32::from(cell.width),
                    layout.line_height,
                ),
            );
            shapes.extend(
                glyphs::draw(ch, bounds, layout.scale)
                    .into_iter()
                    .map(|shape| (shape, color)),
            );
            continue;
        }

        if cell.width == 2 {
            flush(batch.take(), out);
            let shaped = text.shape(glyph.to_owned(), &cell.style, None);
            out.push((layout.cell_origin(col, row), shaped));
            continue;
        }

        match &mut batch {
            Some(current) if current.style == cell.style && current.col + current.cols == col => {
                current.text.push_str(glyph);
                current.cols += 1;
            }
            _ => {
                flush(batch.take(), out);
                batch = Some(Batch {
                    col,
                    cols: 1,
                    text: glyph.to_owned(),
                    style: cell.style,
                });
            }
        }
    }
    flush(batch, out);
}

fn cursor_paint(
    cursor: &Cursor,
    cell: Option<&Cell>,
    frame: &Frame,
    text: &TextContext<'_>,
    focused: bool,
) -> (PaintQuad, Option<(Point<Pixels>, ShapedLine)>) {
    let layout = text.layout;
    let color = hsla(cursor.color.unwrap_or(frame.foreground));
    let bounds = layout.cell_bounds(cursor.col, cursor.row, u16::from(cursor.width));
    let shape = match cursor.shape {
        CursorShape::Block if !focused => CursorShape::BlockHollow,
        shape => shape,
    };

    match shape {
        CursorShape::Block => {
            // Redraw the glyph under the block in the cell's background color so it stays legible.
            let glyph = cell.filter(|cell| !cell.text.is_empty()).map(|cell| {
                let style = CellStyle {
                    fg: cell.bg.unwrap_or(frame.background),
                    ..cell.style
                };
                let force_width = (cell.width == 1).then_some(layout.cell_width);
                let shaped = text.shape(cell.text.clone(), &style, force_width);
                (layout.cell_origin(cursor.col, cursor.row), shaped)
            });
            (fill(bounds, color), glyph)
        }
        CursorShape::BlockHollow => (outline(bounds, color, BorderStyle::Solid), None),
        CursorShape::Bar => {
            let width = if focused { px(2.) } else { px(1.) };
            let bar = Bounds::new(bounds.origin, size(width, bounds.size.height));
            (
                fill(bar, color.opacity(if focused { 1. } else { 0.6 })),
                None,
            )
        }
        CursorShape::Underline => {
            let underline = Bounds::new(
                point(
                    bounds.origin.x,
                    bounds.origin.y + bounds.size.height - px(2.),
                ),
                size(bounds.size.width, px(2.)),
            );
            (
                fill(underline, color.opacity(if focused { 1. } else { 0.6 })),
                None,
            )
        }
    }
}

fn mouse_button(button: MouseButton) -> mouse::Button {
    match button {
        MouseButton::Left => mouse::Button::Left,
        MouseButton::Right => mouse::Button::Right,
        MouseButton::Middle => mouse::Button::Middle,
        _ => mouse::Button::Unknown,
    }
}

fn luminance(color: Rgb) -> f32 {
    (0.2126 * f32::from(color.r) + 0.7152 * f32::from(color.g) + 0.0722 * f32::from(color.b)) / 255.
}

fn hsla(color: Rgb) -> Hsla {
    Rgba {
        r: f32::from(color.r) / 255.,
        g: f32::from(color.g) / 255.,
        b: f32::from(color.b) / 255.,
        a: 1.,
    }
    .into()
}

fn rgb_from_hsla(color: Hsla) -> Rgb {
    let rgba = Rgba::from(color);
    let channel = |value: f32| (value.clamp(0., 1.) * 255.).round() as u8;
    Rgb {
        r: channel(rgba.r),
        g: channel(rgba.g),
        b: channel(rgba.b),
    }
}
