//! Register or edit an SSH host: name, address, user, how it authenticates, keep-alives and what
//! to do when the connection drops. A typed password goes to the Keychain, never to disk.

use std::rc::Rc;

use gpui::{
    App, AppContext as _, Context, Entity, InteractiveElement as _, IntoElement,
    ParentElement as _, PathPromptOptions, Render, SharedString, StatefulInteractiveElement as _,
    Styled as _, Subscription, Window, div, prelude::FluentBuilder as _, px,
};
use gpui_component::{
    ActiveTheme as _, Icon, Selectable as _, Sizable as _, WindowExt as _,
    button::{Button, ButtonGroup, ButtonVariants as _},
    dialog::DialogEntrance,
    h_flex,
    input::{Input, InputState},
    v_flex,
};

use crate::{
    icons::IconName,
    profiles::{OnDisconnect, Profiles, SshAuth, SshHost, keychain},
    project_dialog::field,
    vault::{self, Vault},
    workspace::{Id, expand_home, tilde},
};

/// Which way of signing in the form shows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum AuthChoice {
    Agent,
    Key,
    Password,
    Vault,
}

const AUTH_CHOICES: [(AuthChoice, &str); 4] = [
    (AuthChoice::Agent, "Agent / config"),
    (AuthChoice::Key, "Key file"),
    (AuthChoice::Password, "Password"),
    (AuthChoice::Vault, "Vaultwarden"),
];

type OnSave = Rc<dyn Fn(Id, &mut Window, &mut App)>;

/// Open the dialog for `host` (`id` 0: a new host). Saving stores it in the profiles (and a typed
/// password in the Keychain), then `on_save` gets its id once the dialog has closed.
pub fn open(
    host: SshHost,
    window: &mut Window,
    cx: &mut App,
    on_save: impl Fn(Id, &mut Window, &mut App) + 'static,
) {
    let title = if host.id == 0 {
        "New SSH host"
    } else {
        "Edit SSH host"
    };
    let editor = cx.new(|cx| HostEditor::new(host, window, cx));
    let on_save: OnSave = Rc::new(on_save);
    let name = editor.read(cx).name.clone();
    window.open_dialog(cx, move |dialog, _, _| {
        let (on_enter, on_click) = (
            (editor.clone(), on_save.clone()),
            (editor.clone(), on_save.clone()),
        );
        dialog
            .title(title)
            .w(px(460.))
            .entrance(DialogEntrance::FadeSlide)
            .on_ok(move |_, window, cx| submit(&on_enter.0, &on_enter.1, window, cx))
            .child(editor.clone())
            .footer(
                h_flex()
                    .w_full()
                    .justify_end()
                    .gap_2()
                    .child(
                        Button::new("host-cancel")
                            .label("Cancel")
                            .on_click(|_, window, cx| window.close_dialog(cx)),
                    )
                    .child(Button::new("host-save").primary().label("Save").on_click(
                        move |_, window, cx| {
                            if submit(&on_click.0, &on_click.1, window, cx) {
                                window.close_dialog(cx);
                            }
                        },
                    )),
            )
    });
    window.defer(cx, move |window, cx| {
        name.update(cx, |input, cx| input.focus(window, cx))
    });
}

fn submit(
    editor: &Entity<HostEditor>,
    on_save: &OnSave,
    window: &mut Window,
    cx: &mut App,
) -> bool {
    let result = editor.read(cx).host(cx);
    let (host, password) = match result {
        Ok(result) => result,
        Err(error) => {
            editor.update(cx, |editor, cx| {
                editor.error = Some(error);
                cx.notify();
            });
            return false;
        }
    };
    let auth = host.auth.clone();
    let id = Profiles::update(cx, |profiles| profiles.upsert_host(host));
    // Keep the Keychain in step with how the host signs in.
    match (auth, password) {
        (SshAuth::Password, Some(password)) => {
            if let Err(err) = keychain::set_password(id, &password) {
                eprintln!("failed to save the password in the Keychain: {err}");
            }
        }
        (SshAuth::Password, None) => {}
        _ => keychain::delete_password(id),
    }
    let on_save = on_save.clone();
    window.defer(cx, move |window, cx| on_save(id, window, cx));
    true
}

struct HostEditor {
    id: Id,
    name: Entity<InputState>,
    address: Entity<InputState>,
    port: Entity<InputState>,
    user: Entity<InputState>,
    key: Entity<InputState>,
    password: Entity<InputState>,
    keepalive: Entity<InputState>,
    auth: AuthChoice,
    /// The chosen vault key: item id and name.
    vault_key: Option<(String, String)>,
    on_disconnect: OnDisconnect,
    /// Whether the Keychain already holds a password for this host.
    has_password: bool,
    error: Option<String>,
    _vault: Subscription,
}

