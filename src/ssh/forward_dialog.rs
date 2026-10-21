//! Add or edit a port forward on an SSH host: local (`-L`), remote (`-R`) or SOCKS (`-D`).

use std::rc::Rc;

use gpui::{
    App, AppContext as _, Context, Entity, IntoElement, ParentElement as _, Render, Styled as _,
    Window, div, prelude::FluentBuilder as _, px,
};
use gpui_component::{
    ActiveTheme as _, Selectable as _, Sizable as _, WindowExt as _,
    button::{Button, ButtonGroup, ButtonVariants as _},
    dialog::DialogEntrance,
    h_flex,
    input::{Input, InputState},
    switch::Switch,
    v_flex,
};

use crate::{
    profiles::{Forward, ForwardKind, Profiles},
    project_dialog::{field, toggle_row},
    workspace::Id,
};

type OnSave = Rc<dyn Fn(Id, &mut Window, &mut App)>;

/// Open the dialog for `forward` on `host` (`id` 0: a new one). Saving stores it in the
/// profiles; `on_save` gets its id once the dialog has closed.
pub fn open(
    host: Id,
    forward: Forward,
    window: &mut Window,
    cx: &mut App,
    on_save: impl Fn(Id, &mut Window, &mut App) + 'static,
) {
    let title = if forward.id == 0 {
        "New port forward"
    } else {
        "Edit port forward"
    };
    let editor = cx.new(|cx| ForwardEditor::new(forward, window, cx));
    let on_save: OnSave = Rc::new(on_save);
    let bind = editor.read(cx).bind.clone();
    window.open_dialog(cx, move |dialog, _, _| {
        let (on_enter, on_click) = (
            (editor.clone(), on_save.clone()),
            (editor.clone(), on_save.clone()),
        );
        dialog
            .title(title)
            .w(px(440.))
            .entrance(DialogEntrance::FadeSlide)
            .on_ok(move |_, window, cx| submit(host, &on_enter.0, &on_enter.1, window, cx))
            .child(editor.clone())
            .footer(
                h_flex()
                    .w_full()
                    .justify_end()
                    .gap_2()
                    .child(
                        Button::new("forward-cancel")
                            .label("Cancel")
                            .on_click(|_, window, cx| window.close_dialog(cx)),
                    )
                    .child(
                        Button::new("forward-save")
                            .primary()
                            .label("Save")
                            .on_click(move |_, window, cx| {
                                if submit(host, &on_click.0, &on_click.1, window, cx) {
                                    window.close_dialog(cx);
                                }
                            }),
                    ),
            )
    });
    window.defer(cx, move |window, cx| {
        bind.update(cx, |input, cx| input.focus(window, cx))
    });
}

fn submit(
    host: Id,
    editor: &Entity<ForwardEditor>,
    on_save: &OnSave,
    window: &mut Window,
    cx: &mut App,
) -> bool {
    let forward = match editor.read(cx).forward(cx) {
        Ok(forward) => forward,
        Err(error) => {
            editor.update(cx, |editor, cx| {
                editor.error = Some(error);
                cx.notify();
            });
            return false;
        }
    };
    let Some(id) = Profiles::update(cx, |profiles| profiles.upsert_forward(host, forward)) else {
        return true;
    };
    let on_save = on_save.clone();
    window.defer(cx, move |window, cx| on_save(id, window, cx));
    true
}

struct ForwardEditor {
    original: Forward,
    name: Entity<InputState>,
    bind: Entity<InputState>,
    target: Entity<InputState>,
    kind: ForwardKind,
    show_logs: bool,
    error: Option<String>,
}

