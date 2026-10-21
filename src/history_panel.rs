//! Command history panel: every command run, newest first, with a fuzzy search bar.

use gpui::{
    AnyElement, App, AppContext as _, Context, Entity, FontWeight, Hsla, InteractiveElement,
    IntoElement, KeyBinding, ParentElement, Render, ScrollStrategy, SharedString,
    StatefulInteractiveElement, Styled, Subscription, UniformListScrollHandle, Window, actions,
    div, prelude::FluentBuilder as _, px, uniform_list,
};
use gpui_component::{
    ActiveTheme, Icon, Sizable as _, h_flex,
    input::{Input, InputEvent, InputState},
    v_flex,
};

use crate::{
    history::{self, History, HistoryEntry},
    icons::IconName,
    sheet, ui,
    view::ActiveTerminal,
    workspace::tilde,
};

actions!(history_panel, [SelectPrevious, SelectNext]);

const CONTEXT: &str = "HistoryPanel";
const MAX_RESULTS: usize = 5000;

pub fn bind_keys(cx: &mut App) {
    // Bound on the search field inside the panel so arrows move through results.
    let context = Some("HistoryPanel > Input");
    cx.bind_keys([
        KeyBinding::new("up", SelectPrevious, context),
        KeyBinding::new("down", SelectNext, context),
        KeyBinding::new("ctrl-p", SelectPrevious, context),
        KeyBinding::new("ctrl-n", SelectNext, context),
        KeyBinding::new("ctrl-r", SelectNext, context),
    ]);
}

/// Open the panel as a sheet; picking a command puts it on the active terminal's prompt.
pub fn open(window: &mut Window, cx: &mut App) {
    let panel = cx.new(|cx| HistoryPanel::new(window, cx));
    let search = panel.read(cx).search.clone();
    sheet::open("Command history", px(600.), window, cx, move |_, _| {
        panel.clone().into_any_element()
    });
    window.defer(cx, move |window, cx| {
        search.update(cx, |search, cx| search.focus(window, cx));
    });
}

struct Row {
    command: SharedString,
    positions: Vec<usize>,
    details: Details,
}

/// Metadata shown under a command.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct Details {
    cwd: Option<String>,
    ago: Option<String>,
    exit_code: Option<i32>,
    duration: Option<String>,
    imported: bool,
}

pub struct HistoryPanel {
    search: Entity<InputState>,
    rows: Vec<Row>,
    total: usize,
    selected: usize,
    scroll: UniformListScrollHandle,
    _subscriptions: Vec<Subscription>,
}

impl HistoryPanel {
    fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let search = cx.new(|cx| InputState::new(window, cx).placeholder("Search commands…"));
        let subscription = cx.subscribe_in(
            &search,
            window,
            |this, _, event: &InputEvent, window, cx| match event {
                InputEvent::Change => this.update_results(cx),
                InputEvent::PressEnter { secondary, .. } => {
                    this.choose(this.selected, *secondary, window, cx)
                }
                _ => {}
            },
        );
        let mut panel = Self {
            search,
            rows: Vec::new(),
            total: 0,
            selected: 0,
            scroll: UniformListScrollHandle::new(),
            _subscriptions: vec![subscription],
        };
        panel.update_results(cx);
        panel
    }

    fn update_results(&mut self, cx: &mut Context<Self>) {
        let query = self.search.read(cx).value();
        let history = cx.global::<History>();
        let now = history::now_secs();
        self.total = history.recent_unique().count();
        self.rows = history
            .search(&query, MAX_RESULTS)
            .into_iter()
            .map(|hit| {
                let entry = &history.entries()[hit.index];
                Row {
                    command: entry.command.clone().into(),
                    positions: hit.positions,
                    details: details(entry, now),
                }
            })
            .collect();
        self.selected = 0;
        self.scroll.scroll_to_item(0, ScrollStrategy::Top);
        cx.notify();
    }

    fn move_selection(&mut self, delta: isize, cx: &mut Context<Self>) {
        if self.rows.is_empty() {
            return;
        }
        let last = self.rows.len() as isize - 1;
        self.selected = (self.selected as isize + delta).clamp(0, last) as usize;
        self.scroll
            .scroll_to_item(self.selected, ScrollStrategy::Center);
        cx.notify();
    }

    /// Put the command on the prompt (or run it right away with ⌘⏎).
    fn choose(&mut self, index: usize, run: bool, window: &mut Window, cx: &mut Context<Self>) {
        let Some(row) = self.rows.get(index) else {
            return;
        };
        let command = row.command.to_string();
        sheet::close(window, cx);
        if let Some(view) = cx
            .try_global::<ActiveTerminal>()
            .and_then(|active| active.0.upgrade())
        {
            view.update(cx, |view, cx| view.insert_command(&command, run, cx));
        }
    }

    fn render_rows(
        &mut self,
        range: std::ops::Range<usize>,
        cx: &mut Context<Self>,
    ) -> Vec<impl IntoElement + use<>> {
        let theme = cx.theme();
        let (accent, accent_foreground, muted, danger, success, primary) = (
            theme.accent,
            theme.accent_foreground,
            theme.muted_foreground,
            theme.danger,
            theme.success,
            theme.primary,
        );
        range
            .filter_map(|index| {
                let row = self.rows.get(index)?;
                let selected = index == self.selected;
                let meta = if selected {
                    accent_foreground.opacity(0.7)
                } else {
                    muted
                };
                let details = &row.details;
                Some(
                    v_flex()
                        .id(("history-row", index))
                        .h(px(52.))
                        .px_3()
                        .gap_1()
                        .justify_center()
                        .rounded_md()
                        .cursor_pointer()
                        .when(selected, |row| row.bg(accent).text_color(accent_foreground))
                        .on_click(
                            cx.listener(move |this, event: &gpui::ClickEvent, window, cx| {
                                this.selected = index;
                                this.choose(index, event.modifiers().platform, window, cx);
                            }),
                        )
                        .child(
                            h_flex()
                                .font_family("Menlo")
                                .text_sm()
                                .overflow_hidden()
                                .whitespace_nowrap()
                                .children(highlighted(&row.command, &row.positions, primary, meta)),
                        )
                        .child(
                            h_flex()
                                .gap_3()
                                .text_xs()
                                .text_color(meta)
                                .overflow_hidden()
                                .whitespace_nowrap()
                                .when_some(details.cwd.clone(), |line, cwd| {
                                    line.child(chip(IconName::Folder, cwd, meta))
                                })
                                .when_some(details.ago.clone(), |line, ago| {
                                    line.child(chip(IconName::Clock, ago, meta))
                                })
                                .when_some(details.exit_code, |line, code| {
                                    line.child(if code == 0 {
                                        chip(IconName::CircleCheck, "ok".into(), success)
                                    } else {
                                        chip(IconName::CircleX, format!("exit {code}"), danger)
                                    })
                                })
                                .when_some(details.duration.clone(), |line, duration| {
                                    line.child(chip(IconName::Timer, duration, meta))
                                })
                                .when(details.imported, |line| {
                                    line.child(chip(
                                        IconName::SquareTerminal,
                                        "shell history".into(),
                                        meta,
                                    ))
                                }),
                        ),
                )
            })
            .collect()
    }
}

