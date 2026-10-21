//! Vaultwarden: SSH keys from the user's vault, decrypted in memory and loaded into a private
//! ssh-agent while the vault is unlocked. Only the server, email and a device id are saved
//! (in the profiles); the master password and keys never are. Locking (by hand, after the chosen
//! idle time, or on quit) stops the agent, and its keys with it.

pub mod agent;
pub mod client;
pub mod crypto;
pub mod unlock_dialog;

use std::{cell::Cell, path::PathBuf, time::Instant};

use gpui::{App, Global};
use serde::{Deserialize, Serialize};

use self::{agent::Agent, client::LoginError};
use crate::{profiles::Profiles, ssh::VaultIdentity};

/// The linked account (saved; holds no secrets).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct VaultAccount {
    pub server: String,
    pub email: String,
    /// Sent with each login so the server knows this device.
    pub device_id: String,
    /// Lock after this many idle minutes; 0 never.
    #[serde(default = "default_lock_minutes")]
    pub lock_minutes: u32,
}

fn default_lock_minutes() -> u32 {
    60
}

impl VaultAccount {
    pub const LOCK_CHOICES: [(u32, &'static str); 4] = [
        (15, "15 min"),
        (60, "1 hour"),
        (240, "4 hours"),
        (0, "Never"),
    ];
}

/// A key the unlocked vault offers.
#[derive(Clone, Debug)]
pub struct VaultKeyInfo {
    pub id: String,
    pub name: String,
    pub public_key: PathBuf,
}

struct Session {
    agent: Agent,
    keys: Vec<VaultKeyInfo>,
    last_used: Cell<Instant>,
}

#[derive(Default)]
pub struct Vault {
    session: Option<Session>,
}

impl Global for Vault {}

/// What an unlock produced, ready to install on the main thread.
pub struct Unlocked {
    agent: Agent,
    keys: Vec<VaultKeyInfo>,
    skipped: usize,
    /// Keys that could not be loaded into the agent, with why.
    pub failures: Vec<String>,
}

/// Log in, start the agent and load the keys. Blocking: run it off the main thread.
pub fn unlock(login: &client::Login) -> Result<Unlocked, LoginError> {
    let vault = client::unlock(login)?;
    let agent = Agent::start()
        .map_err(|err| LoginError::Rejected(format!("could not start ssh-agent: {err}")))?;
    let mut keys = Vec::new();
    let mut failures = Vec::new();
    for key in vault.keys {
        match agent.add(&key.id, &key.private_key) {
            Ok(public_key) => keys.push(VaultKeyInfo {
                id: key.id,
                name: key.name,
                public_key,
            }),
            Err(err) => failures.push(format!("{}: {err}", key.name)),
        }
    }
    Ok(Unlocked {
        agent,
        keys,
        skipped: vault.skipped,
        failures,
    })
}

impl Vault {
    pub fn install(unlocked: Unlocked, cx: &mut App) {
        cx.set_global(Self {
            session: Some(Session {
                agent: unlocked.agent,
                keys: unlocked.keys,
                last_used: Cell::new(Instant::now()),
            }),
        });
    }

    pub fn is_unlocked(cx: &App) -> bool {
        cx.try_global::<Self>()
            .is_some_and(|vault| vault.session.is_some())
    }

    pub fn keys(cx: &App) -> Vec<VaultKeyInfo> {
        cx.try_global::<Self>()
            .and_then(|vault| vault.session.as_ref())
            .map(|session| session.keys.clone())
            .unwrap_or_default()
    }

    /// The agent and public key ssh should use for a vault key (`None` while locked).
    pub fn identity(item: &str, cx: &App) -> Option<VaultIdentity> {
        let session = cx.try_global::<Self>()?.session.as_ref()?;
        let key = session.keys.iter().find(|key| key.id == item)?;
        session.last_used.set(Instant::now());
        Some(VaultIdentity {
            socket: session.agent.socket().to_path_buf(),
            public_key: key.public_key.clone(),
        })
    }

    /// Stop the agent; its keys go with it.
    pub fn lock(cx: &mut App) {
        cx.set_global(Self::default());
    }

    /// Lock when the vault has gone unused for the account's chosen time.
    pub fn lock_if_idle(cx: &mut App) {
        let minutes = Profiles::get(cx)
            .vault
            .as_ref()
            .map_or(0, |account| account.lock_minutes);
        let idle = cx
            .try_global::<Self>()
            .and_then(|vault| vault.session.as_ref())
            .is_some_and(|session| {
                minutes > 0
                    && session.last_used.get().elapsed().as_secs() >= u64::from(minutes) * 60
            });
        if idle {
            Self::lock(cx);
        }
    }
}
