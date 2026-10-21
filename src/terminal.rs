//! Safe, renderer-friendly wrapper around the `libghostty-vt` terminal state machine.
//!
//! [`Terminal`] owns the VT parser/grid plus the render-state iterators, input encoders and the
//! selection gesture. Rendering code never touches FFI types: [`Terminal::sync`] copies the visible
//! viewport into an owned [`Frame`], refreshing only the rows libghostty reports as dirty.

use std::{
    cell::{Cell as StdCell, RefCell},
    rc::Rc,
    time::Duration,
};

use libghostty_vt::{
    focus, key, mouse, paste,
    render::{
        CellIteration, CellIterator, Colors, CursorVisualStyle, Dirty, RenderState, RowIterator,
    },
    screen::{CellWide, Screen},
    selection::{
        FormatOptions, Selection,
        gesture::{
            Autoscroll, AutoscrollTickEvent, DragEvent, Geometry, Gesture, PressEvent, ReleaseEvent,
        },
    },
    style::{Palette, StyleColor, Underline},
    terminal::{
        ColorScheme, ConformanceLevel, CursorStyle, DeviceAttributeFeature, DeviceAttributes,
        DeviceType, Mode, Point, PointCoordinate, PrimaryDeviceAttributes, ScrollViewport,
        SecondaryDeviceAttributes, SizeReportSize,
    },
};

pub use libghostty_vt::Error;
pub use libghostty_vt::selection::gesture::Autoscroll as SelectionAutoscroll;
pub use libghostty_vt::style::RgbColor as Rgb;

pub type Result<T> = std::result::Result<T, Error>;

/// Maximum delay between clicks of a double/triple click.
const REPEAT_CLICK_INTERVAL: Duration = Duration::from_millis(500);

/// Initial terminal geometry and history size.
#[derive(Clone, Copy, Debug)]
pub struct TerminalConfig {
    pub cols: u16,
    pub rows: u16,
    pub scrollback: usize,
}

impl Default for TerminalConfig {
    fn default() -> Self {
        Self {
            cols: 80,
            rows: 24,
            scrollback: 10_000,
        }
    }
}

/// Underline shapes the renderer can distinguish.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UnderlineKind {
    Single,
    Double,
    Curly,
    Dotted,
    Dashed,
}

/// Fully resolved visual style of a cell: palette lookups and `inverse` are already applied.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CellStyle {
    pub fg: Rgb,
    pub bold: bool,
    pub italic: bool,
    pub faint: bool,
    pub strikethrough: bool,
    pub underline: Option<(UnderlineKind, Rgb)>,
}

/// One grid cell of the visible viewport.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Cell {
    /// Grapheme cluster to draw; empty for blank cells and wide-character spacers.
    pub text: String,
    /// Explicit background, `None` means the terminal default background.
    pub bg: Option<Rgb>,
    pub style: CellStyle,
    /// Columns occupied: 1 (narrow), 2 (wide) or 0 (spacer tail of a wide character).
    pub width: u8,
    /// Whether the cell is inside the active selection.
    pub selected: bool,
}

impl Cell {
    fn blank(fg: Rgb) -> Self {
        Self {
            text: String::new(),
            bg: None,
            style: CellStyle {
                fg,
                bold: false,
                italic: false,
                faint: false,
                strikethrough: false,
                underline: None,
            },
            width: 1,
            selected: false,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CursorShape {
    Block,
    BlockHollow,
    Bar,
    Underline,
}

impl From<CursorShape> for CursorStyle {
    fn from(shape: CursorShape) -> Self {
        match shape {
            CursorShape::Block => CursorStyle::Block,
            CursorShape::BlockHollow => CursorStyle::BlockHollow,
            CursorShape::Bar => CursorStyle::Bar,
            CursorShape::Underline => CursorStyle::Underline,
        }
    }
}

/// Cursor state in viewport coordinates.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Cursor {
    pub col: u16,
    pub row: u16,
    /// Cells covered by the cursor (2 when it sits on a wide character).
    pub width: u8,
    pub shape: CursorShape,
    pub blinking: bool,
    pub color: Option<Rgb>,
}

/// Owned snapshot of everything needed to paint the viewport.
#[derive(Clone, Debug)]
pub struct Frame {
    pub cols: u16,
    pub rows: u16,
    pub lines: Vec<Vec<Cell>>,
    /// `wrapped[row]` is true when that row soft-wraps into the next one.
    pub wrapped: Vec<bool>,
    pub cursor: Option<Cursor>,
    pub foreground: Rgb,
    pub background: Rgb,
    /// Incremented whenever any visible state changed.
    pub generation: u64,
}

impl Frame {
    fn empty() -> Self {
        Self {
            cols: 0,
            rows: 0,
            lines: Vec::new(),
            wrapped: Vec::new(),
            cursor: None,
            foreground: Rgb::default(),
            background: Rgb::default(),
            generation: 0,
        }
    }
}

/// A grid position in viewport coordinates.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct GridPoint {
    pub col: u16,
    pub row: u16,
}

/// A position in absolute screen rows (scrollback + active area), stable while output scrolls.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ScreenPoint {
    pub col: u16,
    pub row: usize,
}

/// The command line typed at the prompt.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InputLine {
    pub text: String,
    /// Cursor position as a char index into `text`.
    pub cursor: usize,
}

impl InputLine {
    pub fn cursor_at_end(&self) -> bool {
        self.cursor >= self.text.chars().count()
    }

    /// The text before the cursor.
    pub fn before_cursor(&self) -> String {
        self.text.chars().take(self.cursor).collect()
    }
}

/// A pointer position in surface pixels (device pixels relative to the grid origin).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SurfacePoint {
    pub x: f32,
    pub y: f32,
}

/// A key press, already mapped to libghostty's logical key model.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KeyInput {
    pub key: key::Key,
    pub mods: key::Mods,
    /// Text produced by the key without Ctrl/Meta transformations (never a control character).
    pub text: Option<String>,
    /// The key's character with no modifiers applied, if it has one.
    pub unshifted: Option<char>,
    pub repeat: bool,
}

impl KeyInput {
    pub fn named(key: key::Key) -> Self {
        Self {
            key,
            mods: key::Mods::empty(),
            text: None,
            unshifted: None,
            repeat: false,
        }
    }
}

/// What a scroll-wheel gesture turned into.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WheelOutcome {
    /// Bytes for the host application (mouse report, or arrow keys in alternate-scroll mode).
    Report(Vec<u8>),
    /// The viewport was moved through scrollback locally.
    Scrolled,
}

/// Default colors applied to the terminal.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ColorConfig {
    pub foreground: Rgb,
    pub background: Rgb,
    pub cursor: Option<Rgb>,
    /// Overrides for the 16 ANSI colors; `None` keeps the built-in xterm palette.
    pub ansi: Option<[Rgb; 16]>,
}

/// Side effects the VT produced while processing output, to be handled by the embedder.
#[derive(Debug, Default)]
pub struct Effects {
    /// Replies to queries (device attributes, cursor position, ...) for the PTY.
    pub replies: Vec<u8>,
    pub bell: bool,
    pub title: Option<String>,
    /// Text an application asked to place on the clipboard (OSC 52).
    pub clipboard: Option<String>,
}

