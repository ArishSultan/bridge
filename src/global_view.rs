//! What every project shares, in the Global window's sidebar: SSH hosts with their port forwards,
//! the Vaultwarden lock, and sandbox profiles.

use gpui::{
    AnyElement, App, AppContext as _, Context, FontWeight, InteractiveElement, IntoElement,
    ParentElement, Render, SharedString, StatefulInteractiveElement, Styled, Window, div,
    prelude::FluentBuilder as _, px,
};
use gpui_component::{
    ActiveTheme, Icon, Sizable, h_flex,
    menu::{ContextMenuExt, PopupMenuItem},
    switch::Switch,
    tooltip::Tooltip,
    v_flex,
};

use crate::{
    app,
    icons::IconName,
    profiles::{Forward, PROJECT_SANDBOX, Profiles, SandboxEngine, SandboxProfile, keychain},
    sandbox, sheet,
    ssh::{self, forward::Status, log_view::LogView},
    vault::{self, Vault},
    workspace::Id,
    workspace_view::{icon_button, update},
};

pub struct PresetsPanel {
    _subscriptions: Vec<gpui::Subscription>,
}

impl PresetsPanel {
    pub fn new(cx: &mut Context<Self>) -> Self {
        let forwards = app::forwards(cx);
        Self {
            _subscriptions: vec![
                cx.observe(&forwards, |_, _, cx| cx.notify()),
                cx.observe_global::<Vault>(|_, cx| cx.notify()),
                cx.observe_global::<Profiles>(|_, cx| cx.notify()),
            ],
        }
    }

    /// Register a new SSH host, or edit one.
    fn edit_host(&mut self, host: Option<Id>, window: &mut Window, cx: &mut Context<Self>) {
        let existing = host.and_then(|host| Profiles::get(cx).host(host).cloned());
        let weak = cx.entity().downgrade();
        ssh::host_dialog::open(
            existing.unwrap_or_default(),
            window,
            cx,
            move |id, window, cx| {
                update(&weak, window, cx, |_, _, cx| {
                    // Running forwards pick up the new address and sign-in.
                    let forwards: Vec<Id> = Profiles::get(cx)
                        .host(id)
                        .map(|host| host.forwards.iter().map(|forward| forward.id).collect())
                        .unwrap_or_default();
                    app::forwards(cx).update(cx, |manager, cx| {
                        for forward in forwards {
                            manager.reload(forward, cx);
                        }
                    });
                    cx.notify();
                });
            },
        );
    }

    fn delete_host(&mut self, host: Id, cx: &mut Context<Self>) {
        let forwards: Vec<Id> = Profiles::get(cx)
            .host(host)
            .map(|host| host.forwards.iter().map(|forward| forward.id).collect())
            .unwrap_or_default();
        app::forwards(cx).update(cx, |manager, cx| {
            for forward in forwards {
                manager.remove(forward, cx);
            }
        });
        Profiles::update(cx, |profiles| profiles.remove_host(host));
        keychain::delete_password(host);
        cx.notify();
    }

    /// Add a port forward to `host`, or edit one.
    fn edit_forward(
        &mut self,
        host: Id,
        forward: Option<Id>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let existing = forward.and_then(|forward| {
            Profiles::get(cx)
                .forward(forward)
                .map(|(_, forward)| forward.clone())
        });
        let weak = cx.entity().downgrade();
        ssh::forward_dialog::open(
            host,
            existing.unwrap_or_default(),
            window,
            cx,
            move |id, window, cx| {
                update(&weak, window, cx, |_, _, cx| {
                    app::forwards(cx).update(cx, |forwards, cx| forwards.reload(id, cx));
                    cx.notify();
                });
            },
        );
    }

    fn delete_forward(&mut self, forward: Id, cx: &mut Context<Self>) {
        app::forwards(cx).update(cx, |forwards, cx| forwards.remove(forward, cx));
        Profiles::update(cx, |profiles| profiles.remove_forward(forward));
        cx.notify();
    }

    fn show_forward_logs(&mut self, forward: Id, window: &mut Window, cx: &mut Context<Self>) {
        let title = Profiles::get(cx).forward(forward).map_or_else(
            || "Connection log".to_owned(),
            |(_, forward)| format!("{} — log", forward_name(forward)),
        );
        let manager = app::forwards(cx);
        let view = cx.new(|cx| LogView::new(forward, manager, cx));
        sheet::open(title, px(620.), window, cx, move |_, _| {
            view.clone().into_any_element()
        });
    }

