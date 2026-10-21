//! Side sheet: a dimmed backdrop and a panel sliding in from the right over the whole window,
//! timed by the theme's motion tokens (quick in, quicker out). gpui-component's own sheet only
//! nudges its panel 100px in and has no exit animation, so the app draws its own on gpui-base's
//! unstyled sheet host, which brings focus trapping, Escape and click-outside dismissal.

use std::rc::Rc;

use gpui::{
    AnyElement, App, FocusHandle, FontWeight, Global, InteractiveElement as _, IntoElement,
    ParentElement as _, Pixels, SharedString, Styled as _, WeakFocusHandle, Window, div, hsla, px,
};
use gpui_base::{Presence, Transition};
use gpui_component::{
    ActiveTheme as _, Sizable as _,
    button::{Button, ButtonVariants as _},
    h_flex,
    scroll::ScrollableElement as _,
    v_flex,
};

use crate::icons::IconName;

/// shadcn's backdrop, `bg-black/50`.
const BACKDROP_OPACITY: f32 = 0.5;

type Content = Rc<dyn Fn(&mut Window, &mut App) -> AnyElement>;

struct ActiveSheet {
    title: SharedString,
    width: Pixels,
    focus: FocusHandle,
    /// Where focus goes back to when the sheet closes.
    previous_focus: Option<WeakFocusHandle>,
    content: Content,
}

/// The sheet being shown. It stays here while it animates out after closing.
#[derive(Default)]
struct Sheets {
    current: Option<Rc<ActiveSheet>>,
    open: bool,
}

impl Global for Sheets {}

/// Show a sheet (replacing any open one); `content` is rebuilt on every render.
pub fn open(
    title: impl Into<SharedString>,
    width: Pixels,
    window: &mut Window,
    cx: &mut App,
    content: impl Fn(&mut Window, &mut App) -> AnyElement + 'static,
) {
    let sheets = cx.default_global::<Sheets>();
    let previous_focus = match &sheets.current {
        Some(sheet) if sheets.open => sheet.previous_focus.clone(),
        _ => None,
    }
    .or_else(|| window.focused(cx).map(|handle| handle.downgrade()));
    let focus = cx.focus_handle();
    focus.focus(window, cx);
    let sheets = cx.global_mut::<Sheets>();
    sheets.current = Some(Rc::new(ActiveSheet {
        title: title.into(),
        width,
        focus,
        previous_focus,
        content: Rc::new(content),
    }));
    sheets.open = true;
    window.refresh();
}

/// Close the open sheet (it animates out) and give focus back to what had it before.
pub fn close(window: &mut Window, cx: &mut App) {
    let sheets = cx.default_global::<Sheets>();
    if !sheets.open {
        return;
    }
    sheets.open = false;
    let previous = sheets
        .current
        .as_ref()
        .and_then(|sheet| sheet.previous_focus.clone());
    if let Some(handle) = previous.and_then(|handle| handle.upgrade()) {
        window.focus(&handle, cx);
    }
    window.refresh();
}

/// The sheet layer, drawn above the window content while a sheet is open or animating out.
pub fn render(window: &mut Window, cx: &mut App) -> Option<AnyElement> {
    let (sheet, open) = {
        let sheets = cx.try_global::<Sheets>()?;
        (sheets.current.clone()?, sheets.open)
    };
    let motion = cx.theme().motion_tokens();
    let transition = if open {
        Transition::new(motion.duration_normal).easing(motion.easing_enter.clone())
    } else {
        Transition::new(motion.duration_fast).easing(motion.easing_exit.clone())
    };
    let sample = Presence::new("app-sheet", open)
        .transition(transition)
        .sample(window, cx);
    if !sample.should_render() {
        return None;
    }
    let progress = sample.progress;

    let theme = cx.theme();
    let viewport = window.viewport_size();
    let width = sheet.width.min(viewport.width - px(48.)).max(px(0.));
    let (background, border, muted) = (
        theme.tokens.background,
        theme.border,
        theme.muted_foreground,
    );
    let content = (sheet.content)(window, cx);

    let backdrop = div()
        .absolute()
        .inset_0()
        .bg(hsla(0., 0., 0., BACKDROP_OPACITY * progress));
    let panel = v_flex()
        .id("app-sheet-panel")
        .absolute()
        .occlude()
        // Full window height, over the title bar like shadcn's sheet; the traffic lights are on
        // the other side.
        .top_0()
        .bottom_0()
        .right(-width * (1. - progress))
        .w(width)
        .bg(background)
        .border_l_1()
        .border_color(border)
        .shadow_lg()
        .child(
            h_flex()
                .flex_none()
                .justify_between()
                .pl_4()
                .pr_3()
                .py_2()
                .font_weight(FontWeight::SEMIBOLD)
                .child(sheet.title.clone())
                .child(
                    Button::new("app-sheet-close")
                        .small()
                        .ghost()
                        .icon(IconName::X)
                        .text_color(muted)
                        .on_click(|_, window, cx| close(window, cx)),
                ),
        )
        .child(
            div().flex_1().min_h_0().overflow_hidden().child(
                v_flex()
                    .id("app-sheet-body")
                    .size_full()
                    .overflow_y_scrollbar()
                    .px_4()
                    .child(content),
            ),
        );

    Some(if open {
        gpui_base::Sheet::new(cx)
            .focus_handle(sheet.focus.clone())
            .request_close(close)
            .overlay(backdrop)
            .surface(panel)
            .into_any_element()
    } else {
        // Animating out: drawn only, so the window underneath already takes clicks.
        div()
            .absolute()
            .inset_0()
            .child(backdrop)
            .child(panel)
            .into_any_element()
    })
}