/// State shared with the libghostty callbacks, which run synchronously inside `vt_write`.
#[derive(Default)]
struct Shared {
    replies: RefCell<Vec<u8>>,
    bell: StdCell<bool>,
    title_changed: StdCell<bool>,
    clipboard: RefCell<Option<String>>,
    dark: StdCell<bool>,
    pixels: StdCell<PixelSize>,
}

/// Device-pixel geometry of one cell, used for mouse reports, size reports and selection.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct PixelSize {
    cell_width: u32,
    cell_height: u32,
}

pub struct Terminal {
    vt: libghostty_vt::Terminal<'static, 'static>,
    render: RenderState<'static>,
    row_iter: RowIterator<'static>,
    cell_iter: CellIterator<'static>,
    key_encoder: key::Encoder<'static>,
    key_event: key::Event<'static>,
    mouse_encoder: mouse::Encoder<'static>,
    mouse_event: mouse::Event<'static>,
    gesture: Gesture<'static>,
    press: PressEvent<'static>,
    drag: DragEvent<'static>,
    release: ReleaseEvent<'static>,
    autoscroll_tick: AutoscrollTickEvent<'static>,
    shared: Rc<Shared>,
    base_palette: Palette,
    bold_is_bright: bool,
    option_as_alt: bool,
    input_anchor: Option<InputAnchor>,
    /// Last (anchor, cursor) pair mirrored into the terminal selection.
    input_span_shown: Option<(GridPoint, GridPoint)>,
    frame: Frame,
}

/// Start of a keyboard selection: column and absolute screen row (scrollback + active row).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct InputAnchor {
    col: u16,
    row: usize,
}

impl Terminal {
    pub fn new(config: TerminalConfig) -> Result<Self> {
        let mut vt = libghostty_vt::Terminal::new(libghostty_vt::TerminalOptions {
            cols: config.cols.max(1),
            rows: config.rows.max(1),
            max_scrollback: config.scrollback,
        })?;
        let shared = Rc::new(Shared {
            dark: StdCell::new(true),
            ..Shared::default()
        });
        register_callbacks(&mut vt, &shared)?;
        let base_palette = vt.default_color_palette()?;

        Ok(Self {
            vt,
            render: RenderState::new()?,
            row_iter: RowIterator::new()?,
            cell_iter: CellIterator::new()?,
            key_encoder: key::Encoder::new()?,
            key_event: key::Event::new()?,
            mouse_encoder: mouse::Encoder::new()?,
            mouse_event: mouse::Event::new()?,
            gesture: Gesture::new()?,
            press: PressEvent::new()?,
            drag: DragEvent::new()?,
            release: ReleaseEvent::new()?,
            autoscroll_tick: AutoscrollTickEvent::new()?,
            shared,
            base_palette,
            bold_is_bright: false,
            option_as_alt: false,
            input_anchor: None,
            input_span_shown: None,
            frame: Frame::empty(),
        })
    }

    /// Feed raw VT-encoded bytes (program output) into the state machine.
    pub fn write(&mut self, bytes: &[u8]) {
        self.vt.vt_write(bytes);
    }

    /// Collect the side effects produced since the last call.
    pub fn take_effects(&mut self) -> Effects {
        let shared = &self.shared;
        Effects {
            replies: std::mem::take(&mut *shared.replies.borrow_mut()),
            bell: shared.bell.replace(false),
            title: shared
                .title_changed
                .replace(false)
                .then(|| self.vt.title().unwrap_or_default().to_owned()),
            clipboard: shared.clipboard.borrow_mut().take(),
        }
    }

    /// Full reset (RIS), used when restarting the shell.
    pub fn reset(&mut self) {
        self.vt.reset();
    }

    /// Apply default colors and the ANSI palette.
    pub fn set_colors(&mut self, colors: &ColorConfig) -> Result<()> {
        let mut palette = self.base_palette;
        if let Some(ansi) = colors.ansi {
            palette.0[..16].copy_from_slice(&ansi);
        }
        self.vt
            .set_default_fg_color(Some(colors.foreground))?
            .set_default_bg_color(Some(colors.background))?
            .set_default_cursor_color(colors.cursor)?
            .set_default_color_palette(Some(palette))?;
        Ok(())
    }

    /// Whether color-scheme queries (CSI ? 996 n) report a dark scheme.
    pub fn set_dark_mode(&mut self, dark: bool) {
        self.shared.dark.set(dark);
    }

    /// Render bold text in the bright variant of the 8 basic ANSI colors.
    pub fn set_bold_is_bright(&mut self, enabled: bool) {
        if self.bold_is_bright != enabled {
            self.bold_is_bright = enabled;
            self.frame.cols = 0; // force a full rebuild
        }
    }

    /// Treat the macOS Option key as Alt (ESC prefix) instead of a character modifier.
    pub fn set_option_as_alt(&mut self, enabled: bool) {
        self.option_as_alt = enabled;
    }

    /// Default cursor shape and blinking, unless an application overrides them (DECSCUSR).
    pub fn set_default_cursor(&mut self, shape: CursorShape, blink: bool) -> Result<()> {
        self.vt
            .set_default_cursor_style(Some(shape.into()))?
            .set_default_cursor_blink(Some(blink))?;
        Ok(())
    }

    pub fn size(&self) -> Result<(u16, u16)> {
        Ok((self.vt.cols()?, self.vt.rows()?))
    }

    /// Resize the grid. The primary screen reflows soft-wrapped lines.
    /// Returns `true` if the dimensions actually changed.
    pub fn resize(
        &mut self,
        cols: u16,
        rows: u16,
        cell_width_px: u32,
        cell_height_px: u32,
    ) -> Result<bool> {
        let (cols, rows) = (cols.max(1), rows.max(1));
        let pixels = PixelSize {
            cell_width: cell_width_px.max(1),
            cell_height: cell_height_px.max(1),
        };
        let changed = self.size()? != (cols, rows);
        if changed || pixels != self.shared.pixels.get() {
            self.vt
                .resize(cols, rows, pixels.cell_width, pixels.cell_height)?;
            self.shared.pixels.set(pixels);
        }
        Ok(changed)
    }

    /// Scroll the viewport through scrollback. Negative values scroll up (towards history).
    pub fn scroll_viewport(&mut self, lines: isize) {
        if lines != 0 {
            self.vt.scroll_viewport(ScrollViewport::Delta(lines));
        }
    }

    pub fn scroll_to_bottom(&mut self) {
        self.vt.scroll_viewport(ScrollViewport::Bottom);
    }

    pub fn scroll_to_top(&mut self) {
        self.vt.scroll_viewport(ScrollViewport::Top);
    }

    /// Whether the viewport is showing history rather than the live screen.
    pub fn is_scrolled_back(&self) -> bool {
        self.vt
            .scrollbar()
            .is_ok_and(|bar| bar.offset + bar.len < bar.total)
    }

    pub fn is_alternate_screen(&self) -> bool {
        self.vt
            .active_screen()
            .is_ok_and(|screen| screen == Screen::Alternate)
    }