    /// Edit a sandbox profile (`None`: the built-in Project one), or create one (`Some(0)`).
    fn edit_sandbox(&mut self, profile: Option<Id>, window: &mut Window, cx: &mut Context<Self>) {
        let (title, sandbox, deletable) = match profile {
            None => (
                "Edit Project sandbox",
                Profiles::get(cx).project_profile(),
                false,
            ),
            Some(0) => (
                "New sandbox profile",
                SandboxProfile {
                    id: 0,
                    name: "Agents".into(),
                    engine: SandboxEngine::seatbelt_defaults(),
                },
                false,
            ),
            Some(id) => match Profiles::get(cx).sandbox(id).cloned() {
                Some(sandbox) => ("Edit sandbox profile", sandbox, true),
                None => return,
            },
        };
        let builtin = profile.is_none();
        let weak = cx.entity().downgrade();
        sandbox::profile_dialog::open(
            title,
            sandbox,
            deletable,
            window,
            cx,
            move |sandbox, window, cx| {
                Profiles::update(cx, |profiles| {
                    if builtin {
                        profiles.project_sandbox = Some(sandbox.engine);
                    } else {
                        profiles.upsert_sandbox(sandbox);
                    }
                });
                update(&weak, window, cx, |_, _, cx| cx.notify());
            },
        );
    }

    /// A section heading, with an add button.
    fn section_header(
        &self,
        id: &'static str,
        title: &'static str,
        extra: Option<AnyElement>,
        on_add: impl Fn(&mut Self, &mut Window, &mut Context<Self>) + 'static,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let muted = cx.theme().muted_foreground;
        h_flex()
            .group(id)
            .h(px(28.))
            .pl_2()
            .pr_1()
            .gap_1()
            .text_xs()
            .font_weight(FontWeight::MEDIUM)
            .text_color(muted)
            .child(title)
            .child(div().flex_1())
            .children(extra)
            .child(
                div()
                    .opacity(0.)
                    .group_hover(id, |style| style.opacity(1.))
                    .child(
                        icon_button((id, 0usize), IconName::Plus, "Add")
                            .xsmall()
                            .on_click(
                                cx.listener(move |this, _, window, cx| on_add(this, window, cx)),
                            ),
                    ),
            )
            .into_any_element()
    }

    /// Vaultwarden's lock: click to unlock (or link an account), or to lock.
    fn render_vault_button(&self, cx: &mut Context<Self>) -> AnyElement {
        let unlocked = Vault::is_unlocked(cx);
        let server = Profiles::get(cx)
            .vault
            .as_ref()
            .map(|account| account.server.clone());
        let keys = Vault::keys(cx).len();
        let tooltip: SharedString = match (unlocked, server) {
            (true, server) => format!(
                "Vaultwarden unlocked ({keys} SSH key{}, {}) — click to lock",
                if keys == 1 { "" } else { "s" },
                server.unwrap_or_default()
            )
            .into(),
            (false, Some(server)) => {
                format!("Vaultwarden locked ({server}) — click to unlock or change the server")
                    .into()
            }
            (false, None) => "Link Vaultwarden to use its SSH keys".into(),
        };
        let success = cx.theme().success;
        icon_button(
            "vault-lock",
            if unlocked {
                IconName::LockOpen
            } else {
                IconName::Lock
            },
            "",
        )
        .xsmall()
        .when(unlocked, |button| button.text_color(success))
        .tooltip(tooltip)
        .on_click(cx.listener(move |_, _, window, cx| {
            cx.stop_propagation();
            if unlocked {
                Vault::lock(cx);
            } else {
                vault::unlock_dialog::open(window, cx, |_, _| {});
            }
        }))
        .into_any_element()
    }

