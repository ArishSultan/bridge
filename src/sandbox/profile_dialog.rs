//! Create or edit a sandbox profile: macOS's sandbox (what is readable and writable, hidden paths,
//! network, blocked programs, Keychain) or a Docker container (image, network, mounts, variables).

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
    input::{Input, InputState, Textarea, TextareaState},
    switch::Switch,
    v_flex,
};

use crate::{
    profiles::{Network, Profiles, SandboxEngine, SandboxProfile},
    project_dialog::{field, toggle_row},
    workspace::Id,
};

type OnSave = Rc<dyn Fn(SandboxProfile, &mut Window, &mut App)>;

/// Open the dialog for `profile`. `title` says what it edits; `deletable` offers Delete for a
/// saved profile. `on_save` gets the edited profile, to store, once the dialog has closed.
pub fn open(
    title: &'static str,
    profile: SandboxProfile,
    deletable: bool,
    window: &mut Window,
    cx: &mut App,
    on_save: impl Fn(SandboxProfile, &mut Window, &mut App) + 'static,
) {
    let existing = deletable.then_some(profile.id);
    let editor = cx.new(|cx| SandboxEditor::new(profile, window, cx));
    let on_save: OnSave = Rc::new(on_save);
    let name = editor.read(cx).name.clone();
    window.open_dialog(cx, move |dialog, _, _| {
        let on_click = (editor.clone(), on_save.clone());
        dialog
            .title(title)
            .w(px(520.))
            .entrance(DialogEntrance::FadeSlide)
            .child(editor.clone())
            .footer(
                h_flex()
                    .w_full()
                    .justify_end()
                    .gap_2()
                    .when_some(existing, |footer, id| {
                        footer
                            .child(
                                Button::new("sandbox-delete")
                                    .danger()
                                    .label("Delete")
                                    .on_click(move |_, window, cx| {
                                        Profiles::update(cx, |profiles| {
                                            profiles.remove_sandbox(id)
                                        });
                                        window.close_dialog(cx);
                                    }),
                            )
                            .child(div().flex_1())
                    })
                    .child(
                        Button::new("sandbox-cancel")
                            .label("Cancel")
                            .on_click(|_, window, cx| window.close_dialog(cx)),
                    )
                    .child(
                        Button::new("sandbox-save")
                            .primary()
                            .label("Save")
                            .on_click(move |_, window, cx| {
                                let profile = on_click.0.read(cx).profile(cx);
                                window.close_dialog(cx);
                                let on_save = on_click.1.clone();
                                window.defer(cx, move |window, cx| {
                                    on_save(profile.clone(), window, cx)
                                });
                            }),
                    ),
            )
    });
    window.defer(cx, move |window, cx| {
        name.update(cx, |input, cx| input.focus(window, cx))
    });
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum EngineChoice {
    Seatbelt,
    Docker,
}

struct SandboxEditor {
    id: Id,
    name: Entity<InputState>,
    engine: EngineChoice,
    // Seatbelt
    writable: Entity<TextareaState>,
    hidden: Entity<TextareaState>,
    blocked: Entity<InputState>,
    network: Network,
    block_keychain: bool,
    confine_reads: bool,
    readable: Entity<TextareaState>,
    allow_clipboard: bool,
    allow_open: bool,
    // Docker
    image: Entity<InputState>,
    docker_network: bool,
    mounts: Entity<TextareaState>,
    env: Entity<InputState>,
}

impl SandboxEditor {
    fn new(profile: SandboxProfile, window: &mut Window, cx: &mut Context<Self>) -> Self {
        // Each engine's fields start from the profile, or from that engine's defaults.
        let (seatbelt, docker, engine) = match &profile.engine {
            SandboxEngine::Seatbelt { .. } => (
                profile.engine.clone(),
                SandboxEngine::docker_defaults(),
                EngineChoice::Seatbelt,
            ),
            SandboxEngine::Docker { .. } => (
                SandboxEngine::seatbelt_defaults(),
                profile.engine.clone(),
                EngineChoice::Docker,
            ),
        };
        let SandboxEngine::Seatbelt {
            writable,
            hidden,
            network,
            blocked,
            block_keychain,
            confine_reads,
            readable,
            allow_clipboard,
            allow_open,
        } = seatbelt
        else {
            unreachable!("seatbelt fields come from a Seatbelt engine");
        };
        let SandboxEngine::Docker {
            image,
            network: docker_network,
            mounts,
            env,
        } = docker
        else {
            unreachable!("docker fields come from a Docker engine");
        };
        let lines = |items: Vec<String>, window: &mut Window, cx: &mut Context<Self>| {
            cx.new(|cx| {
                TextareaState::new(window, cx)
                    .rows(4)
                    .default_value(items.join("\n"))
            })
        };
        Self {
            id: profile.id,
            name: cx.new(|cx| {
                InputState::new(window, cx)
                    .placeholder("Agents")
                    .default_value(profile.name)
            }),
            engine,
            writable: lines(writable, window, cx),
            hidden: lines(hidden, window, cx),
            blocked: cx.new(|cx| {
                InputState::new(window, cx)
                    .placeholder("curl wget scp")
                    .default_value(blocked.join(" "))
            }),
            network,
            block_keychain,
            confine_reads,
            readable: lines(readable, window, cx),
            allow_clipboard,
            allow_open,
            image: cx.new(|cx| {
                InputState::new(window, cx)
                    .placeholder("ubuntu:24.04")
                    .default_value(image)
            }),
            docker_network,
            mounts: lines(mounts, window, cx),
            env: cx.new(|cx| {
                InputState::new(window, cx)
                    .placeholder("ANTHROPIC_API_KEY")
                    .default_value(env.join(" "))
            }),
        }
    }

    fn profile(&self, cx: &App) -> SandboxProfile {
        let lines = |state: &Entity<TextareaState>| -> Vec<String> {
            state
                .read(cx)
                .value()
                .lines()
                .map(str::trim)
                .filter(|line| !line.is_empty())
                .map(str::to_owned)
                .collect()
        };
        let words = |state: &Entity<InputState>| -> Vec<String> {
            state
                .read(cx)
                .value()
                .split([' ', ','])
                .map(str::trim)
                .filter(|word| !word.is_empty())
                .map(str::to_owned)
                .collect()
        };
        let engine = match self.engine {
            EngineChoice::Seatbelt => SandboxEngine::Seatbelt {
                writable: lines(&self.writable),
                hidden: lines(&self.hidden),
                network: self.network,
                blocked: words(&self.blocked),
                block_keychain: self.block_keychain,
                confine_reads: self.confine_reads,
                readable: lines(&self.readable),
                allow_clipboard: self.allow_clipboard,
                allow_open: self.allow_open,
            },
            EngineChoice::Docker => SandboxEngine::Docker {
                image: self.image.read(cx).value().trim().to_owned(),
                network: self.docker_network,
                mounts: lines(&self.mounts),
                env: words(&self.env),
            },
        };
        let name = self.name.read(cx).value().trim().to_owned();
        SandboxProfile {
            id: self.id,
            name: if name.is_empty() {
                "Sandbox".to_owned()
            } else {
                name
            },
            engine,
        }
    }

    fn render_seatbelt(&self, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let muted = cx.theme().muted_foreground;
        let networks: Vec<Network> = Network::ALL.iter().map(|(network, _)| *network).collect();
        v_flex()
            .gap_4()
            .child(toggle_row(
                "Confine reads to the project",
                "Programs (and agents) can only read the project, system folders and the paths below; other \
                 projects and the rest of your home folder stay out of reach. Names of paths stay visible.",
                Switch::new("sandbox-confine-reads").checked(self.confine_reads).on_click(cx.listener(|this, checked: &bool, _, cx| {
                    this.confine_reads = *checked;
                    cx.notify();
                })),
            ))
            .when(self.confine_reads, |form| {
                form.child(field(
                    "Also readable",
                    v_flex()
                        .gap_1()
                        .child(Textarea::new(&self.readable))
                        .child(div().text_xs().text_color(muted).child(
                            "One path per line: your shell's and toolchains' setup. Add a tool's folder here if it can't read its files.",
                        )),
                ))
            })
            .child(field(
                "Writable besides the project",
                v_flex()
                    .gap_1()
                    .child(Textarea::new(&self.writable))
                    .child(div().text_xs().text_color(muted).child("One path per line. Temporary folders are always writable.")),
            ))
            .child(field(
                "Hidden (cannot be read)",
                v_flex()
                    .gap_1()
                    .child(Textarea::new(&self.hidden))
                    .child(div().text_xs().text_color(muted).child("Credentials and keys an agent has no business reading.")),
            ))
            .child(field(
                "Network",
                ButtonGroup::new("sandbox-network")
                    .outline()
                    .small()
                    .children(Network::ALL.iter().enumerate().map(|(index, (network, label))| {
                        Button::new(("sandbox-network", index)).label(*label).selected(*network == self.network)
                    }))
                    .on_click(cx.listener(move |this, clicked: &Vec<usize>, _, cx| {
                        if let Some(network) = clicked.first().and_then(|index| networks.get(*index)) {
                            this.network = *network;
                            cx.notify();
                        }
                    })),
            ))
            .child(field(
                "Blocked programs",
                v_flex()
                    .gap_1()
                    .child(Input::new(&self.blocked))
                    .child(div().text_xs().text_color(muted).child(
                        "Names or paths, separated by spaces. A deterrent, not a guarantee: a program can be copied or \
                         its job done another way. Hiding files and cutting the network are the strong limits.",
                    )),
            ))
            .child(toggle_row(
                "Allow clipboard access",
                "Let programs read and set the clipboard. Pasting with ⌘V works either way: the app types it in.",
                Switch::new("sandbox-clipboard").checked(self.allow_clipboard).on_click(cx.listener(|this, checked: &bool, _, cx| {
                    this.allow_clipboard = *checked;
                    cx.notify();
                })),
            ))
            .child(toggle_row(
                "Allow opening apps and links",
                "Let programs open other apps, files or a browser (e.g. for a login). Opened apps run outside the sandbox.",
                Switch::new("sandbox-open").checked(self.allow_open).on_click(cx.listener(|this, checked: &bool, _, cx| {
                    this.allow_open = *checked;
                    cx.notify();
                })),
            ))
            .child(toggle_row(
                "Block Keychain access",
                "Stops programs from reading saved passwords and tokens through the Keychain.",
                Switch::new("sandbox-keychain").checked(self.block_keychain).on_click(cx.listener(|this, checked: &bool, _, cx| {
                    this.block_keychain = *checked;
                    cx.notify();
                })),
            ))
    }

    fn render_docker(&self, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let muted = cx.theme().muted_foreground;
        v_flex()
            .gap_4()
            .child(field(
                "Image",
                v_flex().gap_1().child(Input::new(&self.image)).child(
                    div()
                        .text_xs()
                        .text_color(muted)
                        .child("The terminal's folder is mounted at /workspace."),
                ),
            ))
            .child(toggle_row(
                "Network",
                "Let the container reach the network.",
                Switch::new("sandbox-docker-network")
                    .checked(self.docker_network)
                    .on_click(cx.listener(|this, checked: &bool, _, cx| {
                        this.docker_network = *checked;
                        cx.notify();
                    })),
            ))
            .child(field(
                "Extra mounts",
                v_flex().gap_1().child(Textarea::new(&self.mounts)).child(
                    div()
                        .text_xs()
                        .text_color(muted)
                        .child("One per line: host:container, or host:container:ro."),
                ),
            ))
            .child(field(
                "Pass variables",
                v_flex().gap_1().child(Input::new(&self.env)).child(
                    div()
                        .text_xs()
                        .text_color(muted)
                        .child("Names of environment variables to pass in, e.g. API keys."),
                ),
            ))
    }
}

impl Render for SandboxEditor {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let engines = [
            (EngineChoice::Seatbelt, "macOS sandbox"),
            (EngineChoice::Docker, "Docker container"),
        ];
        let choices: Vec<EngineChoice> = engines.iter().map(|(engine, _)| *engine).collect();
        let body = match self.engine {
            EngineChoice::Seatbelt => self.render_seatbelt(cx).into_any_element(),
            EngineChoice::Docker => self.render_docker(cx).into_any_element(),
        };
        v_flex()
            .gap_4()
            .child(field("Name", Input::new(&self.name)))
            .child(field(
                "Isolation",
                ButtonGroup::new("sandbox-engine")
                    .outline()
                    .small()
                    .children(engines.iter().enumerate().map(|(index, (engine, label))| {
                        Button::new(("sandbox-engine", index))
                            .label(*label)
                            .selected(*engine == self.engine)
                    }))
                    .on_click(cx.listener(move |this, clicked: &Vec<usize>, _, cx| {
                        if let Some(engine) = clicked.first().and_then(|index| choices.get(*index))
                        {
                            this.engine = *engine;
                            cx.notify();
                        }
                    })),
            ))
            .child(body)
    }
}