    /// Whether the application is in the middle of a synchronized update (mode 2026).
    pub fn is_synchronized_output(&self) -> bool {
        self.vt.mode(Mode::SYNC_OUTPUT).unwrap_or(false)
    }

    pub fn is_mouse_tracking(&self) -> bool {
        self.vt.is_mouse_tracking().unwrap_or(false)
    }

    /// Erase the screen and scrollback, keeping the cursor line's content for the shell to redraw.
    pub fn clear_screen_and_history(&mut self) {
        self.vt.vt_write(b"\x1b[H\x1b[2J\x1b[3J");
    }

    /// Encode a key press into the byte sequence a host application expects, honoring the
    /// terminal's current modes (application cursor keys, keypad mode, kitty keyboard flags, ...).
    pub fn encode_key(&mut self, input: &KeyInput) -> Result<Vec<u8>> {
        let action = if input.repeat {
            key::Action::Repeat
        } else {
            key::Action::Press
        };
        // Shift is "consumed" when it already shaped the produced text (e.g. shift+1 -> "!").
        let shift_consumed = input.mods.contains(key::Mods::SHIFT)
            && match (&input.text, input.unshifted) {
                (Some(text), Some(unshifted)) => !text.starts_with(unshifted),
                _ => false,
            };
        let consumed = if shift_consumed {
            key::Mods::SHIFT
        } else {
            key::Mods::empty()
        };

        self.key_event
            .set_action(action)
            .set_key(input.key)
            .set_mods(input.mods)
            .set_consumed_mods(consumed)
            .set_composing(false)
            .set_utf8(input.text.clone())
            .set_unshifted_codepoint(input.unshifted.unwrap_or('\0'));

        let option_as_alt = if self.option_as_alt {
            key::OptionAsAlt::True
        } else {
            key::OptionAsAlt::False
        };
        let mut bytes = Vec::new();
        self.key_encoder
            .set_options_from_terminal(&self.vt)
            .set_macos_option_as_alt(option_as_alt)
            .encode_to_vec(&self.key_event, &mut bytes)?;
        Ok(bytes)
    }

    /// Encode pasted text, honoring bracketed-paste mode and stripping unsafe control bytes.
    pub fn encode_paste(&self, text: &str) -> Result<Vec<u8>> {
        let bracketed = self.vt.mode(Mode::BRACKETED_PASTE)?;
        let mut data = text.as_bytes().to_vec();
        let mut buf = vec![0u8; data.len() + 16];
        loop {
            match paste::encode(&mut data, bracketed, &mut buf) {
                Ok(len) => {
                    buf.truncate(len);
                    return Ok(buf);
                }
                Err(Error::OutOfSpace { required }) => buf.resize(required, 0),
                Err(err) => return Err(err),
            }
        }
    }

    /// Whether pasting `text` could execute commands without the user pressing Enter.
    pub fn is_paste_safe(&self, text: &str) -> bool {
        paste::is_safe(text) || self.vt.mode(Mode::BRACKETED_PASTE).unwrap_or(false)
    }

    /// Focus-in/out report (`CSI I` / `CSI O`) if the application enabled focus events.
    pub fn encode_focus(&self, focused: bool) -> Option<Vec<u8>> {
        if !self.vt.mode(Mode::FOCUS_EVENT).unwrap_or(false) {
            return None;
        }
        let event = if focused {
            focus::Event::Gained
        } else {
            focus::Event::Lost
        };
        let mut buf = [0u8; 8];
        let len = event.encode(&mut buf).ok()?;
        Some(buf[..len].to_vec())
    }

    /// Encode a mouse event for an application that enabled mouse tracking.
    /// Returns no bytes when the current tracking mode does not report this event.
    pub fn encode_mouse(
        &mut self,
        action: mouse::Action,
        button: Option<mouse::Button>,
        position: SurfacePoint,
        mods: key::Mods,
        any_button_pressed: bool,
    ) -> Result<Vec<u8>> {
        let (cols, rows) = self.size()?;
        let pixels = self.shared.pixels.get();
        self.mouse_encoder
            .set_options_from_terminal(&self.vt)
            .set_size(mouse::EncoderSize {
                screen_width: u32::from(cols) * pixels.cell_width,
                screen_height: u32::from(rows) * pixels.cell_height,
                cell_width: pixels.cell_width.max(1),
                cell_height: pixels.cell_height.max(1),
                padding_top: 0,
                padding_bottom: 0,
                padding_right: 0,
                padding_left: 0,
            })
            .set_any_button_pressed(any_button_pressed)
            .set_track_last_cell(true);
        self.mouse_event
            .set_action(action)
            .set_button(button)
            .set_mods(mods)
            .set_position(mouse::Position {
                x: position.x,
                y: position.y,
            });
        let mut bytes = Vec::new();
        self.mouse_encoder
            .encode_to_vec(&self.mouse_event, &mut bytes)?;
        Ok(bytes)
    }

    /// Translate a scroll-wheel gesture of `lines` (positive = up).
    ///
    /// Applications that track the mouse get wheel button reports (if `report_mouse`); full-screen
    /// applications on the alternate screen with alternate-scroll mode get arrow keys; otherwise
    /// the viewport is scrolled through local scrollback.
    pub fn wheel(
        &mut self,
        lines: i32,
        position: SurfacePoint,
        mods: key::Mods,
        report_mouse: bool,
    ) -> Result<WheelOutcome> {
        if lines == 0 {
            return Ok(WheelOutcome::Scrolled);
        }
        let mut bytes = Vec::new();

        if report_mouse && self.is_mouse_tracking() {
            let button = if lines > 0 {
                mouse::Button::Four
            } else {
                mouse::Button::Five
            };
            for _ in 0..lines.unsigned_abs() {
                bytes.extend(self.encode_mouse(
                    mouse::Action::Press,
                    Some(button),
                    position,
                    mods,
                    false,
                )?);
            }
            return Ok(WheelOutcome::Report(bytes));
        }

        if self.is_alternate_screen() && self.vt.mode(Mode::ALT_SCROLL)? {
            let arrow = KeyInput::named(if lines > 0 {
                key::Key::ArrowUp
            } else {
                key::Key::ArrowDown
            });
            for _ in 0..lines.unsigned_abs() {
                bytes.extend(self.encode_key(&arrow)?);
            }
            return Ok(WheelOutcome::Report(bytes));
        }

        self.scroll_viewport(-(lines as isize));
        Ok(WheelOutcome::Scrolled)
    }

    fn selection_geometry(&self) -> Result<Geometry> {
        let (cols, rows) = self.size()?;
        let pixels = self.shared.pixels.get();
        Ok(Geometry {
            columns: u32::from(cols),
            cell_width: pixels.cell_width.max(1),
            padding_left: 0,
            screen_height: (u32::from(rows) * pixels.cell_height).max(1),
        })
    }

    fn viewport_point(point: GridPoint) -> Point {
        Point::Viewport(PointCoordinate {
            x: point.col,
            y: u32::from(point.row),
        })
    }

