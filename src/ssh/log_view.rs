//! A forward's connection log, live, newest at the bottom (shown in a sheet).

use gpui::{
    Context, Entity, IntoElement, ParentElement as _, Render, ScrollStrategy, Styled as _,
    Subscription, UniformListScrollHandle, Window, div, px, uniform_list,
};
use gpui_component::{ActiveTheme as _, v_flex};

use super::forward::ForwardManager;
use crate::workspace::Id;

pub struct LogView {
    forward: Id,
    manager: Entity<ForwardManager>,
    scroll: UniformListScrollHandle,
    /// Lines shown last render, to follow new ones.
    shown: usize,
    _subscription: Subscription,
}

impl LogView {
    pub fn new(forward: Id, manager: Entity<ForwardManager>, cx: &mut Context<Self>) -> Self {
        let subscription = cx.observe(&manager, |_, _, cx| cx.notify());
        Self {
            forward,
            manager,
            scroll: UniformListScrollHandle::new(),
            shown: 0,
            _subscription: subscription,
        }
    }
}

impl Render for LogView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let lines = self.manager.read(cx).logs(self.forward);
        let status = self.manager.read(cx).status(self.forward).describe();
        if lines.len() != self.shown {
            self.shown = lines.len();
            self.scroll
                .scroll_to_item(lines.len().saturating_sub(1), ScrollStrategy::Bottom);
        }
        let muted = cx.theme().muted_foreground;
        let count = lines.len();
        v_flex()
            .size_full()
            .gap_2()
            .pb_4()
            .child(div().text_sm().text_color(muted).child(status))
            .child(
                uniform_list("forward-log", count, move |range, _, _| {
                    range
                        .filter_map(|index| lines.get(index).cloned())
                        .map(|line| {
                            div()
                                .h(px(18.))
                                .text_xs()
                                .font_family("Menlo")
                                .whitespace_nowrap()
                                .child(line)
                        })
                        .collect()
                })
                .track_scroll(&self.scroll)
                .flex_1(),
            )
    }
}
