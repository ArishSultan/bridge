//! Link and unlock Vaultwarden: server, email and master password (plus a two-step code when the
//! account asks for one). Unlocking runs off the main thread; the dialog closes once the vault's
//! keys are loaded into the app's agent.

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
    notification::Notification,
    v_flex,
};
use zeroize::Zeroizing;

use super::{
    Vault, VaultAccount,
    client::{self, AUTHENTICATOR, EMAIL, LoginError},
};
use crate::{profiles::Profiles, project_dialog::field};

type OnUnlocked = Rc<dyn Fn(&mut Window, &mut App)>;

/// Open the dialog; `on_unlocked` runs once the vault is unlocked and the dialog has closed.
pub fn open(
    window: &mut Window,
    cx: &mut App,
    on_unlocked: impl Fn(&mut Window, &mut App) + 'static,
) {
    let account = Profiles::get(cx).vault.clone().unwrap_or_default();
    let linked = !account.email.is_empty();
    let editor = cx.new(|cx| UnlockEditor::new(account, Rc::new(on_unlocked), window, cx));
    let focus = if linked {
        editor.read(cx).password.clone()
    } else {
        editor.read(cx).server.clone()
    };
    window.open_dialog(cx, move |dialog, _, _| {
        let (on_enter, on_click) = (editor.clone(), editor.clone());
        dialog
            .title(if linked {
                "Unlock Vaultwarden"
            } else {
                "Link Vaultwarden"
            })
            .w(px(440.))
            .entrance(DialogEntrance::FadeSlide)
            .on_ok(move |_, window, cx| {
                on_enter.update(cx, |editor, cx| editor.submit(window, cx));
                false
            })
            .child(editor.clone())
            .footer(
                h_flex()
                    .w_full()
                    .justify_end()
                    .gap_2()
                    .child(
                        Button::new("vault-cancel")
                            .label("Cancel")
                            .on_click(|_, window, cx| window.close_dialog(cx)),
                    )
                    .child(
                        Button::new("vault-unlock")
                            .primary()
                            .label("Unlock")
                            .on_click(move |_, window, cx| {
                                on_click.update(cx, |editor, cx| editor.submit(window, cx));
                            }),
                    ),
            )
    });
    window.defer(cx, move |window, cx| {
        focus.update(cx, |input, cx| input.focus(window, cx))
    });
}

struct UnlockEditor {
    server: Entity<InputState>,
    email: Entity<InputState>,
    password: Entity<InputState>,
    code: Entity<InputState>,
    device_id: String,
    lock_minutes: u32,
    /// The two-step method a code is being asked for.
    code_for: Option<u32>,
    busy: bool,
    /// A note or an error (`true`) to show.
    message: Option<(bool, String)>,
    on_unlocked: OnUnlocked,
}

impl UnlockEditor {
    fn new(
        account: VaultAccount,
        on_unlocked: OnUnlocked,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let device_id = if account.device_id.is_empty() {
            uuid::Uuid::new_v4().to_string()
        } else {
            account.device_id
        };
        let lock_minutes = if account.server.is_empty() {
            60
        } else {
            account.lock_minutes
        };
        Self {
            server: cx.new(|cx| {
                InputState::new(window, cx)
                    .placeholder("https://vault.example.com")
                    .default_value(account.server)
            }),
            email: cx.new(|cx| {
                InputState::new(window, cx)
                    .placeholder("you@example.com")
                    .default_value(account.email)
            }),
            password: cx.new(|cx| {
                InputState::new(window, cx)
                    .masked(true)
                    .placeholder("Master password")
            }),
            code: cx.new(|cx| InputState::new(window, cx).placeholder("123456")),
            device_id,
            lock_minutes,
            code_for: None,
            busy: false,
            message: None,
            on_unlocked,
        }
    }

    fn login(&self, cx: &App) -> Result<client::Login, String> {
        let text = |input: &Entity<InputState>| input.read(cx).value().trim().to_owned();
        let server = client::server_url(&text(&self.server))?;
        let email = text(&self.email);
        if !email.contains('@') {
            return Err("Enter the email of your Vaultwarden account.".into());
        }
        let password = Zeroizing::new(self.password.read(cx).value().to_string());
        if password.is_empty() {
            return Err("Enter your master password.".into());
        }
        let two_factor = match self.code_for {
            Some(provider) => {
                let code = text(&self.code);
                if code.is_empty() {
                    return Err("Enter the two-step login code.".into());
                }
                Some((provider, code))
            }
            None => None,
        };
        Ok(client::Login {
            server,
            email,
            password,
            device_id: self.device_id.clone(),
            two_factor,
        })
    }