    /// Start a selection gesture. Repeated presses within the click interval select words and lines.
    pub fn selection_press(
        &mut self,
        cell: GridPoint,
        position: SurfacePoint,
        time: Duration,
    ) -> Result<()> {
        let distance = f64::from(self.shared.pixels.get().cell_width.max(4));
        self.press
            .set_position(f64::from(position.x), f64::from(position.y))?
            .set_time(time)?
            .set_repeat_interval(REPEAT_CLICK_INTERVAL)?
            .set_repeat_distance(distance)?;
        let grid_ref = self.vt.grid_ref(Self::viewport_point(cell))?;
        let selection = self.press.apply(&mut self.gesture, &self.vt, grid_ref)?;
        self.vt.set_selection(selection.as_ref())?;
        Ok(())
    }

    /// Extend the active selection gesture; returns whether the viewport should autoscroll.
    pub fn selection_drag(
        &mut self,
        cell: GridPoint,
        position: SurfacePoint,
    ) -> Result<Autoscroll> {
        let geometry = self.selection_geometry()?;
        self.drag
            .set_position(f64::from(position.x), f64::from(position.y))?;
        let grid_ref = self.vt.grid_ref(Self::viewport_point(cell))?;
        if let Some(selection) = self
            .drag
            .apply(&mut self.gesture, &self.vt, grid_ref, geometry)?
        {
            self.vt.set_selection(Some(&selection))?;
        }
        self.gesture.autoscroll(&self.vt)
    }

    /// Scroll one line in the autoscroll direction and extend the selection to `cell`.
    pub fn selection_autoscroll(
        &mut self,
        cell: GridPoint,
        position: SurfacePoint,
    ) -> Result<Autoscroll> {
        match self.gesture.autoscroll(&self.vt)? {
            Autoscroll::Up => self.scroll_viewport(-1),
            Autoscroll::Down => self.scroll_viewport(1),
            other => return Ok(other),
        }
        let geometry = self.selection_geometry()?;
        self.autoscroll_tick
            .set_position(f64::from(position.x), f64::from(position.y))?;
        let viewport = PointCoordinate {
            x: cell.col,
            y: u32::from(cell.row),
        };
        if let Some(selection) =
            self.autoscroll_tick
                .apply(&mut self.gesture, &self.vt, viewport, geometry)?
        {
            self.vt.set_selection(Some(&selection))?;
        }
        self.gesture.autoscroll(&self.vt)
    }

    /// Finish the selection gesture. Returns `(click_count, dragged)` for the finished gesture.
    pub fn selection_release(&mut self, cell: GridPoint) -> Result<(u8, bool)> {
        let grid_ref = self.vt.grid_ref(Self::viewport_point(cell))?;
        self.release
            .apply(&mut self.gesture, &self.vt, Some(grid_ref))?;
        Ok((
            self.gesture.click_count(&self.vt)?,
            self.gesture.dragged(&self.vt)?,
        ))
    }

    pub fn clear_selection(&mut self) {
        if let Err(err) = self.vt.set_selection(None) {
            eprintln!("failed to clear selection: {err:?}");
        }
    }

    pub fn select_all(&mut self) -> Result<()> {
        let selection = self.vt.select_all()?;
        self.vt.set_selection(selection.as_ref())?;
        Ok(())
    }

    /// Plain-text contents of the active selection (soft wraps joined, trailing spaces trimmed).
    pub fn selection_text(&self) -> Option<String> {
        let options = FormatOptions::new().with_unwrap(true).with_trim(true);
        match self.vt.format_selection_alloc(None, options) {
            Ok(Some(bytes)) if !bytes.is_empty() => {
                Some(String::from_utf8_lossy(&bytes).into_owned())
            }
            Ok(_) => None,
            Err(err) => {
                eprintln!("failed to format selection: {err:?}");
                None
            }
        }
    }

    /// Signed number of cursor steps (characters, not cells) from `from` to `to`, if both lie on
    /// the same soft-wrapped logical line of the current frame. Positive means `to` is later.
    fn line_steps(&self, from: GridPoint, to: GridPoint) -> Option<isize> {
        let frame = &self.frame;
        let rows = usize::from(frame.rows);
        let (from_row, to_row) = (usize::from(from.row), usize::from(to.row));
        if from_row >= rows || to_row >= rows {
            return None;
        }
        let mut start = from_row;
        while start > 0 && frame.wrapped[start - 1] {
            start -= 1;
        }
        let mut end = from_row;
        while end + 1 < rows && frame.wrapped[end] {
            end += 1;
        }
        if !(start..=end).contains(&to_row) {
            return None;
        }

        let cols = usize::from(frame.cols);
        let last_col = frame.cols.saturating_sub(1);
        let offset = |row: usize, col: u16| (row - start) * cols + usize::from(col.min(last_col));
        let (a, b) = (offset(from_row, from.col), offset(to_row, to.col));
        let (lo, hi) = (a.min(b), a.max(b));
        let steps = (lo..hi)
            .filter(|&index| {
                let (row, col) = (start + index / cols, index % cols);
                frame.lines[row]
                    .get(col)
                    .is_some_and(|cell| cell.width != 0)
            })
            .count() as isize;
        Some(if b >= a { steps } else { -steps })
    }

    /// Arrow-key bytes that move the cursor by `steps` characters (negative = left).
    fn arrow_steps(&mut self, steps: isize) -> Result<Vec<u8>> {
        let arrow = KeyInput::named(if steps > 0 {
            key::Key::ArrowRight
        } else {
            key::Key::ArrowLeft
        });
        Ok(self.encode_key(&arrow)?.repeat(steps.unsigned_abs()))
    }

    /// Arrow-key bytes that move the shell's cursor to `target`, if it lies on the cursor's
    /// logical (soft-wrapped) line. Wide characters count as one cursor step.
    pub fn click_to_move(&mut self, target: GridPoint) -> Result<Option<Vec<u8>>> {
        let Some(cursor) = self.frame.cursor else {
            return Ok(None);
        };
        let from = GridPoint {
            col: cursor.col,
            row: cursor.row,
        };
        match self.line_steps(from, target) {
            Some(steps) if steps != 0 => Ok(Some(self.arrow_steps(steps)?)),
            _ => Ok(None),
        }
    }

    // ----- the command line being typed ------------------------------------------------------

    /// Where the cursor is, in absolute screen rows (stable while output scrolls).
    pub fn cursor_anchor(&self) -> Result<ScreenPoint> {
        Ok(ScreenPoint {
            col: self.vt.cursor_x()?,
            row: self.vt.scrollback_rows()? + usize::from(self.vt.cursor_y()?),
        })
    }

