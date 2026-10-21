//! Create or edit a terminal of a project. What every terminal has comes first (name, tag, whether it
//! is kept alive), then its type and only that type's settings: a shell (folder,
//! isolation), a task bound to one command (command, folder, isolation, start and restart), or an
//! SSH session (host). The type is chosen when the terminal is created and is fixed after that.

use std::{path::PathBuf, rc::Rc};

use gpui::{
    AnyElement, App, AppContext as _, Context, Entity, InteractiveElement as _, IntoElement,
    ParentElement as _, PathPromptOptions, Render, SharedString, StatefulInteractiveElement as _,
    Styled as _, Window, div, prelude::FluentBuilder as _, px,
};
use gpui_component::{
    ActiveTheme as _, Icon, Selectable as _, Sizable as _, WindowExt as _,
    button::{Button, ButtonGroup, ButtonVariants as _},
    dialog::DialogEntrance,
    h_flex,
    input::{Input, InputState},
    switch::Switch,
    v_flex,
};

use crate::{
    icons::IconName,
    profiles::{PROJECT_SANDBOX, Profiles},
    project_dialog::{field, toggle_row},
    workspace::{Id, Isolation, TerminalKind, TerminalSpec},
};

type OnSave = Rc<dyn Fn(TerminalSpec, &mut Window, &mut App)>;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum KindChoice {
    Shell,
    Task,
    Ssh,
}

const KINDS: [(KindChoice, &str); 3] = [
    (KindChoice::Shell, "Shell"),
    (KindChoice::Task, "Task"),
    (KindChoice::Ssh, "SSH"),
];

/// Open the dialog for `spec` in the project at `root`: to create a terminal (its type preselected
/// from `spec`) or, with `editing`, to change one (its type then fixed). `on_save` gets the
/// terminal once the dialog has closed.
/// `global`: a terminal of the Global window, in the home folder and never sandboxed.
pub fn open(
    editing: bool,
    global: bool,
    root: PathBuf,
    spec: TerminalSpec,
    window: &mut Window,
    cx: &mut App,
    on_save: impl Fn(TerminalSpec, &mut Window, &mut App) + 'static,
) {
    let editor = cx.new(|cx| TerminalEditor::new(root, spec, editing, global, window, cx));
    let on_save: OnSave = Rc::new(on_save);
    let focus = editor.read(cx).name.clone();
    let (title, action) = if editing {
        ("Edit terminal", "Save")
    } else {
        ("New terminal", "Create")
    };
    window.open_dialog(cx, move |dialog, _, _| {
        let (on_enter, on_click) = (
            (editor.clone(), on_save.clone()),
            (editor.clone(), on_save.clone()),
        );
        dialog
            .title(title)
            .w(px(480.))
            .entrance(DialogEntrance::FadeSlide)
            .on_ok(move |_, window, cx| submit(&on_enter.0, &on_enter.1, window, cx))
            .child(editor.clone())
            .footer(
                h_flex()
                    .w_full()
                    .justify_end()
                    .gap_2()
                    .child(
                        Button::new("terminal-cancel")
                            .label("Cancel")
                            .on_click(|_, window, cx| window.close_dialog(cx)),
                    )
                    .child(
                        Button::new("terminal-save")
                            .primary()
                            .label(action)
                            .on_click(move |_, window, cx| {
                                if submit(&on_click.0, &on_click.1, window, cx) {
                                    window.close_dialog(cx);
                                }
                            }),
                    ),
            )
    });
    window.defer(cx, move |window, cx| {
        focus.update(cx, |input, cx| input.focus(window, cx))
    });
}

fn submit(
    editor: &Entity<TerminalEditor>,
    on_save: &OnSave,
    window: &mut Window,
    cx: &mut App,
) -> bool {
    match editor.read(cx).spec(cx) {
        Ok(spec) => {
            let on_save = on_save.clone();
            window.defer(cx, move |window, cx| on_save(spec, window, cx));
            true
        }
        Err(error) => {
            editor.update(cx, |editor, cx| {
                editor.error = Some(error);
                cx.notify();
            });
            false
        }
    }
}

