//! The Welcome window: shown when no other window is open. Opens a folder as a project, one of the
//! projects opened before, or the Global window.

use gpui::{
    BorrowAppContext as _, Context, FontWeight, InteractiveElement, IntoElement, ParentElement,
    Render, SharedString, StatefulInteractiveElement, Styled, Window, div, px,
};
use gpui_component::{
    ActiveTheme, Icon, Sizable, TitleBar,
    button::{Button, ButtonVariants},
    h_flex,
    menu::{ContextMenuExt, PopupMenuItem},
    v_flex,
};

use crate::{
    app,
    icons::IconName,
    project_dialog,
    workspace::{Id, Projects},
    workspace_view::{APP_NAME, ClosePane, OpenSettings},
};

pub struct WelcomeView {
    _subscriptions: Vec<gpui::Subscription>,
}

impl WelcomeView {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        window.set_window_title(APP_NAME);
        Self {
            _subscriptions: vec![
                cx.observe_global::<Projects>(|_, cx| cx.notify()),
                crate::track_appearance(window, cx),
            ],
        }
    }

    /// Forget a project (its folder is untouched). An open project stays.
    fn remove(&mut self, project: Id, cx: &mut Context<Self>) {
        if app::is_open(project, cx) {
            return;
        }
        cx.update_global::<Projects, _>(|projects, _| {
            projects.remove_project(project);
            if let Err(err) = projects.save() {
                eprintln!("failed to save projects: {err}");
            }
        });
        cx.notify();
    }
}

impl Render for WelcomeView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.theme();
        let (chrome, muted, hover, foreground) = (
            theme.title_bar,
            theme.muted_foreground,
            theme.sidebar_accent.opacity(0.6),
            theme.sidebar_foreground,
        );
        let projects = cx.global::<Projects>().projects.clone();
        let rows: Vec<_> = projects
            .iter()
            .map(|project| {
                let id = project.id;
                let color = project
                    .color
                    .as_deref()
                    .and_then(|color| crate::theme::group_color(color, cx));
                let tile = project_dialog::group_tile(project.icon.as_deref(), color, px(20.), cx);
                let dir = SharedString::from(project.dir.clone());
                let weak = cx.entity().downgrade();
                h_flex()
                    .id(("recent", id))
                    .h(px(40.))
                    .px_2()
                    .gap_2p5()
                    .rounded_md()
                    .cursor_pointer()
                    .hover(move |style| style.bg(hover))
                    .on_click(move |_, _, cx| app::open_project(id, false, cx))
                    .child(tile)
                    .child(
                        v_flex()
                            .min_w_0()
                            .child(
                                div()
                                    .text_sm()
                                    .font_weight(FontWeight::MEDIUM)
                                    .truncate()
                                    .child(project.name.clone()),
                            )
                            .child(div().text_xs().text_color(muted).truncate().child(dir)),
                    )
                    .context_menu(move |menu, _, _| {
                        let weak = weak.clone();
                        menu.item(
                            PopupMenuItem::new("Remove from list")
                                .icon(IconName::Trash)
                                .on_click(move |_, _, cx| {
                                    let _ = weak.update(cx, |this, cx| this.remove(id, cx));
                                }),
                        )
                    })
            })
            .collect();
        let empty = rows.is_empty().then(|| {
            div()
                .py_6()
                .text_sm()
                .text_color(muted)
                .child("A project is a folder. Open one to start.")
        });
        v_flex()
            .size_full()
            .bg(chrome)
            .text_color(foreground)
            .on_action(|_: &ClosePane, window, _| window.remove_window())
            .on_action(cx.listener(|_, _: &OpenSettings, window, cx| {
                crate::settings_panel::open(window, cx)
            }))
            .child(
                TitleBar::new()
                    .bg(gpui::transparent_black())
                    .border_color(gpui::transparent_black()),
            )
            .child(
                v_flex()
                    .flex_1()
                    .min_h_0()
                    .px_6()
                    .pb_6()
                    .gap_4()
                    .child(
                        h_flex()
                            .gap_3()
                            .child(
                                Icon::new(IconName::SquareTerminal)
                                    .size(px(32.))
                                    .text_color(theme.ring),
                            )
                            .child(
                                v_flex()
                                    .child(
                                        div()
                                            .text_lg()
                                            .font_weight(FontWeight::SEMIBOLD)
                                            .child(APP_NAME),
                                    )
                                    .child(
                                        div()
                                            .text_sm()
                                            .text_color(muted)
                                            .child("Your projects, servers and terminals"),
                                    ),
                            ),
                    )
                    .child(
                        h_flex()
                            .gap_2()
                            .child(
                                Button::new("welcome-open")
                                    .primary()
                                    .small()
                                    .icon(IconName::FolderOpen)
                                    .label("Open Folder")
                                    .tooltip("Open a folder as a project (⌘O)")
                                    .on_click(|_, _, cx| app::open_folder(cx)),
                            )
                            .child(
                                Button::new("welcome-global")
                                    .small()
                                    .icon(IconName::Globe)
                                    .label("Global")
                                    .tooltip("SSH hosts, port forwards and sandboxes")
                                    .on_click(|_, _, cx| app::open_global(cx)),
                            ),
                    )
                    .child(
                        div()
                            .text_xs()
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(muted)
                            .child("RECENT PROJECTS"),
                    )
                    .child(
                        div()
                            .id("recent-projects")
                            .flex_1()
                            .min_h_0()
                            .overflow_y_scroll()
                            .child(v_flex().gap_0p5().children(rows).children(empty)),
                    ),
            )
    }
}