    /// The text typed after a prompt that ended at `start`, read from the current frame.
    ///
    /// Covers the prompt's soft-wrapped line; a right-side prompt (separated by a wide gap after
    /// the cursor) is cut off. Returns `None` when the prompt is not on screen.
    pub fn prompt_input(&self, start: ScreenPoint) -> Option<InputLine> {
        if self.is_scrolled_back() || self.is_alternate_screen() {
            return None;
        }
        let frame = &self.frame;
        let row = start.row.checked_sub(self.vt.scrollback_rows().ok()?)?;
        if row >= frame.lines.len() {
            return None;
        }
        let cursor = frame.cursor?;
        let mut text = String::new();
        let mut cursor_index = None;
        let mut chars = 0usize;
        let mut current = row;
        loop {
            let first_col = if current == row {
                usize::from(start.col)
            } else {
                0
            };
            for (col, cell) in frame.lines[current].iter().enumerate().skip(first_col) {
                if usize::from(cursor.row) == current && usize::from(cursor.col) == col {
                    cursor_index = Some(chars);
                }
                if cell.width == 0 {
                    continue;
                }
                if cell.text.is_empty() {
                    text.push(' ');
                } else {
                    text.push_str(&cell.text);
                }
                chars += 1;
            }
            if !frame.wrapped[current] || current + 1 >= frame.lines.len() {
                break;
            }
            current += 1;
        }
        let cursor = match cursor_index {
            Some(index) => index,
            // The cursor sits right after the last cell of the line.
            None if usize::from(cursor.row) == current => chars,
            None => return None,
        };

        let mut text: Vec<char> = text.chars().collect();
        // Drop a right-side prompt: anything after a wide gap following the cursor.
        if let Some(gap) =
            (cursor..text.len()).find(|&index| text[index..].starts_with(&[' ', ' ', ' ']))
            && text[gap..].iter().any(|ch| *ch != ' ')
        {
            text.truncate(gap);
        }
        while text.len() > cursor && text.last() == Some(&' ') {
            text.pop();
        }
        Some(InputLine {
            text: text.into_iter().collect(),
            cursor,
        })
    }

    // ----- keyboard (Shift+arrow) selection on the prompt line ------------------------------
    //
    // The anchor is where the shell cursor was when selecting started; the other end follows the
    // live cursor, so any cursor motion the shell performs (arrows, word jumps, line start/end)
    // extends the selection. Rows are stored as absolute screen rows so output that scrolls the
    // screen does not move the anchor.

    pub fn has_input_selection(&self) -> bool {
        self.input_anchor.is_some()
    }

    /// Start a keyboard selection at the cursor unless one is already active.
    pub fn begin_input_selection(&mut self) -> Result<()> {
        if self.input_anchor.is_none() {
            let row = self.vt.scrollback_rows()? + usize::from(self.vt.cursor_y()?);
            self.input_anchor = Some(InputAnchor {
                col: self.vt.cursor_x()?,
                row,
            });
            self.input_span_shown = None;
        }
        Ok(())
    }

    pub fn clear_input_selection(&mut self) {
        if self.input_anchor.take().is_some() {
            self.input_span_shown = None;
            self.clear_selection();
        }
    }

    /// Anchor and cursor in active-area coordinates (the viewport, when scrolled to the bottom).
    fn input_span(&self) -> Result<Option<(GridPoint, GridPoint)>> {
        let Some(anchor) = self.input_anchor else {
            return Ok(None);
        };
        let Some(row) = anchor.row.checked_sub(self.vt.scrollback_rows()?) else {
            return Ok(None);
        };
        if row >= usize::from(self.vt.rows()?) {
            return Ok(None);
        }
        let anchor = GridPoint {
            col: anchor.col,
            row: row as u16,
        };
        let cursor = GridPoint {
            col: self.vt.cursor_x()?,
            row: self.vt.cursor_y()?,
        };
        Ok(Some((anchor, cursor)))
    }

    /// Mirror the keyboard selection (anchor .. cursor, exclusive of the cursor cell) into the
    /// terminal's selection so it renders and copies like any other selection.
    fn refresh_input_selection(&mut self) -> Result<()> {
        if self.input_anchor.is_none() {
            return Ok(());
        }
        let Some((anchor, cursor)) = self.input_span()? else {
            self.clear_input_selection();
            return Ok(());
        };
        if self.input_span_shown == Some((anchor, cursor)) {
            return Ok(());
        }
        self.input_span_shown = Some((anchor, cursor));
        if anchor == cursor {
            self.vt.set_selection(None)?;
            return Ok(());
        }
        let (lo, hi) = if (anchor.row, anchor.col) < (cursor.row, cursor.col) {
            (anchor, cursor)
        } else {
            (cursor, anchor)
        };
        let cols = self.vt.cols()?;
        let end = if hi.col > 0 {
            GridPoint {
                col: hi.col - 1,
                row: hi.row,
            }
        } else {
            GridPoint {
                col: cols.saturating_sub(1),
                row: hi.row.saturating_sub(1),
            }
        };
        let active = |point: GridPoint| {
            Point::Active(PointCoordinate {
                x: point.col,
                y: u32::from(point.row),
            })
        };
        let start_ref = self.vt.grid_ref(active(lo))?;
        let end_ref = self.vt.grid_ref(active(end))?;
        let selection = Selection::new(start_ref, end_ref, false);
        self.vt.set_selection(Some(&selection))?;
        Ok(())
    }

    /// Bytes that delete the keyboard-selected text through the shell's line editor, ending the
    /// selection. Returns `None` when nothing is selected.
    pub fn take_input_selection_deletion(&mut self) -> Result<Option<Vec<u8>>> {
        let span = self.input_span()?;
        self.clear_input_selection();
        let Some((anchor, cursor)) = span else {
            return Ok(None);
        };
        self.scroll_to_bottom();
        self.sync()?;
        let Some(steps) = self.line_steps(cursor, anchor).filter(|steps| *steps != 0) else {
            return Ok(None);
        };
        // Put the cursor at the right end of the selection, then backspace over it.
        let mut bytes = if steps > 0 {
            self.arrow_steps(steps)?
        } else {
            Vec::new()
        };
        let backspace = self.encode_key(&KeyInput::named(key::Key::Backspace))?;
        bytes.extend(backspace.repeat(steps.unsigned_abs()));
        Ok(Some(bytes))
    }

    /// The most recently synchronized frame.
    pub fn frame(&self) -> &Frame {
        &self.frame
    }