impl Render for HistoryPanel {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let muted = cx.theme().muted_foreground;
        let count = if self.rows.len() == self.total {
            format!("{} commands", self.total)
        } else {
            format!("{} of {} commands", self.rows.len(), self.total)
        };
        let summary = h_flex()
            .gap_3()
            .child(div().flex_1().child(count))
            .child(ui::key_hint(&["up", "down"], "choose"))
            .child(ui::key_hint(&["enter"], "insert"))
            .child(ui::key_hint(&["cmd-enter"], "run"));
        v_flex()
            .key_context(CONTEXT)
            .size_full()
            .gap_2()
            .on_action(cx.listener(|this, _: &SelectPrevious, _, cx| this.move_selection(-1, cx)))
            .on_action(cx.listener(|this, _: &SelectNext, _, cx| this.move_selection(1, cx)))
            .child(
                Input::new(&self.search)
                    .prefix(Icon::new(IconName::Search).small().text_color(muted))
                    .cleanable(true),
            )
            .child(div().text_xs().text_color(muted).child(summary))
            .child(
                uniform_list(
                    "history-rows",
                    self.rows.len(),
                    cx.processor(|this, range, _window, cx| this.render_rows(range, cx)),
                )
                .track_scroll(&self.scroll)
                .flex_1(),
            )
    }
}

fn details(entry: &HistoryEntry, now: u64) -> Details {
    Details {
        cwd: entry.cwd.as_deref().map(tilde),
        ago: entry
            .started_at
            .map(|started| ago(now.saturating_sub(started))),
        exit_code: entry.exit_code,
        duration: entry.duration_ms.filter(|ms| *ms >= 100).map(|ms| {
            if ms < 60_000 {
                format!("{:.1}s", ms as f64 / 1000.)
            } else {
                format!("{}m {}s", ms / 60_000, ms % 60_000 / 1000)
            }
        }),
        imported: entry.imported,
    }
}

/// An icon followed by a short label.
fn chip(icon: IconName, label: String, color: Hsla) -> gpui::Div {
    h_flex()
        .flex_none()
        .gap_1()
        .text_color(color)
        .child(Icon::new(icon).xsmall())
        .child(label)
}

fn ago(secs: u64) -> String {
    match secs {
        0..60 => "just now".into(),
        60..3600 => format!("{}m ago", secs / 60),
        3600..86_400 => format!("{}h ago", secs / 3600),
        _ => format!("{}d ago", secs / 86_400),
    }
}

/// The command as spans with fuzzy-matched characters emphasized; line breaks shown as an icon.
fn highlighted(command: &str, positions: &[usize], color: Hsla, muted: Hsla) -> Vec<AnyElement> {
    let mut spans = Vec::new();
    let mut current = String::new();
    let mut current_matched = false;
    for (index, ch) in command.chars().enumerate() {
        let matched = positions.contains(&index);
        if (matched != current_matched || ch == '\n') && !current.is_empty() {
            spans.push(span(std::mem::take(&mut current), current_matched, color));
        }
        if ch == '\n' {
            spans.push(
                div()
                    .px_1()
                    .child(
                        Icon::new(IconName::CornerDownLeft)
                            .xsmall()
                            .text_color(muted),
                    )
                    .into_any_element(),
            );
            continue;
        }
        current_matched = matched;
        current.push(ch);
    }
    if !current.is_empty() {
        spans.push(span(current, current_matched, color));
    }
    spans
}

fn span(text: String, matched: bool, color: Hsla) -> AnyElement {
    let span = div().child(text);
    if matched {
        span.text_color(color)
            .font_weight(FontWeight::BOLD)
            .into_any_element()
    } else {
        span.into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn describes_entries() {
        let entry = HistoryEntry {
            command: "make".into(),
            cwd: Some("/tmp".into()),
            exit_code: Some(2),
            started_at: Some(1000),
            duration_ms: Some(2500),
            imported: false,
        };
        assert_eq!(
            details(&entry, 1000 + 7200),
            Details {
                cwd: Some("/tmp".into()),
                ago: Some("2h ago".into()),
                exit_code: Some(2),
                duration: Some("2.5s".into()),
                imported: false,
            }
        );
        assert_eq!(ago(30), "just now");
        assert_eq!(ago(3 * 86_400), "3d ago");
    }
}