struct TerminalEditor {
    root: PathBuf,
    /// Editing an existing terminal: its type can no longer change.
    editing: bool,
    /// A terminal of the Global window: open, in the home folder.
    global: bool,
    kind: KindChoice,
    name: Entity<InputState>,
    tag: Entity<InputState>,
    command: Entity<InputState>,
    folder: Entity<InputState>,
    auto_start: bool,
    restart_on_exit: bool,
    host: Option<Id>,
    /// `None`: open (not sandboxed); `Some(None)`: the Project profile.
    sandbox: Option<Option<Id>>,
    background: bool,
    error: Option<String>,
}

impl TerminalEditor {
    fn new(
        root: PathBuf,
        spec: TerminalSpec,
        editing: bool,
        global: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let (kind, command, auto_start, restart_on_exit, host) = match &spec.kind {
            TerminalKind::Shell => (KindChoice::Shell, String::new(), false, false, None),
            TerminalKind::Task {
                command,
                auto_start,
                restart_on_exit,
            } => (
                KindChoice::Task,
                command.clone(),
                *auto_start,
                *restart_on_exit,
                None,
            ),
            TerminalKind::Ssh { host } => {
                (KindChoice::Ssh, String::new(), false, false, Some(*host))
            }
        };
        let sandbox = match spec.isolation {
            Isolation::Sandboxed { profile } => Some(profile),
            Isolation::Open => None,
        };
        let input = |value: String,
                     placeholder: &'static str,
                     window: &mut Window,
                     cx: &mut Context<Self>| {
            cx.new(|cx| {
                InputState::new(window, cx)
                    .placeholder(placeholder)
                    .default_value(value)
            })
        };
        Self {
            root,
            editing,
            global,
            kind,
            name: input(spec.name, "Named after what it runs", window, cx),
            tag: input(spec.tag.unwrap_or_default(), "api", window, cx),
            command: input(command, "npx nx serve api", window, cx),
            folder: input(spec.folder, ".", window, cx),
            auto_start,
            restart_on_exit,
            host,
            sandbox,
            background: spec.background,
            error: None,
        }
    }

    fn spec(&self, cx: &App) -> Result<TerminalSpec, String> {
        let text = |input: &Entity<InputState>| input.read(cx).value().trim().to_owned();
        let kind = match self.kind {
            KindChoice::Shell => TerminalKind::Shell,
            KindChoice::Task => {
                let command = text(&self.command);
                if command.is_empty() {
                    return Err("Enter the command this terminal runs.".into());
                }
                TerminalKind::Task {
                    command,
                    auto_start: self.auto_start,
                    restart_on_exit: self.restart_on_exit,
                }
            }
            KindChoice::Ssh => TerminalKind::Ssh {
                host: self
                    .host
                    .ok_or("Choose an SSH host (add hosts in Global).")?,
            },
        };
        let folder = match text(&self.folder) {
            folder if folder.is_empty() || self.kind == KindChoice::Ssh => ".".to_owned(),
            folder => folder,
        };
        if !self.root.join(&folder).is_dir()
            || folder.starts_with('/')
            || folder.split('/').any(|part| part == "..")
        {
            return Err("The folder must be inside the project.".into());
        }
        let tag = Some(text(&self.tag)).filter(|tag| !tag.is_empty());
        Ok(TerminalSpec {
            name: text(&self.name),
            tag,
            kind,
            folder,
            isolation: match self.sandbox.filter(|_| !self.global) {
                Some(profile) => Isolation::Sandboxed { profile },
                None => Isolation::Open,
            },
            background: self.background,
        })
    }

    fn browse(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let paths = cx.prompt_for_paths(PathPromptOptions {
            files: false,
            directories: true,
            multiple: false,
            prompt: Some("Choose".into()),
        });
        let root = self
            .root
            .canonicalize()
            .unwrap_or_else(|_| self.root.clone());
        cx.spawn_in(window, async move |this, cx| {
            if let Ok(Ok(Some(paths))) = paths.await
                && let Some(dir) = paths.into_iter().next()
            {
                let _ = this.update_in(cx, |this, window, cx| {
                    let dir = dir.canonicalize().unwrap_or(dir);
                    match dir.strip_prefix(&root) {
                        Ok(relative) => {
                            let relative = if relative.as_os_str().is_empty() {
                                ".".to_owned()
                            } else {
                                relative.to_string_lossy().into_owned()
                            };
                            this.folder.update(cx, |input, cx| {
                                input.set_value(SharedString::from(relative), window, cx)
                            });
                            this.error = None;
                        }
                        Err(_) => this.error = Some("Choose a folder inside the project.".into()),
                    }
                    cx.notify();
                });
            }
        })
        .detach();
    }

