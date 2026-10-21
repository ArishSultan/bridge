//! Saved profiles: SSH hosts with their port forwards, and sandbox profiles. Persisted to
//! `~/.config/bridge/profiles.json`. Secrets never go in this file: saved SSH passwords live
//! in the macOS Keychain (see [`keychain`]).

use std::{fs, io, path::PathBuf};

use gpui::{App, Global};
use serde::{Deserialize, Serialize};

use crate::{settings::TerminalSettings, workspace::Id};

/// How an SSH host authenticates.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum SshAuth {
    /// Whatever `ssh` would use: the agent, `~/.ssh/config` and default keys.
    #[default]
    Agent,
    /// A private key file.
    Key { path: String },
    /// A password, kept in the Keychain when saved (otherwise ssh asks for it).
    Password,
    /// An SSH key from Vaultwarden, served by the app's agent while the vault is unlocked.
    Vault { item: String, name: String },
}

/// What to do when a connection drops.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OnDisconnect {
    /// Show it in the terminal; Enter reconnects.
    #[default]
    Nothing,
    /// Also post a system notification.
    Notify,
    /// Reconnect by itself.
    Reconnect,
}

impl OnDisconnect {
    pub const ALL: [(Self, &'static str); 3] = [
        (Self::Nothing, "Do nothing"),
        (Self::Notify, "Notify"),
        (Self::Reconnect, "Reconnect"),
    ];
}

/// Which way a port forward goes.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ForwardKind {
    /// A local port reaches a target through the server (`ssh -L`).
    #[default]
    Local,
    /// A port on the server reaches a target on this machine (`ssh -R`).
    Remote,
    /// A local SOCKS proxy through the server (`ssh -D`).
    Dynamic,
}

impl ForwardKind {
    pub const ALL: [(Self, &'static str); 3] = [
        (Self::Local, "Local"),
        (Self::Remote, "Remote"),
        (Self::Dynamic, "SOCKS"),
    ];
}

/// A port forward over an SSH host, run as its own connection so each can be switched on and off.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Forward {
    pub id: Id,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub kind: ForwardKind,
    /// Where it listens: `8080` or `127.0.0.1:8080` (on the server for remote forwards).
    pub bind: String,
    /// Where connections go: `localhost:5432`; unused for SOCKS.
    #[serde(default)]
    pub target: String,
    /// Keep its connection log to show.
    #[serde(default)]
    pub show_logs: bool,
    /// Switched on; it reconnects at launch.
    #[serde(default)]
    pub enabled: bool,
}

impl Forward {
    /// The `-L` / `-R` / `-D` arguments.
    pub fn ssh_flag(&self) -> [String; 2] {
        let bind = self.bind.trim();
        match self.kind {
            ForwardKind::Local => ["-L".into(), format!("{bind}:{}", self.target.trim())],
            ForwardKind::Remote => ["-R".into(), format!("{bind}:{}", self.target.trim())],
            ForwardKind::Dynamic => ["-D".into(), bind.to_owned()],
        }
    }