    fn submit(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        let login = match self.login(cx) {
            Ok(login) => login,
            Err(error) => {
                self.message = Some((true, error));
                cx.notify();
                return;
            }
        };
        self.busy = true;
        self.message = Some((false, "Unlocking…".into()));
        cx.notify();
        let account = VaultAccount {
            server: login.server.clone(),
            email: login.email.clone(),
            device_id: login.device_id.clone(),
            lock_minutes: self.lock_minutes,
        };
        let task = cx.background_spawn(async move {
            let result = super::unlock(&login);
            // An email code is sent once the server has said it wants one.
            if let Err(LoginError::TwoFactor(providers)) = &result
                && login.two_factor.is_none()
                && !providers.contains(&AUTHENTICATOR)
                && providers.contains(&EMAIL)
            {
                let _ = client::send_email_code(&login);
            }
            result
        });
        cx.spawn_in(window, async move |this, cx| {
            let result = task.await;
            let _ = this.update_in(cx, |this, window, cx| {
                this.finish(result, account, window, cx)
            });
        })
        .detach();
    }

    fn finish(
        &mut self,
        result: Result<super::Unlocked, LoginError>,
        account: VaultAccount,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.busy = false;
        match result {
            Ok(unlocked) => {
                let summary = summary(unlocked.keys.len(), unlocked.skipped, &unlocked.failures);
                Profiles::update(cx, |profiles| profiles.vault = Some(account));
                Vault::install(unlocked, cx);
                window.close_dialog(cx);
                window.push_notification(
                    Notification::success(summary).title("Vaultwarden unlocked"),
                    cx,
                );
                let on_unlocked = self.on_unlocked.clone();
                window.defer(cx, move |window, cx| on_unlocked(window, cx));
            }
            Err(LoginError::TwoFactor(providers)) => {
                let provider = if providers.contains(&AUTHENTICATOR) {
                    AUTHENTICATOR
                } else {
                    EMAIL
                };
                self.code_for = Some(provider);
                let note = if provider == AUTHENTICATOR {
                    "Enter the code from your authenticator app."
                } else {
                    "The server is emailing you a code; enter it here."
                };
                self.message = Some((false, note.into()));
                self.code.update(cx, |input, cx| input.focus(window, cx));
            }
            Err(error) => self.message = Some((true, error.to_string())),
        }
        cx.notify();
    }
}

/// What an unlock loaded, for the toast.
fn summary(keys: usize, skipped: usize, failures: &[String]) -> String {
    let mut summary = match keys {
        0 => "No SSH keys found in your vault.".to_owned(),
        1 => "1 SSH key is ready.".to_owned(),
        keys => format!("{keys} SSH keys are ready."),
    };
    if skipped > 0 {
        summary.push_str(&format!(
            " {skipped} organization item(s) can't be read yet."
        ));
    }
    for failure in failures {
        summary.push_str(&format!(" Not loaded: {failure}."));
    }
    summary
}

impl Render for UnlockEditor {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.theme();
        let (muted, danger) = (theme.muted_foreground, theme.danger);
        let choices: Vec<u32> = VaultAccount::LOCK_CHOICES
            .iter()
            .map(|(minutes, _)| *minutes)
            .collect();
        v_flex()
            .gap_4()
            .child(field(
                "Server",
                v_flex().gap_1p5().child(Input::new(&self.server)).child(
                    div().text_xs().text_color(muted).child(
                        "Your self-hosted Vaultwarden address. A path such as \
                         https://example.com/vault works too.",
                    ),
                ),
            ))
            .child(field("Email", Input::new(&self.email)))
            .child(field("Master password", Input::new(&self.password).mask_toggle()))
            .when(self.code_for.is_some(), |form| form.child(field("Two-step login code", Input::new(&self.code))))
            .child(field(
                "Lock after",
                ButtonGroup::new("vault-lock")
                    .outline()
                    .small()
                    .children(VaultAccount::LOCK_CHOICES.iter().enumerate().map(|(index, (minutes, label))| {
                        Button::new(("vault-lock", index)).label(*label).selected(*minutes == self.lock_minutes)
                    }))
                    .on_click(cx.listener(move |this, clicked: &Vec<usize>, _, cx| {
                        if let Some(minutes) = clicked.first().and_then(|index| choices.get(*index)) {
                            this.lock_minutes = *minutes;
                            cx.notify();
                        }
                    })),
            ))
            .child(div().text_xs().text_color(muted).child(
                "Keys are decrypted in memory and loaded into a private ssh-agent; nothing is written to disk. \
                 Only the server and email are remembered.",
            ))
            .when_some(self.message.clone(), |form, (error, message)| {
                form.child(div().text_sm().text_color(if error { danger } else { muted }).child(message))
            })
    }
}
