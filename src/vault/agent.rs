//! A private `ssh-agent` holding the vault's keys in memory. Keys are handed to it through
//! `ssh-add -` on stdin, so no private key is ever written to disk; only public keys are, so ssh
//! can be told which agent key to offer. The agent runs under the app's guard (it dies with the
//! app) and is stopped, with its folder removed, when the vault locks.

use std::{
    fs,
    io::{self, Write as _},
    os::unix::{fs::PermissionsExt as _, process::CommandExt as _},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    thread,
    time::Duration,
};

use crate::ssh::guard::GUARD;

pub struct Agent {
    dir: PathBuf,
    socket: PathBuf,
    /// The guard process (and the agent in its process group).
    pid: u32,
}

impl Agent {
    pub fn start() -> io::Result<Self> {
        // Short, private folder: socket paths are limited to about 100 bytes.
        let dir = std::env::temp_dir().join(format!(
            "gpu-term-{}",
            &uuid::Uuid::new_v4().simple().to_string()[..12]
        ));
        fs::create_dir(&dir)?;
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700))?;
        let socket = dir.join("agent.sock");
        // Under the guard (this binary) so the agent dies with the app; tests run it directly,
        // their executable being the test runner.
        let mut command = if cfg!(test) {
            Command::new("ssh-agent")
        } else {
            let mut guard = Command::new(std::env::current_exe()?);
            guard.env(GUARD, "1").arg("ssh-agent");
            guard
        };
        let child = command
            .process_group(0)
            .arg("-D")
            .arg("-a")
            .arg(&socket)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()?;
        let agent = Self {
            dir,
            socket,
            pid: child.id(),
        };
        for _ in 0..50 {
            if agent.socket.exists() {
                return Ok(agent);
            }
            thread::sleep(Duration::from_millis(40));
        }
        Err(io::Error::other("ssh-agent did not start"))
    }

    pub fn socket(&self) -> &Path {
        &self.socket
    }

    /// Load a private key; returns the file holding its public key (to point ssh at it).
    pub fn add(&self, id: &str, private_key: &str) -> Result<PathBuf, String> {
        let before = self.public_keys();
        let mut child = Command::new("ssh-add")
            .arg("-q")
            .arg("-")
            .env("SSH_AUTH_SOCK", &self.socket)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|err| format!("could not run ssh-add: {err}"))?;
        if let Some(mut stdin) = child.stdin.take() {
            let key = if private_key.ends_with('\n') {
                private_key.to_owned()
            } else {
                format!("{private_key}\n")
            };
            let mut key = zeroize::Zeroizing::new(key);
            let written = stdin.write_all(key.as_bytes());
            zeroize::Zeroize::zeroize(&mut *key);
            written.map_err(|err| format!("could not pass the key to ssh-add: {err}"))?;
        }
        let output = child
            .wait_with_output()
            .map_err(|err| format!("ssh-add failed: {err}"))?;
        if !output.status.success() {
            return Err(String::from_utf8_lossy(&output.stderr).trim().to_owned());
        }
        let public_key = self
            .public_keys()
            .into_iter()
            .find(|key| !before.contains(key))
            .ok_or("the key was already loaded or could not be read")?;
        let file = self.dir.join(format!("{}.pub", sanitize(id)));
        fs::write(&file, format!("{public_key}\n"))
            .map_err(|err| format!("could not save the public key: {err}"))?;
        Ok(file)
    }

    /// Public keys the agent holds, one `type base64 comment` line each.
    fn public_keys(&self) -> Vec<String> {
        Command::new("ssh-add")
            .arg("-L")
            .env("SSH_AUTH_SOCK", &self.socket)
            .stderr(Stdio::null())
            .output()
            .map(|output| {
                String::from_utf8_lossy(&output.stdout)
                    .lines()
                    .map(str::to_owned)
                    .collect()
            })
            .unwrap_or_default()
    }
}

impl Drop for Agent {
    fn drop(&mut self) {
        // SAFETY: signalling the process group of the guard this agent started.
        unsafe { libc::kill(-(self.pid as libc::pid_t), libc::SIGTERM) };
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn sanitize(id: &str) -> String {
    id.chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || ch == '-' {
                ch
            } else {
                '_'
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn loads_keys_from_memory_and_cleans_up() {
        // A throwaway key, read into memory and its file removed straight away.
        let scratch = std::env::temp_dir().join(format!("gpu-term-test-{}", std::process::id()));
        fs::create_dir_all(&scratch).unwrap();
        let file = scratch.join("id");
        let made = Command::new("ssh-keygen")
            .args(["-q", "-t", "ed25519", "-N", "", "-C", "test", "-f"])
            .arg(&file)
            .status()
            .unwrap();
        assert!(made.success());
        let private_key = fs::read_to_string(&file).unwrap();
        let expected = fs::read_to_string(file.with_extension("pub")).unwrap();
        fs::remove_dir_all(&scratch).unwrap();

        let agent = Agent::start().unwrap();
        let dir = agent.dir.clone();
        let public_key = agent.add("item/1", &private_key).unwrap();
        let loaded = fs::read_to_string(&public_key).unwrap();
        // Same key (the agent names it "(stdin)" instead of the file's comment).
        assert_eq!(
            loaded.split_whitespace().take(2).collect::<Vec<_>>(),
            expected.split_whitespace().take(2).collect::<Vec<_>>()
        );
        // Only the public half is on disk.
        let files: Vec<String> = fs::read_dir(&dir)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert!(
            files
                .iter()
                .all(|name| name.ends_with(".pub") || name == "agent.sock"),
            "{files:?}"
        );
        assert!(
            agent.add("again", &private_key).is_err(),
            "the same key twice is reported"
        );

        drop(agent);
        assert!(!dir.exists(), "locking removes the agent's folder");
    }
}