    /// A list of choices, the chosen one checked.
    fn choice_list(
        &self,
        id: &'static str,
        rows: Vec<(String, bool)>,
        cx: &mut Context<Self>,
        pick: impl Fn(&mut Self, usize) + Clone + 'static,
    ) -> AnyElement {
        let theme = cx.theme();
        let (muted, accent, border) = (theme.muted_foreground, theme.accent, theme.border);
        v_flex()
            .id(id)
            .max_h(px(132.))
            .overflow_y_scroll()
            .rounded_md()
            .border_1()
            .border_color(border)
            .p_1()
            .children(
                rows.into_iter()
                    .enumerate()
                    .map(|(index, (label, selected))| {
                        let pick = pick.clone();
                        h_flex()
                            .id((id, index))
                            .h(px(28.))
                            .px_2()
                            .gap_2()
                            .rounded_sm()
                            .cursor_pointer()
                            .text_sm()
                            .when(selected, |row| row.bg(accent))
                            .hover(move |style| style.bg(accent))
                            .on_click(cx.listener(move |this, _, _, cx| {
                                pick(this, index);
                                cx.notify();
                            }))
                            .child(
                                Icon::new(if selected {
                                    IconName::CircleCheck
                                } else {
                                    IconName::Circle
                                })
                                .small()
                                .text_color(muted),
                            )
                            .child(div().flex_1().min_w_0().truncate().child(label))
                    }),
            )
            .into_any_element()
    }
}

fn kind_icon(kind: KindChoice) -> IconName {
    match kind {
        KindChoice::Shell => IconName::SquareTerminal,
        KindChoice::Task => IconName::Play,
        KindChoice::Ssh => IconName::Server,
    }
}

impl Render for TerminalEditor {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.theme();
        let (muted, danger, warning) = (theme.muted_foreground, theme.danger, theme.warning);
        let border = theme.border;

        // What every terminal has.
        let mut form = v_flex()
            .gap_4()
            .child(
                h_flex()
                    .gap_3()
                    .child(div().flex_1().child(field("Name", Input::new(&self.name))))
                    .child(div().w(px(140.)).child(field("Tag", Input::new(&self.tag)))),
            )
            .child(toggle_row(
                "Keep alive",
                "Keeps running when you switch to another terminal or view. Otherwise switching away stops it (after asking).",
                Switch::new("terminal-background").checked(self.background).on_click(cx.listener(|this, checked: &bool, _, cx| {
                    this.background = *checked;
                    cx.notify();
                })),
            ));

        // Its type: chosen once, when the terminal is created.
        let label = KINDS
            .iter()
            .find(|(kind, _)| *kind == self.kind)
            .map_or("", |(_, label)| *label);
        let kind_field = if self.editing {
            field(
                "Type",
                h_flex()
                    .gap_2()
                    .text_sm()
                    .child(Icon::new(kind_icon(self.kind)).small().text_color(muted))
                    .child(label)
                    .child(
                        div()
                            .text_xs()
                            .text_color(muted)
                            .child("— fixed; delete it and create another to change the type"),
                    ),
            )
            .into_any_element()
        } else {
            let kinds: Vec<KindChoice> = KINDS.iter().map(|(kind, _)| *kind).collect();
            field(
                "Type",
                ButtonGroup::new("terminal-kind")
                    .outline()
                    .small()
                    .children(KINDS.iter().enumerate().map(|(index, (kind, label))| {
                        Button::new(("terminal-kind", index))
                            .icon(kind_icon(*kind))
                            .label(*label)
                            .selected(*kind == self.kind)
                    }))
                    .on_click(cx.listener(move |this, clicked: &Vec<usize>, _, cx| {
                        if let Some(kind) = clicked.first().and_then(|index| kinds.get(*index)) {
                            this.kind = *kind;
                            cx.notify();
                        }
                    })),
            )
            .into_any_element()
        };
        form = form.child(
            div()
                .pt_4()
                .border_t_1()
                .border_color(border)
                .child(kind_field),
        );