impl HostEditor {
    fn new(host: SshHost, window: &mut Window, cx: &mut Context<Self>) -> Self {
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
        let (auth, key, vault_key) = match &host.auth {
            SshAuth::Agent => (AuthChoice::Agent, String::new(), None),
            SshAuth::Key { path } => (AuthChoice::Key, path.clone(), None),
            SshAuth::Password => (AuthChoice::Password, String::new(), None),
            SshAuth::Vault { item, name } => (
                AuthChoice::Vault,
                String::new(),
                Some((item.clone(), name.clone())),
            ),
        };
        let has_password = host.id != 0 && keychain::has_password(host.id);
        Self {
            id: host.id,
            name: input(host.name, "Production server", window, cx),
            address: input(host.host, "example.com or 10.0.0.5", window, cx),
            port: input(host.port.to_string(), "22", window, cx),
            user: input(host.user, "From ~/.ssh/config", window, cx),
            key: input(key, "~/.ssh/id_ed25519", window, cx),
            password: cx.new(|cx| {
                InputState::new(window, cx)
                    .masked(true)
                    .placeholder(if has_password {
                        "Saved in Keychain — type to replace"
                    } else {
                        "Asked when connecting if empty"
                    })
            }),
            keepalive: input(host.keepalive_secs.to_string(), "30", window, cx),
            auth,
            vault_key,
            on_disconnect: host.on_disconnect,
            has_password,
            error: None,
            // The key list appears once the vault is unlocked from here.
            _vault: cx.observe_global::<Vault>(|_, cx| cx.notify()),
        }
    }

    /// The host as entered, with a newly typed password; or what is wrong with it.
    fn host(&self, cx: &App) -> Result<(SshHost, Option<String>), String> {
        let text = |input: &Entity<InputState>| input.read(cx).value().trim().to_owned();
        let address = text(&self.address);
        if address.is_empty() {
            return Err("Enter the host to connect to.".into());
        }
        let port = match text(&self.port) {
            port if port.is_empty() => 22,
            port => port
                .parse::<u16>()
                .map_err(|_| "The port must be a number from 1 to 65535.")?,
        };
        let keepalive_secs = match text(&self.keepalive) {
            secs if secs.is_empty() => 0,
            secs => secs
                .parse::<u32>()
                .map_err(|_| "Keep-alive must be a whole number of seconds.")?,
        };
        let auth = match self.auth {
            AuthChoice::Agent => SshAuth::Agent,
            AuthChoice::Key => {
                let path = text(&self.key);
                if !expand_home(&path).is_file() {
                    return Err("Choose a key file that exists.".into());
                }
                SshAuth::Key {
                    path: tilde(&expand_home(&path).to_string_lossy()),
                }
            }
            AuthChoice::Password => SshAuth::Password,
            AuthChoice::Vault => {
                let (item, name) = self
                    .vault_key
                    .clone()
                    .ok_or("Choose a key from your vault.")?;
                SshAuth::Vault { item, name }
            }
        };
        let name = match text(&self.name) {
            name if name.is_empty() => address.clone(),
            name => name,
        };
        let password = Some(self.password.read(cx).value().to_string())
            .filter(|password| !password.is_empty());
        Ok((
            SshHost {
                id: self.id,
                name,
                host: address,
                port,
                user: text(&self.user),
                auth,
                keepalive_secs,
                on_disconnect: self.on_disconnect,
                forwards: Vec::new(),
            },
            password,
        ))
    }

    fn browse_key(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let paths = cx.prompt_for_paths(PathPromptOptions {
            files: true,
            directories: false,
            multiple: false,
            prompt: Some("Use key".into()),
        });
        cx.spawn_in(window, async move |this, cx| {
            if let Ok(Ok(Some(paths))) = paths.await
                && let Some(path) = paths.into_iter().next()
            {
                let _ = this.update_in(cx, |this, window, cx| {
                    let text = SharedString::from(tilde(&path.to_string_lossy()));
                    this.key
                        .update(cx, |input, cx| input.set_value(text, window, cx));
                    cx.notify();
                });
            }
        })
        .detach();
    }
}