impl ForwardEditor {
    fn new(forward: Forward, window: &mut Window, cx: &mut Context<Self>) -> Self {
        Self {
            name: cx.new(|cx| {
                InputState::new(window, cx)
                    .placeholder("Database")
                    .default_value(forward.name.clone())
            }),
            bind: cx.new(|cx| {
                InputState::new(window, cx)
                    .placeholder("5433 or 127.0.0.1:5433")
                    .default_value(forward.bind.clone())
            }),
            target: cx.new(|cx| {
                InputState::new(window, cx)
                    .placeholder("localhost:5432")
                    .default_value(forward.target.clone())
            }),
            kind: forward.kind,
            show_logs: forward.show_logs,
            original: forward,
            error: None,
        }
    }

    fn forward(&self, cx: &App) -> Result<Forward, String> {
        let text = |input: &Entity<InputState>| input.read(cx).value().trim().to_owned();
        let bind = text(&self.bind);
        let port = bind.rsplit(':').next().unwrap_or_default();
        if port.parse::<u16>().map_or(true, |port| port == 0) {
            return Err(
                "Listen on a port from 1 to 65535, optionally after an address (127.0.0.1:5433)."
                    .into(),
            );
        }
        let target = text(&self.target);
        if self.kind != ForwardKind::Dynamic {
            let valid = target
                .rsplit_once(':')
                .is_some_and(|(host, port)| !host.is_empty() && port.parse::<u16>().is_ok());
            if !valid {
                return Err("Forward to host:port, e.g. localhost:5432.".into());
            }
        }
        Ok(Forward {
            id: self.original.id,
            name: text(&self.name),
            kind: self.kind,
            bind,
            target: if self.kind == ForwardKind::Dynamic {
                String::new()
            } else {
                target
            },
            show_logs: self.show_logs,
            enabled: self.original.enabled,
        })
    }
}

impl Render for ForwardEditor {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.theme();
        let (muted, danger) = (theme.muted_foreground, theme.danger);
        let kinds: Vec<ForwardKind> = ForwardKind::ALL.iter().map(|(kind, _)| *kind).collect();
        let (bind_label, help) = match self.kind {
            ForwardKind::Local => (
                "Local port",
                "Connections to this port on your Mac go through the server to the target.",
            ),
            ForwardKind::Remote => (
                "Server port",
                "Connections to this port on the server come back to the target, reached from your Mac.",
            ),
            ForwardKind::Dynamic => (
                "Local port",
                "A SOCKS proxy on this port sends traffic out through the server.",
            ),
        };
        v_flex()
            .gap_4()
            .child(field(
                "Type",
                v_flex()
                    .gap_1p5()
                    .child(
                        ButtonGroup::new("forward-kind")
                            .outline()
                            .small()
                            .children(ForwardKind::ALL.iter().enumerate().map(
                                |(index, (kind, label))| {
                                    Button::new(("forward-kind", index))
                                        .label(*label)
                                        .selected(*kind == self.kind)
                                },
                            ))
                            .on_click(cx.listener(move |this, clicked: &Vec<usize>, _, cx| {
                                if let Some(kind) =
                                    clicked.first().and_then(|index| kinds.get(*index))
                                {
                                    this.kind = *kind;
                                    cx.notify();
                                }
                            })),
                    )
                    .child(div().text_xs().text_color(muted).child(help)),
            ))
            .child(
                h_flex()
                    .gap_3()
                    .items_start()
                    .child(
                        div()
                            .flex_1()
                            .child(field(bind_label, Input::new(&self.bind))),
                    )
                    .when(self.kind != ForwardKind::Dynamic, |row| {
                        row.child(
                            div()
                                .flex_1()
                                .child(field("Target", Input::new(&self.target))),
                        )
                    }),
            )
            .child(field("Name", Input::new(&self.name)))
            .child(toggle_row(
                "Keep a connection log",
                "Shows ssh's log for this forward, to see why it fails.",
                Switch::new("forward-logs")
                    .checked(self.show_logs)
                    .on_click(cx.listener(|this, checked: &bool, _, cx| {
                        this.show_logs = *checked;
                        cx.notify();
                    })),
            ))
            .when_some(self.error.clone(), |form, error| {
                form.child(div().text_sm().text_color(danger).child(error))
            })
    }
}