        // Only what this type needs.
        match self.kind {
            KindChoice::Task => {
                form = form.child(field("Command", Input::new(&self.command)));
            }
            KindChoice::Ssh => {
                let hosts: Vec<(Id, String)> = Profiles::get(cx)
                    .hosts
                    .iter()
                    .map(|host| (host.id, format!("{}  ·  {}", host.name, host.address())))
                    .collect();
                let picker = if hosts.is_empty() {
                    div()
                        .text_xs()
                        .text_color(muted)
                        .child("No SSH hosts yet: add them in Global.")
                        .into_any_element()
                } else {
                    let ids: Vec<Id> = hosts.iter().map(|(id, _)| *id).collect();
                    let rows = hosts
                        .into_iter()
                        .map(|(id, label)| (label, self.host == Some(id)))
                        .collect();
                    self.choice_list("terminal-hosts", rows, cx, move |this, index| {
                        this.host = ids.get(index).copied()
                    })
                };
                form = form.child(field("Host", picker));
            }
            KindChoice::Shell => {}
        }

        if self.kind != KindChoice::Ssh {
            form = form.child(field(
                if self.global {
                    "Folder in your home folder"
                } else {
                    "Folder in the project"
                },
                h_flex()
                    .gap_2()
                    .child(div().flex_1().child(Input::new(&self.folder)))
                    .child(
                        Button::new("terminal-browse")
                            .label("Browse")
                            .on_click(cx.listener(|this, _, window, cx| this.browse(window, cx))),
                    ),
            ));
        }

        if self.kind != KindChoice::Ssh && !self.global {
            // Sandboxed first and by default; "Open" is the deliberate exception.
            let mut options: Vec<(Option<Option<Id>>, String)> = vec![(
                Some(None),
                format!("{PROJECT_SANDBOX} sandbox (writes only inside the project)"),
            )];
            options.extend(
                Profiles::get(cx)
                    .sandboxes
                    .iter()
                    .map(|profile| (Some(Some(profile.id)), format!("{} sandbox", profile.name))),
            );
            options.push((None, "Open — not sandboxed".to_owned()));
            let values: Vec<Option<Option<Id>>> = options.iter().map(|(value, _)| *value).collect();
            let rows = options
                .into_iter()
                .map(|(value, label)| (label, value == self.sandbox))
                .collect();
            form = form.child(field(
                "Isolation",
                v_flex()
                    .gap_1()
                    .child(
                        self.choice_list("terminal-isolation", rows, cx, move |this, index| {
                            if let Some(value) = values.get(index) {
                                this.sandbox = *value;
                            }
                        }),
                    )
                    .when(self.sandbox.is_none(), |column| {
                        column.child(
                            div().text_xs().text_color(warning).child(
                                "Open terminals can read and change anything your user can.",
                            ),
                        )
                    }),
            ));
        }

        if self.kind == KindChoice::Task {
            form = form
                .child(toggle_row(
                    "Start when it is opened",
                    "Otherwise it waits for ▶.",
                    Switch::new("terminal-auto-start")
                        .checked(self.auto_start)
                        .on_click(cx.listener(|this, checked: &bool, _, cx| {
                            this.auto_start = *checked;
                            cx.notify();
                        })),
                ))
                .child(toggle_row(
                    "Restart when it exits",
                    "Start it again a moment after it stops on its own.",
                    Switch::new("terminal-restart")
                        .checked(self.restart_on_exit)
                        .on_click(cx.listener(|this, checked: &bool, _, cx| {
                            this.restart_on_exit = *checked;
                            cx.notify();
                        })),
                ));
        }
        form.when_some(self.error.clone(), |form, error| {
            form.child(div().text_sm().text_color(danger).child(error))
        })
    }
}
