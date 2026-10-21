//! SSH sessions through the system OpenSSH client, so `~/.ssh/config`, `known_hosts` and agents
//! all keep working. Saved passwords come from the Keychain through this same binary acting as
//! `SSH_ASKPASS` (see [`askpass`]).

pub mod askpass;
pub mod forward;
pub mod forward_dialog;
pub mod guard;
pub mod host_dialog;
pub mod log_view;

use std::path::PathBuf;

use crate::{
    profiles::{Forward, SshAuth, SshHost},
    workspace::expand_home,
};

/// Environment variable naming the host whose saved password askpass should answer with.
pub const ASKPASS_HOST: &str = "GPU_TERMINAL_ASKPASS";

/// Where ssh finds a Vaultwarden key: the app's agent, and the key's public half to pick it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VaultIdentity {
    pub socket: PathBuf,
    pub public_key: PathBuf,
}

/// A ready-to-run `ssh` invocation.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SshCommand {
    pub program: String,
    pub args: Vec<String>,
    pub env: Vec<(String, String)>,
}

/// An interactive session to `host`. `saved_password` says whether the Keychain holds one;
/// `vault` is where its Vaultwarden key is, while the vault is unlocked.
pub fn interactive(
    host: &SshHost,
    saved_password: bool,
    vault: Option<&VaultIdentity>,
) -> SshCommand {
    let mut command = base(host, saved_password, vault);
    command.args.push(host.destination());
    command
}

/// A connection that only carries `forward` (`-N`), logging verbosely so its state can be read
/// from stderr. With no terminal to answer prompts, unknown host keys are accepted the first time
/// (a changed key is still refused) and, without a saved password, nothing may prompt.
pub fn forwarding(
    host: &SshHost,
    forward: &Forward,
    saved_password: bool,
    vault: Option<&VaultIdentity>,
) -> SshCommand {
    let mut command = base(host, saved_password, vault);
    let password = saved_password && host.auth == SshAuth::Password;
    for option in [
        "ExitOnForwardFailure=yes",
        "StrictHostKeyChecking=accept-new",
        "ConnectTimeout=15",
        if password {
            "BatchMode=no"
        } else {
            "BatchMode=yes"
        },
    ] {
        command.args.extend(["-o".to_owned(), option.to_owned()]);
    }
    command
        .args
        .extend(["-N".to_owned(), "-T".to_owned(), "-v".to_owned()]);
    command.args.extend(forward.ssh_flag());
    command.args.push(host.destination());
    command
}