    /// Global SSH hosts and their port forwards.
    fn render_ssh_section(&self, cx: &mut Context<Self>) -> AnyElement {
        let theme = cx.theme();
        let (muted, foreground, hover) = (
            theme.muted_foreground,
            theme.sidebar_foreground,
            theme.sidebar_accent.opacity(0.6),
        );
        let vault_button = self.render_vault_button(cx);
        let header = self.section_header(
            "ssh-header",
            "SSH HOSTS",
            Some(vault_button),
            |this, window, cx| this.edit_host(None, window, cx),
            cx,
        );
        let registered = Profiles::get(cx).hosts.clone();
        let hosts: Vec<AnyElement> = registered
            .iter()
            .map(|host| {
                let (id, address) = (host.id, SharedString::from(host.address()));
                let weak = cx.entity().downgrade();
                let row =
                    h_flex()
                        .id(("ssh-host", id))
                        .h(px(30.))
                        .pl_2()
                        .pr_1()
                        .gap_2()
                        .rounded_md()
                        .cursor_pointer()
                        .text_sm()
                        .text_color(foreground.opacity(0.85))
                        .hover(move |style| style.bg(hover))
                        .tooltip(move |window, cx| Tooltip::new(address.clone()).build(window, cx))
                        .on_click(cx.listener(move |this, _, window, cx| {
                            this.edit_host(Some(id), window, cx)
                        }))
                        .child(Icon::new(IconName::Server).small().text_color(muted))
                        .child(div().flex_1().min_w_0().truncate().child(host.name.clone()))
                        .context_menu(move |menu, _, _| {
                            let (add, edit, delete) = (weak.clone(), weak.clone(), weak.clone());
                            menu.item(
                                PopupMenuItem::new("Add port forward")
                                    .icon(IconName::Cable)
                                    .on_click(move |_, window, cx| {
                                        update(&add, window, cx, |this, window, cx| {
                                            this.edit_forward(id, None, window, cx)
                                        });
                                    }),
                            )
                            .item(
                                PopupMenuItem::new("Edit host")
                                    .icon(IconName::Pencil)
                                    .on_click(move |_, window, cx| {
                                        update(&edit, window, cx, |this, window, cx| {
                                            this.edit_host(Some(id), window, cx)
                                        });
                                    }),
                            )
                            .separator()
                            .item(
                                PopupMenuItem::new("Delete host")
                                    .icon(IconName::Trash)
                                    .on_click(move |_, window, cx| {
                                        update(&delete, window, cx, |this, _, cx| {
                                            this.delete_host(id, cx)
                                        });
                                    }),
                            )
                        })
                        .into_any_element();
                let forwards = host
                    .forwards
                    .iter()
                    .map(|forward| self.render_forward(id, forward, cx));
                v_flex()
                    .gap_0p5()
                    .child(row)
                    .children(forwards)
                    .into_any_element()
            })
            .collect();
        let empty = hosts.is_empty().then(|| {
            add_row("add-ssh-host", "Add SSH host", cx)
                .on_click(cx.listener(|this, _, window, cx| this.edit_host(None, window, cx)))
        });
        v_flex()
            .gap_0p5()
            .child(header)
            .children(hosts)
            .children(empty)
            .into_any_element()
    }