    /// `localhost:8080 → db:5432`, for display.
    pub fn summary(&self) -> String {
        let bind = if self.bind.contains(':') {
            self.bind.trim().to_owned()
        } else {
            format!("localhost:{}", self.bind.trim())
        };
        match self.kind {
            ForwardKind::Local => format!("{bind} → {}", self.target.trim()),
            ForwardKind::Remote => format!("server {bind} → {}", self.target.trim()),
            ForwardKind::Dynamic => format!("SOCKS on {bind}"),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SshHost {
    pub id: Id,
    pub name: String,
    pub host: String,
    #[serde(default = "default_port")]
    pub port: u16,
    /// Empty: ssh's default (from `~/.ssh/config` or the local user name).
    #[serde(default)]
    pub user: String,
    #[serde(default)]
    pub auth: SshAuth,
    /// Seconds between keep-alive messages; 0 turns them off.
    #[serde(default = "default_keepalive")]
    pub keepalive_secs: u32,
    #[serde(default)]
    pub on_disconnect: OnDisconnect,
    #[serde(default)]
    pub forwards: Vec<Forward>,
}

impl Default for SshHost {
    fn default() -> Self {
        Self {
            id: 0,
            name: String::new(),
            host: String::new(),
            port: default_port(),
            user: String::new(),
            auth: SshAuth::Agent,
            keepalive_secs: default_keepalive(),
            on_disconnect: OnDisconnect::Nothing,
            forwards: Vec::new(),
        }
    }
}

fn default_port() -> u16 {
    22
}

fn default_keepalive() -> u32 {
    30
}

impl SshHost {
    /// `user@host`, or just `host` without a user.
    pub fn destination(&self) -> String {
        if self.user.trim().is_empty() {
            self.host.trim().to_owned()
        } else {
            format!("{}@{}", self.user.trim(), self.host.trim())
        }
    }

    /// `user@host:port` for display, leaving out the default port.
    pub fn address(&self) -> String {
        if self.port == default_port() {
            self.destination()
        } else {
            format!("{}:{}", self.destination(), self.port)
        }
    }
}

/// What a Seatbelt sandbox lets its programs reach on the network.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Network {
    #[default]
    All,
    Localhost,
    None,
}

impl Network {
    pub const ALL: [(Self, &'static str); 3] = [
        (Self::All, "Allowed"),
        (Self::Localhost, "Localhost only"),
        (Self::None, "Blocked"),
    ];
}

/// How a sandbox isolates what runs in it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum SandboxEngine {
    /// macOS's own sandbox (`sandbox-exec`), around the user's shell and tools.
    Seatbelt {
        /// Writable besides the terminal's folder and temporary folders (`~` allowed).
        writable: Vec<String>,
        /// Neither readable nor writable.
        hidden: Vec<String>,
        network: Network,
        /// Programs that may not be run (names looked up on PATH, or paths).
        blocked: Vec<String>,
        /// Refuse access to the Keychain (passwords, tokens) through the system service.
        block_keychain: bool,
        /// Only let programs read the project, system folders, what is writable and `readable`;
        /// everything else (other projects, the rest of the home folder) is off limits.
        #[serde(default = "yes")]
        confine_reads: bool,
        /// Readable (not writable) while reads are confined: shell and toolchain setup.
        #[serde(default = "default_readable")]
        readable: Vec<String>,
        /// Let programs read and set the clipboard (pasting with ⌘V works either way).
        #[serde(default)]
        allow_clipboard: bool,
        /// Let programs open apps, files and links in other apps (`open`, a browser for a login).
        #[serde(default)]
        allow_open: bool,
    },
    /// A Linux container that sees only the terminal's folder (and any extra mounts).
    Docker {
        image: String,
        network: bool,
        /// Extra `host:container[:ro]` mounts.
        mounts: Vec<String>,
        /// Environment variables passed in by name.
        env: Vec<String>,
    },
}

fn yes() -> bool {
    true
}

fn list(items: &[&str]) -> Vec<String> {
    items.iter().map(|item| (*item).to_owned()).collect()
}

/// What a shell and common toolchains read from the home folder at startup and while working.
fn default_readable() -> Vec<String> {
    list(&[
        "~/.zshenv",
        "~/.zprofile",
        "~/.zshrc",
        "~/.zlogin",
        "~/.zlogout",
        "~/.zsh",
        "~/.oh-my-zsh",
        "~/.bashrc",
        "~/.bash_profile",
        "~/.profile",
        "~/.inputrc",
        "~/.gitconfig",
        "~/.gitignore_global",
        "~/.config/git",
        "~/.config/starship.toml",
        "~/.config/bridge/shell",
        "~/.local/bin",
        "~/.local/share/mise",
        "~/.nvm",
        "~/.volta",
        "~/.bun",
        "~/.deno",
        "~/.rustup",
        "~/.pyenv",
        "~/.rbenv",
        "~/.asdf",
        "~/.sdkman",
        "~/go",
        "~/Library/pnpm",
    ])
}

impl SandboxEngine {
    /// What a new Seatbelt profile starts from: tools and agents keep their caches and settings,
    /// credentials stay out of reach.
    pub fn seatbelt_defaults() -> Self {
        Self::Seatbelt {
            writable: list(&[
                "~/.cache",
                "~/Library/Caches",
                "~/.npm",
                "~/.cargo",
                "~/.claude",
                "~/.claude.json",
                "~/.codex",
                "~/.zcompdump",
            ]),
            hidden: list(&[
                "~/.ssh",
                "~/.aws",
                "~/.gnupg",
                "~/.kube",
                "~/.netrc",
                "~/.docker/config.json",
                "~/.config/gh",
                "~/Library/Keychains",
                "~/.config/bridge/profiles.json",
                "~/.config/bridge/history.jsonl",
            ]),
            network: Network::All,
            blocked: Vec::new(),
            block_keychain: true,
            confine_reads: true,
            readable: default_readable(),
            allow_clipboard: false,
            allow_open: false,
        }
    }

    pub fn docker_defaults() -> Self {
        Self::Docker {
            image: "ubuntu:24.04".to_owned(),
            network: true,
            mounts: Vec::new(),
            env: Vec::new(),
        }
    }
}

/// Name of the built-in sandbox profile.
pub const PROJECT_SANDBOX: &str = "Project";

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SandboxProfile {
    pub id: Id,
    pub name: String,
    pub engine: SandboxEngine,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Profiles {
    pub hosts: Vec<SshHost>,
    pub sandboxes: Vec<SandboxProfile>,
    /// The built-in Project sandbox, when edited (otherwise [`SandboxEngine::seatbelt_defaults`]).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project_sandbox: Option<SandboxEngine>,
    /// The linked Vaultwarden account, if any.
    pub vault: Option<crate::vault::VaultAccount>,
    next_id: Id,
}

impl Global for Profiles {}

impl Profiles {
    pub fn load() -> Self {
        let mut profiles: Self = fs::read_to_string(Self::path())
            .ok()
            // Paths saved before the app's folder was renamed.
            .map(|json| json.replace("~/.config/gpu-terminal/", "~/.config/bridge/"))
            .and_then(|json| serde_json::from_str(&json).ok())
            .unwrap_or_default();
        let max = profiles
            .hosts
            .iter()
            .flat_map(|host| {
                std::iter::once(host.id).chain(host.forwards.iter().map(|forward| forward.id))
            })
            .chain(profiles.sandboxes.iter().map(|sandbox| sandbox.id))
            .max()
            .unwrap_or(0);
        profiles.next_id = profiles.next_id.max(max + 1);
        profiles
    }

    pub fn save(&self) -> io::Result<()> {
        let path = Self::path();
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir)?;
        }
        fs::write(
            path,
            serde_json::to_string_pretty(self).map_err(io::Error::other)?,
        )
    }

    fn path() -> PathBuf {
        TerminalSettings::path().parent().map_or_else(
            || PathBuf::from("profiles.json"),
            |dir| dir.join("profiles.json"),
        )
    }

    pub fn get(cx: &App) -> &Self {
        cx.global::<Self>()
    }

    /// Change the profiles and save them.
    pub fn update<R>(cx: &mut App, f: impl FnOnce(&mut Self) -> R) -> R {
        let result = f(cx.global_mut::<Self>());
        if let Err(err) = cx.global::<Self>().save() {
            eprintln!("failed to save profiles: {err}");
        }
        result
    }

    pub fn host(&self, id: Id) -> Option<&SshHost> {
        self.hosts.iter().find(|host| host.id == id)
    }

    /// Add a host or replace the one with the same id (keeping its forwards); returns its id.
    pub fn upsert_host(&mut self, mut host: SshHost) -> Id {
        if let Some(existing) = self
            .hosts
            .iter_mut()
            .find(|existing| existing.id == host.id)
        {
            host.forwards = std::mem::take(&mut existing.forwards);
            *existing = host;
            return existing.id;
        }
        host.id = self.next_id();
        let id = host.id;
        self.hosts.push(host);
        id
    }

    pub fn remove_host(&mut self, id: Id) {
        self.hosts.retain(|host| host.id != id);
    }

    pub fn sandbox(&self, id: Id) -> Option<&SandboxProfile> {
        self.sandboxes.iter().find(|sandbox| sandbox.id == id)
    }

    /// A terminal's sandbox: the chosen profile, else (or when it was deleted) the Project one.
    pub fn sandbox_for(&self, profile: Option<Id>) -> SandboxProfile {
        match profile.and_then(|id| self.sandbox(id)) {
            Some(profile) => profile.clone(),
            None => self.project_profile(),
        }
    }

    /// The built-in Project sandbox, which every project terminal uses unless told otherwise.
    pub fn project_profile(&self) -> SandboxProfile {
        SandboxProfile {
            id: 0,
            name: PROJECT_SANDBOX.to_owned(),
            engine: self
                .project_sandbox
                .clone()
                .unwrap_or_else(SandboxEngine::seatbelt_defaults),
        }
    }

    /// Add a sandbox profile or replace the one with the same id; returns its id.
    pub fn upsert_sandbox(&mut self, mut sandbox: SandboxProfile) -> Id {
        if let Some(existing) = self
            .sandboxes
            .iter_mut()
            .find(|existing| existing.id == sandbox.id)
        {
            *existing = sandbox;
            return existing.id;
        }
        sandbox.id = self.next_id();
        let id = sandbox.id;
        self.sandboxes.push(sandbox);
        id
    }

    pub fn remove_sandbox(&mut self, id: Id) {
        self.sandboxes.retain(|sandbox| sandbox.id != id);
    }

    /// The host a forward belongs to, and the forward.
    pub fn forward(&self, id: Id) -> Option<(&SshHost, &Forward)> {
        self.hosts.iter().find_map(|host| {
            host.forwards
                .iter()
                .find(|forward| forward.id == id)
                .map(|forward| (host, forward))
        })
    }

    pub fn forward_mut(&mut self, id: Id) -> Option<&mut Forward> {
        self.hosts
            .iter_mut()
            .flat_map(|host| host.forwards.iter_mut())
            .find(|forward| forward.id == id)
    }

    /// Add a forward to `host` or replace the one with the same id; returns its id.
    pub fn upsert_forward(&mut self, host: Id, mut forward: Forward) -> Option<Id> {
        if let Some(existing) = self.forward_mut(forward.id) {
            *existing = forward;
            return Some(existing.id);
        }
        forward.id = self.next_id();
        let id = forward.id;
        self.hosts
            .iter_mut()
            .find(|candidate| candidate.id == host)?
            .forwards
            .push(forward);
        Some(id)
    }

    pub fn remove_forward(&mut self, id: Id) {
        for host in &mut self.hosts {
            host.forwards.retain(|forward| forward.id != id);
        }
    }

    fn next_id(&mut self) -> Id {
        let id = self.next_id.max(1);
        self.next_id = id + 1;
        id
    }
}

/// Saved SSH passwords, in the macOS Keychain under the service `gpu-terminal`.
pub mod keychain {
    use crate::workspace::Id;