/// Options shared by every connection to `host`: port, keep-alives and how it signs in.
fn base(host: &SshHost, saved_password: bool, vault: Option<&VaultIdentity>) -> SshCommand {
    let mut args = Vec::new();
    let mut env = Vec::new();
    let option = |args: &mut Vec<String>, value: String| {
        args.push("-o".to_owned());
        args.push(value);
    };
    if host.port != 22 {
        args.push("-p".to_owned());
        args.push(host.port.to_string());
    }
    if host.keepalive_secs > 0 {
        option(
            &mut args,
            format!("ServerAliveInterval={}", host.keepalive_secs),
        );
        option(&mut args, "ServerAliveCountMax=3".to_owned());
    }
    match &host.auth {
        SshAuth::Agent => {}
        SshAuth::Key { path } => {
            args.push("-i".to_owned());
            args.push(expand_home(path).to_string_lossy().into_owned());
            option(&mut args, "IdentitiesOnly=yes".to_owned());
        }
        // Only the vault key is offered, from the app's agent (none while locked).
        SshAuth::Vault { .. } => {
            if let Some(vault) = vault {
                option(
                    &mut args,
                    format!("IdentityAgent={}", vault.socket.display()),
                );
                args.push("-i".to_owned());
                args.push(vault.public_key.to_string_lossy().into_owned());
                option(&mut args, "IdentitiesOnly=yes".to_owned());
            }
        }
        SshAuth::Password => {
            option(
                &mut args,
                "PreferredAuthentications=keyboard-interactive,password".to_owned(),
            );
            if saved_password {
                // One try: a wrong saved password must not be repeated until the server locks us out.
                option(&mut args, "NumberOfPasswordPrompts=1".to_owned());
                if let Ok(exe) = std::env::current_exe() {
                    env.push(("SSH_ASKPASS".to_owned(), exe.to_string_lossy().into_owned()));
                    env.push(("SSH_ASKPASS_REQUIRE".to_owned(), "force".to_owned()));
                    env.push((ASKPASS_HOST.to_owned(), host.id.to_string()));
                }
            }
        }
    }
    SshCommand {
        program: "ssh".to_owned(),
        args,
        env,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn host(auth: SshAuth) -> SshHost {
        SshHost {
            id: 4,
            name: "box".into(),
            host: "example.com".into(),
            user: "me".into(),
            auth,
            ..SshHost::default()
        }
    }

    #[test]
    fn agent_hosts_use_plain_ssh_with_keepalives() {
        let command = interactive(&host(SshAuth::Agent), false, None);
        assert_eq!(command.program, "ssh");
        assert_eq!(
            command.args,
            [
                "-o",
                "ServerAliveInterval=30",
                "-o",
                "ServerAliveCountMax=3",
                "me@example.com"
            ]
        );
        assert!(command.env.is_empty());
    }

    #[test]
    fn key_hosts_pin_their_key_and_ports_are_passed() {
        let mut key = host(SshAuth::Key {
            path: "/keys/id".into(),
        });
        key.port = 2222;
        key.keepalive_secs = 0;
        let command = interactive(&key, false, None);
        assert_eq!(
            command.args,
            [
                "-p",
                "2222",
                "-i",
                "/keys/id",
                "-o",
                "IdentitiesOnly=yes",
                "me@example.com"
            ]
        );
    }

    #[test]
    fn forwards_run_without_a_terminal() {
        let forward = Forward {
            bind: "8080".into(),
            target: "db:5432".into(),
            ..Forward::default()
        };
        let command = forwarding(&host(SshAuth::Agent), &forward, false, None);
        let args = command.args.join(" ");
        assert!(args.contains("-o ExitOnForwardFailure=yes"));
        assert!(args.contains("-o BatchMode=yes"));
        assert!(
            args.ends_with("-N -T -v -L 8080:db:5432 me@example.com"),
            "{args}"
        );
        // A saved password is typed by askpass, which batch mode would forbid.
        let command = forwarding(&host(SshAuth::Password), &forward, true, None);
        assert!(command.args.join(" ").contains("-o BatchMode=no"));
    }

    #[test]
    fn vault_keys_come_from_the_app_agent_only() {
        let vault = VaultIdentity {
            socket: "/tmp/agent.sock".into(),
            public_key: "/tmp/key.pub".into(),
        };
        let auth = SshAuth::Vault {
            item: "id".into(),
            name: "deploy".into(),
        };
        let args = interactive(&host(auth.clone()), false, Some(&vault))
            .args
            .join(" ");
        assert!(
            args.contains("-o IdentityAgent=/tmp/agent.sock -i /tmp/key.pub -o IdentitiesOnly=yes"),
            "{args}"
        );
        // Locked: no agent to point at.
        assert!(
            !interactive(&host(auth), false, None)
                .args
                .join(" ")
                .contains("IdentityAgent")
        );
    }

    #[test]
    fn saved_passwords_go_through_askpass() {
        let saved = interactive(&host(SshAuth::Password), true, None);
        assert!(saved.args.contains(&"NumberOfPasswordPrompts=1".to_owned()));
        assert!(
            saved
                .env
                .iter()
                .any(|(key, value)| key == ASKPASS_HOST && value == "4")
        );
        assert!(
            saved
                .env
                .iter()
                .any(|(key, value)| key == "SSH_ASKPASS_REQUIRE" && value == "force")
        );
        // Without a saved password, ssh asks in the terminal as usual.
        let typed = interactive(&host(SshAuth::Password), false, None);
        assert!(typed.env.is_empty());
    }
}