    /// A port forward under its host: status dot, name, logs button and on/off switch.
    fn render_forward(&self, host: Id, forward: &Forward, cx: &mut Context<Self>) -> AnyElement {
        let theme = cx.theme();
        let status = app::forwards(cx).read(cx).status(forward.id);
        let (muted, foreground, hover) = (
            theme.muted_foreground,
            theme.sidebar_foreground,
            theme.sidebar_accent.opacity(0.6),
        );
        let dot = match status {
            Status::Up => theme.success,
            Status::Connecting | Status::Retrying(_) => theme.warning,
            Status::Failed(_) => theme.danger,
            Status::Off => muted.opacity(0.5),
        };
        let id = forward.id;
        let enabled = forward.enabled;
        let tooltip = SharedString::from(format!("{}\n{}", forward.summary(), status.describe()));
        let weak = cx.entity().downgrade();
        let row_group = SharedString::from(format!("forward-row-{id}"));
        h_flex()
            .id(("forward", id))
            .group(row_group.clone())
            .h(px(28.))
            .ml(px(22.))
            .pl_2()
            .pr_1()
            .gap_2()
            .rounded_md()
            .text_xs()
            .text_color(foreground.opacity(0.85))
            .hover(move |style| style.bg(hover))
            .tooltip(move |window, cx| Tooltip::new(tooltip.clone()).build(window, cx))
            .child(div().flex_none().size(px(7.)).rounded_full().bg(dot))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .truncate()
                    .child(forward_name(forward)),
            )
            .when(forward.show_logs, |row| {
                row.child(
                    div()
                        .opacity(0.)
                        .group_hover(row_group, |style| style.opacity(1.))
                        .child(
                            icon_button(
                                ("forward-logs", id),
                                IconName::ScrollText,
                                "Connection log",
                            )
                            .xsmall()
                            .on_click(cx.listener(
                                move |this, _, window, cx| this.show_forward_logs(id, window, cx),
                            )),
                        ),
                )
            })
            .child(
                Switch::new(("forward-switch", id))
                    .xsmall()
                    .checked(enabled)
                    .on_click(cx.listener(move |_, checked: &bool, _, cx| {
                        app::forwards(cx)
                            .update(cx, |forwards, cx| forwards.set_enabled(id, *checked, cx));
                    })),
            )
            .context_menu(move |menu, _, _| {
                let (edit, logs, delete) = (weak.clone(), weak.clone(), weak.clone());
                menu.item(
                    PopupMenuItem::new("Edit port forward")
                        .icon(IconName::Pencil)
                        .on_click(move |_, window, cx| {
                            update(&edit, window, cx, |this, window, cx| {
                                this.edit_forward(host, Some(id), window, cx)
                            });
                        }),
                )
                .item(
                    PopupMenuItem::new("Connection log")
                        .icon(IconName::ScrollText)
                        .on_click(move |_, window, cx| {
                            update(&logs, window, cx, |this, window, cx| {
                                this.show_forward_logs(id, window, cx)
                            });
                        }),
                )
                .separator()
                .item(
                    PopupMenuItem::new("Delete port forward")
                        .icon(IconName::Trash)
                        .on_click(move |_, window, cx| {
                            update(&delete, window, cx, |this, _, cx| {
                                this.delete_forward(id, cx)
                            });
                        }),
                )
            })
            .into_any_element()
    }

    /// Sandbox profiles: the built-in Project one, and any made for agents.
    fn render_sandboxes_section(&self, cx: &mut Context<Self>) -> AnyElement {
        let header = self.section_header(
            "sandbox-header",
            "SANDBOXES",
            None,
            |this, window, cx| this.edit_sandbox(Some(0), window, cx),
            cx,
        );
        let profiles = Profiles::get(cx);
        let mut rows: Vec<(Option<Id>, String, &'static str)> = vec![(
            None,
            format!("{PROJECT_SANDBOX} (default)"),
            engine_label(&profiles.project_profile().engine),
        )];
        rows.extend(profiles.sandboxes.iter().map(|profile| {
            (
                Some(profile.id),
                profile.name.clone(),
                engine_label(&profile.engine),
            )
        }));
        let theme = cx.theme();
        let (muted, foreground, hover) = (
            theme.muted_foreground,
            theme.sidebar_foreground,
            theme.sidebar_accent.opacity(0.6),
        );
        let rows: Vec<AnyElement> = rows
            .into_iter()
            .enumerate()
            .map(|(index, (profile, name, engine))| {
                h_flex()
                    .id(("sandbox-row", index))
                    .h(px(30.))
                    .pl_2()
                    .pr_2()
                    .gap_2()
                    .rounded_md()
                    .cursor_pointer()
                    .text_sm()
                    .text_color(foreground.opacity(0.85))
                    .hover(move |style| style.bg(hover))
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.edit_sandbox(profile, window, cx)
                    }))
                    .child(Icon::new(IconName::Shield).small().text_color(muted))
                    .child(div().flex_1().min_w_0().truncate().child(name))
                    .child(div().flex_none().text_xs().text_color(muted).child(engine))
                    .into_any_element()
            })
            .collect();
        v_flex()
            .gap_0p5()
            .child(header)
            .children(rows)
            .into_any_element()
    }
}

impl Render for PresetsPanel {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        v_flex()
            .gap_4()
            .child(self.render_ssh_section(cx))
            .child(self.render_sandboxes_section(cx))
    }
}

/// A muted row with a plus, for adding the first item of a list.
fn add_row(id: &'static str, label: &'static str, cx: &App) -> gpui::Stateful<gpui::Div> {
    let theme = cx.theme();
    let (muted, hover) = (theme.muted_foreground, theme.sidebar_accent.opacity(0.6));
    h_flex()
        .id(id)
        .h(px(30.))
        .px_2()
        .gap_2()
        .rounded_md()
        .cursor_pointer()
        .text_sm()
        .text_color(muted)
        .hover(move |style| style.bg(hover))
        .child(Icon::new(IconName::Plus).small())
        .child(label)
}

/// A forward's name, or what it does when it has none.
pub(crate) fn forward_name(forward: &Forward) -> String {
    if forward.name.trim().is_empty() {
        forward.summary()
    } else {
        forward.name.clone()
    }
}

fn engine_label(engine: &SandboxEngine) -> &'static str {
    match engine {
        SandboxEngine::Seatbelt { .. } => "macOS",
        SandboxEngine::Docker { .. } => "Docker",
    }
}