    /// Pull the latest render state from libghostty and update the owned [`Frame`].
    ///
    /// Only rows flagged dirty are re-extracted unless libghostty requests a full redraw (or the
    /// grid size / default colors changed). Dirty flags are cleared afterwards.
    pub fn sync(&mut self) -> Result<&Frame> {
        self.refresh_input_selection()?;
        let snapshot = self.render.update(&self.vt)?;
        let dirty = snapshot.dirty()?;
        let cols = snapshot.cols()?;
        let rows = snapshot.rows()?;
        let colors = snapshot.colors()?;
        let frame = &mut self.frame;
        let bold_is_bright = self.bold_is_bright;

        let resized = frame.cols != cols || frame.rows != rows;
        let recolored =
            frame.foreground != colors.foreground || frame.background != colors.background;
        let full = dirty == Dirty::Full || resized || recolored;
        let mut changed = full;

        if resized {
            frame.cols = cols;
            frame.rows = rows;
            frame.lines =
                vec![vec![Cell::blank(colors.foreground); usize::from(cols)]; usize::from(rows)];
            frame.wrapped = vec![false; usize::from(rows)];
        }
        frame.foreground = colors.foreground;
        frame.background = colors.background;

        if full || dirty == Dirty::Partial {
            let mut row_iter = self.row_iter.update(&snapshot)?;
            let mut y = 0usize;
            let mut text = String::with_capacity(8);
            while let Some(row) = row_iter.next() {
                if y >= frame.lines.len() {
                    break;
                }
                if full || row.dirty()? {
                    frame.wrapped[y] = row.raw_row()?.is_wrapped()?;
                    let line = &mut frame.lines[y];
                    line.clear();
                    let mut cell_iter = self.cell_iter.update(row)?;
                    while let Some(cell) = cell_iter.next() {
                        line.push(extract_cell(cell, &colors, bold_is_bright, &mut text)?);
                    }
                    line.resize(usize::from(cols), Cell::blank(colors.foreground));
                    changed = true;
                }
                row.set_dirty(false)?;
                y += 1;
            }
            snapshot.set_dirty(Dirty::Clean)?;
        }

        let mut cursor = None;
        if snapshot.cursor_visible()?
            && let Some(viewport) = snapshot.cursor_viewport()?
        {
            let col = if viewport.at_wide_tail {
                viewport.x.saturating_sub(1)
            } else {
                viewport.x
            };
            let width = frame
                .lines
                .get(usize::from(viewport.y))
                .and_then(|line| line.get(usize::from(col)))
                .map_or(1, |cell| cell.width.max(1));
            cursor = Some(Cursor {
                col,
                row: viewport.y,
                width,
                shape: match snapshot.cursor_visual_style()? {
                    CursorVisualStyle::Bar => CursorShape::Bar,
                    CursorVisualStyle::Underline => CursorShape::Underline,
                    CursorVisualStyle::BlockHollow => CursorShape::BlockHollow,
                    _ => CursorShape::Block,
                },
                blinking: snapshot.cursor_blinking()?,
                color: snapshot.cursor_color()?.or(colors.cursor),
            });
        }
        if cursor != frame.cursor {
            frame.cursor = cursor;
            changed = true;
        }

        if changed {
            frame.generation += 1;
        }
        Ok(&self.frame)
    }
}

fn register_callbacks(
    vt: &mut libghostty_vt::Terminal<'static, 'static>,
    shared: &Rc<Shared>,
) -> Result<()> {
    let replies = shared.clone();
    let bell = shared.clone();
    let title = shared.clone();
    let clipboard = shared.clone();
    let scheme = shared.clone();
    let size = shared.clone();
    vt.on_pty_write(move |_, data| replies.replies.borrow_mut().extend_from_slice(data))?
        .on_bell(move |_| bell.bell.set(true))?
        .on_title_changed(move |_| title.title_changed.set(true))?
        .on_xtversion(|_| Some(concat!("bridge ", env!("CARGO_PKG_VERSION"))))?
        .on_color_scheme(move |_| {
            Some(if scheme.dark.get() {
                ColorScheme::Dark
            } else {
                ColorScheme::Light
            })
        })?
        .on_size(move |term| {
            let pixels = size.pixels.get();
            Some(SizeReportSize {
                rows: term.rows().ok()?,
                columns: term.cols().ok()?,
                cell_width: pixels.cell_width,
                cell_height: pixels.cell_height,
            })
        })?
        .on_device_attributes(|_| {
            Some(DeviceAttributes {
                primary: PrimaryDeviceAttributes::new(
                    ConformanceLevel::VT220,
                    &[
                        DeviceAttributeFeature::COLUMNS_132,
                        DeviceAttributeFeature::SELECTIVE_ERASE,
                        DeviceAttributeFeature::ANSI_COLOR,
                    ],
                ),
                secondary: SecondaryDeviceAttributes {
                    device_type: DeviceType::VT220,
                    firmware_version: 1,
                    rom_cartridge: 0,
                },
                tertiary: Default::default(),
            })
        })?
        .on_clipboard_write(move |_, write| {
            let text = write
                .contents()
                .find(|content| content.mime.starts_with("text/plain"))
                .map(|content| content.data.to_owned())
                .unwrap_or_default();
            *clipboard.clipboard.borrow_mut() = Some(text);
            Ok(())
        })?;
    Ok(())
}