impl HostEditor {
    /// The vault's SSH keys to pick from, or a way to unlock it.
    fn render_vault_keys(&self, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let theme = cx.theme();
        let (muted, accent, border) = (theme.muted_foreground, theme.accent, theme.border);
        if !Vault::is_unlocked(cx) {
            let chosen = self
                .vault_key
                .as_ref()
                .map(|(_, name)| format!("Uses “{name}”. "));
            return v_flex()
                .gap_2()
                .child(div().text_xs().text_color(muted).child(format!(
                    "{}Unlock Vaultwarden to choose a key; it is served from memory, never saved to disk.",
                    chosen.unwrap_or_default()
                )))
                .child(
                    Button::new("host-unlock-vault")
                        .small()
                        .icon(IconName::Lock)
                        .label("Unlock Vaultwarden")
                        .on_click(|_, window, cx| vault::unlock_dialog::open(window, cx, |_, _| {})),
                )
                .into_any_element();
        }
        let keys = Vault::keys(cx);
        if keys.is_empty() {
            return div()
                .text_xs()
                .text_color(muted)
                .child("Your vault has no SSH keys.")
                .into_any_element();
        }
        let chosen = self.vault_key.as_ref().map(|(id, _)| id.clone());
        v_flex()
            .id("host-vault-keys")
            .max_h(px(160.))
            .overflow_y_scroll()
            .rounded_md()
            .border_1()
            .border_color(border)
            .p_1()
            .children(keys.into_iter().enumerate().map(|(index, key)| {
                let selected = chosen.as_deref() == Some(key.id.as_str());
                let pick = (key.id.clone(), key.name.clone());
                h_flex()
                    .id(("vault-key", index))
                    .h(px(28.))
                    .px_2()
                    .gap_2()
                    .rounded_sm()
                    .cursor_pointer()
                    .text_sm()
                    .when(selected, |row| row.bg(accent))
                    .hover(move |style| style.bg(accent))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.vault_key = Some(pick.clone());
                        cx.notify();
                    }))
                    .child(
                        Icon::new(if selected {
                            IconName::CircleCheck
                        } else {
                            IconName::KeyRound
                        })
                        .small()
                        .text_color(muted),
                    )
                    .child(key.name)
            }))
            .into_any_element()
    }
}

/// A row of mutually exclusive choices.
fn segmented<T: Copy + PartialEq + 'static>(
    id: &'static str,
    choices: &[(T, &'static str)],
    selected: T,
    cx: &mut Context<HostEditor>,
    set: fn(&mut HostEditor, T),
) -> ButtonGroup {
    let values: Vec<T> = choices.iter().map(|(value, _)| *value).collect();
    ButtonGroup::new(id)
        .outline()
        .small()
        .children(choices.iter().enumerate().map(|(index, (value, label))| {
            Button::new((id, index))
                .label(*label)
                .selected(*value == selected)
        }))
        .on_click(cx.listener(move |this, clicked: &Vec<usize>, _, cx| {
            if let Some(value) = clicked.first().and_then(|index| values.get(*index)) {
                set(this, *value);
                cx.notify();
            }
        }))
}

impl Render for HostEditor {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.theme();
        let (muted, danger) = (theme.muted_foreground, theme.danger);
        let auth_detail = match self.auth {
            AuthChoice::Agent => div()
                .text_xs()
                .text_color(muted)
                .child("Uses your ssh-agent, ~/.ssh/config and default keys, like plain ssh.")
                .into_any_element(),
            AuthChoice::Key => h_flex()
                .gap_2()
                .child(div().flex_1().child(Input::new(&self.key)))
                .child(
                    Button::new("host-browse-key")
                        .label("Browse")
                        .on_click(cx.listener(|this, _, window, cx| this.browse_key(window, cx))),
                )
                .into_any_element(),
            AuthChoice::Vault => self.render_vault_keys(cx).into_any_element(),
            AuthChoice::Password => v_flex()
                .gap_1p5()
                .child(Input::new(&self.password).mask_toggle())
                .child(
                    div()
                        .text_xs()
                        .text_color(muted)
                        .child(if self.has_password {
                            "A password is saved in your Keychain."
                        } else {
                            "Saved in your macOS Keychain, never in the app's files."
                        }),
                )
                .into_any_element(),
        };

        v_flex()
            .gap_4()
            .child(field("Name", Input::new(&self.name)))
            .child(
                h_flex()
                    .gap_3()
                    .child(
                        div()
                            .flex_1()
                            .child(field("Host", Input::new(&self.address))),
                    )
                    .child(
                        div()
                            .w(px(84.))
                            .child(field("Port", Input::new(&self.port))),
                    ),
            )
            .child(field("User", Input::new(&self.user)))
            .child(field(
                "Sign in with",
                v_flex()
                    .gap_2()
                    .child(segmented(
                        "host-auth",
                        &AUTH_CHOICES,
                        self.auth,
                        cx,
                        |this, value| this.auth = value,
                    ))
                    .child(auth_detail),
            ))
            .child(
                h_flex()
                    .gap_3()
                    .items_start()
                    .child(
                        div()
                            .w(px(120.))
                            .child(field("Keep-alive (s)", Input::new(&self.keepalive))),
                    )
                    .child(div().flex_1().child(field(
                        "When the connection drops",
                        segmented(
                            "host-drop",
                            &OnDisconnect::ALL,
                            self.on_disconnect,
                            cx,
                            |this, value| this.on_disconnect = value,
                        ),
                    ))),
            )
            .when_some(self.error.clone(), |form, error| {
                form.child(div().text_sm().text_color(danger).child(error))
            })
    }
}