    // The app's name before it was Bridge: saved passwords stay where they are.
    const SERVICE: &str = "gpu-terminal";

    fn entry(host: Id) -> keyring::Result<keyring::Entry> {
        keyring::Entry::new(SERVICE, &format!("ssh:{host}"))
    }

    pub fn password(host: Id) -> Option<String> {
        entry(host).and_then(|entry| entry.get_password()).ok()
    }

    pub fn has_password(host: Id) -> bool {
        password(host).is_some()
    }

    pub fn set_password(host: Id, password: &str) -> keyring::Result<()> {
        entry(host)?.set_password(password)
    }

    pub fn delete_password(host: Id) {
        if let Ok(entry) = entry(host) {
            let _ = entry.delete_credential();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn host(user: &str, port: u16) -> SshHost {
        SshHost {
            name: "box".into(),
            host: "example.com".into(),
            port,
            user: user.into(),
            ..SshHost::default()
        }
    }

    #[test]
    fn forwards_belong_to_hosts_and_survive_host_edits() {
        let mut profiles = Profiles::default();
        let box_ = profiles.upsert_host(host("me", 22));
        let db = profiles
            .upsert_forward(
                box_,
                Forward {
                    bind: "5433".into(),
                    target: "localhost:5432".into(),
                    ..Forward::default()
                },
            )
            .unwrap();
        assert_ne!(db, box_);
        assert_eq!(profiles.forward(db).unwrap().0.id, box_);
        // Editing the host from its dialog keeps its forwards.
        let mut edited = profiles.host(box_).unwrap().clone();
        edited.forwards.clear();
        profiles.upsert_host(edited);
        assert!(profiles.forward(db).is_some());
        profiles.remove_forward(db);
        assert!(profiles.forward(db).is_none());
        assert!(profiles.upsert_forward(999, Forward::default()).is_none());
    }

    #[test]
    fn forward_flags_and_listen_addresses() {
        let local = Forward {
            bind: "8080".into(),
            target: "db:5432".into(),
            ..Forward::default()
        };
        assert_eq!(
            local.ssh_flag(),
            ["-L".to_owned(), "8080:db:5432".to_owned()]
        );
        assert_eq!(local.summary(), "localhost:8080 → db:5432");
        let socks = Forward {
            kind: ForwardKind::Dynamic,
            bind: "0.0.0.0:1080".into(),
            ..Forward::default()
        };
        assert_eq!(
            socks.ssh_flag(),
            ["-D".to_owned(), "0.0.0.0:1080".to_owned()]
        );
        let remote = Forward {
            kind: ForwardKind::Remote,
            bind: "9000".into(),
            target: "localhost:3000".into(),
            ..Forward::default()
        };
        assert_eq!(
            remote.ssh_flag(),
            ["-R".to_owned(), "9000:localhost:3000".to_owned()]
        );
    }

    #[test]
    fn hosts_get_fresh_ids_and_are_replaced_in_place() {
        let mut profiles = Profiles::default();
        let a = profiles.upsert_host(host("me", 22));
        let b = profiles.upsert_host(host("", 2222));
        assert_ne!(a, b);
        let mut renamed = profiles.host(a).unwrap().clone();
        renamed.name = "renamed".into();
        assert_eq!(profiles.upsert_host(renamed), a);
        assert_eq!(profiles.hosts.len(), 2);
        assert_eq!(profiles.host(a).unwrap().name, "renamed");
        profiles.remove_host(a);
        assert!(profiles.host(a).is_none());
    }

    #[test]
    fn addresses_leave_out_defaults() {
        assert_eq!(host("me", 22).address(), "me@example.com");
        assert_eq!(host("", 2222).address(), "example.com:2222");
    }

    #[test]
    fn reads_a_hand_written_profiles_file() {
        let json = r#"{"hosts": [{"id": 1, "name": "box", "host": "example.com", "user": "me", "on_disconnect": "reconnect",
            "forwards": [{"id": 2, "name": "db", "kind": "local", "bind": "18080", "target": "localhost:5432", "show_logs": true, "enabled": true}]}],
            "next_id": 3}"#;
        let profiles: Profiles = serde_json::from_str(json).unwrap();
        let (host, forward) = profiles.forward(2).unwrap();
        assert_eq!(
            (host.on_disconnect, forward.enabled),
            (OnDisconnect::Reconnect, true)
        );
    }

    #[test]
    fn old_hosts_fill_in_defaults() {
        let host: SshHost = serde_json::from_str(r#"{"id":1,"name":"a","host":"h"}"#).unwrap();
        assert_eq!(
            (host.port, host.keepalive_secs, host.auth),
            (22, 30, SshAuth::Agent)
        );
    }
}