fn extract_cell(
    cell: &CellIteration<'_, '_>,
    colors: &Colors,
    bold_is_bright: bool,
    text: &mut String,
) -> Result<Cell> {
    let width = match cell.raw_cell()?.wide()? {
        CellWide::Wide => 2,
        CellWide::SpacerTail => 0,
        _ => 1,
    };

    text.clear();
    if width != 0 && cell.graphemes_len()? > 0 {
        cell.graphemes_utf8(text)?;
    }

    let mut fg = cell.fg_color()?.unwrap_or(colors.foreground);
    let mut bg = cell.bg_color()?;
    let mut style = CellStyle {
        fg,
        bold: false,
        italic: false,
        faint: false,
        strikethrough: false,
        underline: None,
    };

    if cell.has_styling()? {
        let raw = cell.style()?;
        if bold_is_bright
            && raw.bold
            && let StyleColor::Palette(index) = raw.fg_color
            && index.0 < 8
        {
            fg = colors.palette[usize::from(index.0) + 8];
        }
        if raw.inverse {
            let inverted_bg = fg;
            fg = bg.unwrap_or(colors.background);
            bg = Some(inverted_bg);
        }
        if raw.invisible {
            text.clear();
        }
        let underline = match raw.underline {
            Underline::None => None,
            Underline::Double => Some(UnderlineKind::Double),
            Underline::Curly => Some(UnderlineKind::Curly),
            Underline::Dotted => Some(UnderlineKind::Dotted),
            Underline::Dashed => Some(UnderlineKind::Dashed),
            _ => Some(UnderlineKind::Single),
        };
        let underline_color = match raw.underline_color {
            StyleColor::None => fg,
            StyleColor::Palette(index) => colors.palette[usize::from(index.0)],
            StyleColor::Rgb(rgb) => rgb,
        };
        style = CellStyle {
            fg,
            bold: raw.bold,
            italic: raw.italic,
            faint: raw.faint,
            strikethrough: raw.strikethrough,
            underline: underline.map(|kind| (kind, underline_color)),
        };
    }

    Ok(Cell {
        text: text.clone(),
        bg,
        style,
        width,
        selected: cell.is_selected()?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn terminal(cols: u16, rows: u16) -> Terminal {
        let mut term = Terminal::new(TerminalConfig {
            cols,
            rows,
            scrollback: 100,
        })
        .unwrap();
        term.resize(cols, rows, 8, 16).unwrap();
        term
    }

    fn line_text(frame: &Frame, row: usize) -> String {
        frame.lines[row]
            .iter()
            .filter(|cell| cell.width != 0)
            .map(|cell| {
                if cell.text.is_empty() {
                    " "
                } else {
                    cell.text.as_str()
                }
            })
            .collect::<String>()
            .trim_end()
            .to_owned()
    }

    fn at(col: u16, row: u16) -> (GridPoint, SurfacePoint) {
        (
            GridPoint { col, row },
            SurfacePoint {
                x: f32::from(col) * 8. + 2.,
                y: f32::from(row) * 16. + 8.,
            },
        )
    }

    #[test]
    fn writes_text_and_colors() {
        let mut term = terminal(20, 5);
        term.write(b"hi\x1b[31mX\x1b[0m");
        let frame = term.sync().unwrap();
        assert_eq!(line_text(frame, 0), "hiX");
        let red = frame.lines[0][2].style.fg;
        assert_ne!(red, frame.lines[0][0].style.fg);
        assert!(
            red.r > red.g && red.r > red.b,
            "expected a red foreground, got {red:?}"
        );
    }

    #[test]
    fn inverse_swaps_colors() {
        let mut term = terminal(10, 2);
        term.set_colors(&ColorConfig {
            foreground: Rgb {
                r: 200,
                g: 200,
                b: 200,
            },
            background: Rgb {
                r: 10,
                g: 10,
                b: 10,
            },
            cursor: None,
            ansi: None,
        })
        .unwrap();
        term.write(b"\x1b[7mA");
        let frame = term.sync().unwrap();
        let cell = &frame.lines[0][0];
        assert_eq!(
            cell.bg,
            Some(Rgb {
                r: 200,
                g: 200,
                b: 200
            })
        );
        assert_eq!(
            cell.style.fg,
            Rgb {
                r: 10,
                g: 10,
                b: 10
            }
        );
    }

    #[test]
    fn custom_ansi_palette_and_bold_is_bright() {
        let mut term = terminal(10, 2);
        let mut ansi = [Rgb::default(); 16];
        ansi[1] = Rgb { r: 1, g: 2, b: 3 };
        ansi[9] = Rgb { r: 4, g: 5, b: 6 };
        term.set_colors(&ColorConfig {
            foreground: Rgb {
                r: 200,
                g: 200,
                b: 200,
            },
            background: Rgb::default(),
            cursor: None,
            ansi: Some(ansi),
        })
        .unwrap();
        term.write(b"\x1b[31mA\x1b[1mB");
        let frame = term.sync().unwrap();
        assert_eq!(frame.lines[0][0].style.fg, ansi[1]);
        assert_eq!(frame.lines[0][1].style.fg, ansi[1]);
        term.set_bold_is_bright(true);
        let frame = term.sync().unwrap();
        assert_eq!(frame.lines[0][1].style.fg, ansi[9]);
    }

    #[test]
    fn tracks_cursor_position() {
        let mut term = terminal(20, 10);
        term.write(b"\x1b[4;7H");
        let cursor = term.sync().unwrap().cursor.unwrap();
        assert_eq!((cursor.col, cursor.row), (6, 3));
    }

    #[test]
    fn default_cursor_shape_applies() {
        let mut term = terminal(10, 2);
        term.set_default_cursor(CursorShape::Bar, false).unwrap();
        let cursor = term.sync().unwrap().cursor.unwrap();
        assert_eq!(cursor.shape, CursorShape::Bar);
        assert!(!cursor.blinking);
    }

    #[test]
    fn wide_characters_occupy_two_cells() {
        let mut term = terminal(10, 2);
        term.write("漢a".as_bytes());
        let frame = term.sync().unwrap();
        assert_eq!(frame.lines[0][0].text, "漢");
        assert_eq!(frame.lines[0][0].width, 2);
        assert_eq!(frame.lines[0][1].width, 0);
        assert_eq!(frame.lines[0][2].text, "a");
    }

    #[test]
    fn resize_reflows_wrapped_lines() {
        let mut term = terminal(10, 4);
        term.write(b"abcdefgh");
        assert!(term.resize(4, 4, 8, 16).unwrap());
        let frame = term.sync().unwrap();
        assert_eq!((frame.cols, frame.rows), (4, 4));
        assert_eq!(line_text(frame, 0), "abcd");
        assert_eq!(line_text(frame, 1), "efgh");
        assert!(frame.wrapped[0]);
        assert!(!term.resize(4, 4, 8, 16).unwrap());
    }

    #[test]
    fn only_dirty_rows_bump_generation() {
        let mut term = terminal(10, 3);
        term.write(b"one");
        let first = term.sync().unwrap().generation;
        let second = term.sync().unwrap().generation;
        assert_eq!(
            first, second,
            "an unchanged terminal must not produce a new frame"
        );
        term.write(b"\r\ntwo");
        let frame = term.sync().unwrap();
        assert!(frame.generation > second);
        assert_eq!(line_text(frame, 0), "one");
        assert_eq!(line_text(frame, 1), "two");
    }

    #[test]
    fn wheel_scrolls_through_scrollback() {
        let mut term = terminal(10, 3);
        for i in 0..10 {
            term.write(format!("line{i}\r\n").as_bytes());
        }
        let bottom = line_text(term.sync().unwrap(), 0);
        let (_, pos) = at(0, 0);
        let outcome = term.wheel(2, pos, key::Mods::empty(), true).unwrap();
        assert_eq!(outcome, WheelOutcome::Scrolled);
        assert!(term.is_scrolled_back());
        let scrolled = line_text(term.sync().unwrap(), 0);
        assert_ne!(bottom, scrolled);
        term.scroll_to_bottom();
        assert!(!term.is_scrolled_back());
        assert_eq!(line_text(term.sync().unwrap(), 0), bottom);
    }

    #[test]
    fn encodes_keys_according_to_modes() {
        let mut term = terminal(10, 3);
        let up = KeyInput::named(key::Key::ArrowUp);
        assert_eq!(term.encode_key(&up).unwrap(), b"\x1b[A");
        term.write(b"\x1b[?1h"); // DECCKM: application cursor keys
        assert_eq!(term.encode_key(&up).unwrap(), b"\x1bOA");

        let ctrl_c = KeyInput {
            key: key::Key::C,
            mods: key::Mods::CTRL,
            text: Some("c".into()),
            unshifted: Some('c'),
            repeat: false,
        };
        assert_eq!(term.encode_key(&ctrl_c).unwrap(), b"\x03");
    }

    #[test]
    fn option_as_alt_prefixes_escape() {
        let mut term = terminal(10, 3);
        term.set_option_as_alt(true);
        let alt_b = KeyInput {
            key: key::Key::B,
            mods: key::Mods::ALT,
            text: Some("b".into()),
            unshifted: Some('b'),
            repeat: false,
        };
        assert_eq!(term.encode_key(&alt_b).unwrap(), b"\x1bb");
    }

    #[test]
    fn wheel_reports_when_mouse_tracking() {
        let mut term = terminal(10, 3);
        term.write(b"\x1b[?1000h\x1b[?1006h"); // normal tracking + SGR encoding
        let (_, pos) = at(0, 0);
        match term.wheel(1, pos, key::Mods::empty(), true).unwrap() {
            WheelOutcome::Report(bytes) => assert_eq!(bytes, b"\x1b[<64;1;1M"),
            other => panic!("expected a mouse report, got {other:?}"),
        }
        // With reporting disabled by the user, the wheel scrolls locally instead.
        assert_eq!(
            term.wheel(1, pos, key::Mods::empty(), false).unwrap(),
            WheelOutcome::Scrolled
        );
    }

    #[test]
    fn mouse_clicks_are_reported() {
        let mut term = terminal(10, 3);
        term.write(b"\x1b[?1000h\x1b[?1006h");
        let (_, pos) = at(2, 1);
        let press = term
            .encode_mouse(
                mouse::Action::Press,
                Some(mouse::Button::Left),
                pos,
                key::Mods::empty(),
                true,
            )
            .unwrap();
        assert_eq!(press, b"\x1b[<0;3;2M");
        let release = term
            .encode_mouse(
                mouse::Action::Release,
                Some(mouse::Button::Left),
                pos,
                key::Mods::empty(),
                false,
            )
            .unwrap();
        assert_eq!(release, b"\x1b[<0;3;2m");
    }

    #[test]
    fn drag_selection_and_copy() {
        let mut term = terminal(20, 3);
        term.write(b"hello world");
        term.sync().unwrap();
        let (start, start_pos) = at(0, 0);
        let (end, mut end_pos) = at(4, 0);
        end_pos.x += 4.; // right half of the cell includes it in the selection
        term.selection_press(start, start_pos, Duration::from_secs(1))
            .unwrap();
        term.selection_drag(end, end_pos).unwrap();
        let (clicks, dragged) = term.selection_release(end).unwrap();
        assert_eq!(clicks, 1);
        assert!(dragged);
        assert_eq!(term.selection_text().as_deref(), Some("hello"));
        let frame = term.sync().unwrap();
        assert!(frame.lines[0][0].selected && frame.lines[0][4].selected);
        assert!(!frame.lines[0][6].selected);
        term.clear_selection();
        assert_eq!(term.selection_text(), None);
    }

    #[test]
    fn double_click_selects_word() {
        let mut term = terminal(20, 3);
        term.write(b"hello world");
        let (cell, pos) = at(7, 0);
        for time in [1000, 1100] {
            term.selection_press(cell, pos, Duration::from_millis(time))
                .unwrap();
            term.selection_release(cell).unwrap();
        }
        assert_eq!(term.selection_text().as_deref(), Some("world"));
    }

    #[test]
    fn paste_is_bracketed_when_requested() {
        let mut term = terminal(10, 3);
        assert_eq!(term.encode_paste("ls").unwrap(), b"ls");
        assert!(!term.is_paste_safe("rm -rf x\n"));
        term.write(b"\x1b[?2004h");
        assert_eq!(term.encode_paste("ls").unwrap(), b"\x1b[200~ls\x1b[201~");
        assert!(term.is_paste_safe("rm -rf x\n"));
    }

    #[test]
    fn click_to_move_on_wrapped_line() {
        let mut term = terminal(5, 4);
        term.write(b"$ abcdefg"); // wraps: "$ abc" / "defg", cursor after 'g' at (4, 1)
        term.sync().unwrap();
        let left = term
            .click_to_move(GridPoint { col: 2, row: 0 })
            .unwrap()
            .unwrap();
        assert_eq!(left, b"\x1b[D".repeat(7));
        let right = term.click_to_move(GridPoint { col: 1, row: 1 }).unwrap();
        assert_eq!(right.unwrap(), b"\x1b[D".repeat(3));
        assert_eq!(
            term.click_to_move(GridPoint { col: 0, row: 3 }).unwrap(),
            None
        );
    }

    #[test]
    fn keyboard_selection_follows_cursor_and_deletes() {
        let mut term = terminal(20, 3);
        term.write(b"$ hello world");
        term.begin_input_selection().unwrap();
        // The shell moves the cursor three characters left (as after three Shift+Left presses).
        term.write(b"\x1b[3D");
        term.sync().unwrap();
        assert_eq!(term.selection_text().as_deref(), Some("rld"));
        // Deleting moves to the right end of the selection, then backspaces over it.
        let bytes = term.take_input_selection_deletion().unwrap().unwrap();
        assert_eq!(
            bytes,
            [&b"\x1b[C".repeat(3)[..], &b"\x7f".repeat(3)[..]].concat()
        );
        assert!(!term.has_input_selection());
        assert_eq!(term.selection_text(), None);
    }

    #[test]
    fn keyboard_selection_to_the_right() {
        let mut term = terminal(20, 3);
        term.write(b"$ abc\x1b[3D"); // cursor on 'a'
        term.begin_input_selection().unwrap();
        term.write(b"\x1b[2C");
        term.sync().unwrap();
        assert_eq!(term.selection_text().as_deref(), Some("ab"));
        let bytes = term.take_input_selection_deletion().unwrap().unwrap();
        assert_eq!(bytes, b"\x7f".repeat(2));
    }

    /// `cargo test --release -- --ignored --nocapture bench_` prints per-frame costs.
    #[test]
    #[ignore = "benchmark"]
    fn bench_full_frame_sync() {
        let mut term = terminal(200, 60);
        let mut output = Vec::new();
        for i in 0..5_000 {
            output.extend_from_slice(
                format!("\x1b[1;34mdrwxr-xr-x\x1b[0m  12 user staff  384 Oct 19 \x1b[32mfile-{i:05}.rs\x1b[0m  some trailing text here\r\n").as_bytes(),
            );
        }
        let start = std::time::Instant::now();
        term.write(&output);
        let write = start.elapsed();
        let start = std::time::Instant::now();
        let iterations = 50;
        for _ in 0..iterations {
            term.write(b"x\r\n"); // scroll by one line: every row becomes dirty
            term.sync().unwrap();
        }
        let sync = start.elapsed() / iterations;
        println!(
            "parse {:.1} MB in {write:?} ({:.0} MB/s); full 200x60 frame sync: {sync:?}",
            output.len() as f64 / 1e6,
            output.len() as f64 / 1e6 / write.as_secs_f64()
        );
    }

    #[test]
    fn reads_the_typed_command_line() {
        let mut term = terminal(12, 4);
        term.write(b"$ ");
        let start = term.cursor_anchor().unwrap();
        term.write(b"git status -s"); // wraps onto the second row
        term.sync().unwrap();
        let input = term.prompt_input(start).unwrap();
        assert_eq!(input.text, "git status -s");
        assert!(input.cursor_at_end());
        term.write(b"\x1b[3D");
        term.sync().unwrap();
        let input = term.prompt_input(start).unwrap();
        assert_eq!(input.cursor, 10);
        assert_eq!(input.before_cursor(), "git status");
    }

    #[test]
    fn ignores_right_side_prompt() {
        let mut term = terminal(30, 3);
        term.write(b"> ");
        let start = term.cursor_anchor().unwrap();
        term.write(b"ls\x1b[1;25Hmain\x1b[1;5H");
        term.sync().unwrap();
        let input = term.prompt_input(start).unwrap();
        assert_eq!(input.text, "ls");
        assert!(input.cursor_at_end());
    }

    #[test]
    fn replies_and_title_are_reported() {
        let mut term = terminal(10, 3);
        term.write(b"\x1b[6n\x1b]2;hello\x07\x07");
        let effects = term.take_effects();
        assert_eq!(effects.replies, b"\x1b[1;1R");
        assert_eq!(effects.title.as_deref(), Some("hello"));
        assert!(effects.bell);
        let effects = term.take_effects();
        assert!(effects.replies.is_empty() && effects.title.is_none() && !effects.bell);
    }

    #[test]
    fn focus_events_only_when_enabled() {
        let mut term = terminal(10, 3);
        assert_eq!(term.encode_focus(true), None);
        term.write(b"\x1b[?1004h");
        assert_eq!(term.encode_focus(true).as_deref(), Some(&b"\x1b[I"[..]));
        assert_eq!(term.encode_focus(false).as_deref(), Some(&b"\x1b[O"[..]));
    }
}
