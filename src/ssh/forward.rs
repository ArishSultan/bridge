//! Port forwards: every switched-on forward is its own `ssh -N -v` process, so each can be
//! toggled on its own even when several use the same server. Its state is read from ssh's
//! verbose log on stderr; when a connection drops it is retried with backoff if its host says so.

use std::{
    collections::{HashMap, VecDeque},
    io::{BufRead as _, BufReader},
    os::unix::process::CommandExt as _,
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};

use futures::{StreamExt as _, channel::mpsc::UnboundedSender};
use gpui::{Context, EventEmitter, SharedString, Task};

use crate::{
    profiles::{OnDisconnect, Profiles, SshAuth, keychain},
    vault::Vault,
    workspace::Id,
};

/// Log lines kept per forward.
const MAX_LOG_LINES: usize = 2000;

/// How long a connection must stay up before a drop starts the backoff over.
const STABLE_AFTER: Duration = Duration::from_secs(30);

/// Waits before reconnect attempt `n` (the last one repeats).
const BACKOFF_SECS: [u64; 5] = [1, 2, 5, 10, 30];

pub fn backoff(attempt: u32) -> Duration {
    Duration::from_secs(BACKOFF_SECS[(attempt as usize).min(BACKOFF_SECS.len() - 1)])
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum Status {
    #[default]
    Off,
    Connecting,
    Up,
    /// Waiting to reconnect (attempt number).
    Retrying(u32),
    Failed(String),
}

impl Status {
    pub fn describe(&self) -> String {
        match self {
            Self::Off => "Off".into(),
            Self::Connecting => "Connecting…".into(),
            Self::Up => "Forwarding".into(),
            Self::Retrying(attempt) => format!("Reconnecting (attempt {})…", attempt + 1),
            Self::Failed(reason) => format!("Failed: {reason}"),
        }
    }
}

/// A forward's connection dropped after it had been up.
pub struct Dropped {
    pub forward: Id,
    pub reason: String,
    pub notify: bool,
}

enum ProcessEvent {
    Line(String),
    Exited(Option<i32>),
}

struct Run {
    status: Status,
    logs: VecDeque<SharedString>,
    /// The running ssh process, killed when the forward stops.
    pid: Option<u32>,
    /// Bumped per process, so events from one that was replaced are ignored.
    generation: u64,
    attempt: u32,
    /// When the current connection came up.
    up_since: Option<Instant>,
    _task: Task<()>,
}

impl Run {
    fn new() -> Self {
        Self {
            status: Status::Off,
            logs: VecDeque::new(),
            pid: None,
            generation: 0,
            attempt: 0,
            up_since: None,
            _task: Task::ready(()),
        }
    }

    fn kill(&mut self) {
        if let Some(pid) = self.pid.take() {
            // SAFETY: signalling the process group of the guard this run started (it and its ssh).
            unsafe { libc::kill(-(pid as libc::pid_t), libc::SIGTERM) };
        }
    }

    fn log(&mut self, line: impl Into<SharedString>) {
        if self.logs.len() == MAX_LOG_LINES {
            self.logs.pop_front();
        }
        self.logs.push_back(line.into());
    }
}

impl Drop for Run {
    fn drop(&mut self) {
        self.kill();
    }
}

#[derive(Default)]
pub struct ForwardManager {
    runs: HashMap<Id, Run>,
}

impl EventEmitter<Dropped> for ForwardManager {}

impl ForwardManager {
    /// Start every forward that was switched on when the app last ran.
    pub fn new(cx: &mut Context<Self>) -> Self {
        let mut this = Self::default();
        let enabled: Vec<Id> = Profiles::get(cx)
            .hosts
            .iter()
            .flat_map(|host| {
                host.forwards
                    .iter()
                    .filter(|forward| forward.enabled)
                    .map(|forward| forward.id)
            })
            .collect();
        for forward in enabled {
            this.start(forward, cx);
        }
        this
    }

    pub fn status(&self, forward: Id) -> Status {
        self.runs
            .get(&forward)
            .map(|run| run.status.clone())
            .unwrap_or_default()
    }

    pub fn logs(&self, forward: Id) -> Vec<SharedString> {
        self.runs
            .get(&forward)
            .map(|run| run.logs.iter().cloned().collect())
            .unwrap_or_default()
    }

    /// Switch a forward on or off (remembered for the next launch).
    pub fn set_enabled(&mut self, forward: Id, enabled: bool, cx: &mut Context<Self>) {
        Profiles::update(cx, |profiles| {
            if let Some(forward) = profiles.forward_mut(forward) {
                forward.enabled = enabled;
            }
        });
        if enabled {
            if let Some(run) = self.runs.get_mut(&forward) {
                run.attempt = 0;
            }
            self.start(forward, cx);
        } else {
            self.stop(forward, cx);
        }
    }

    /// Restart a running forward with its current settings (after it was edited).
    pub fn reload(&mut self, forward: Id, cx: &mut Context<Self>) {
        let enabled = Profiles::get(cx)
            .forward(forward)
            .is_some_and(|(_, forward)| forward.enabled);
        if enabled {
            self.start(forward, cx);
        } else {
            self.stop(forward, cx);
        }
    }

    pub fn stop(&mut self, forward: Id, cx: &mut Context<Self>) {
        if let Some(run) = self.runs.get_mut(&forward) {
            run.kill();
            run.generation += 1;
            run.status = Status::Off;
            run._task = Task::ready(());
            run.log("Stopped.");
        }
        cx.notify();
    }

    pub fn stop_all(&mut self) {
        for run in self.runs.values_mut() {
            run.kill();
        }
    }

    pub fn remove(&mut self, forward: Id, cx: &mut Context<Self>) {
        self.runs.remove(&forward);
        cx.notify();
    }

    fn start(&mut self, forward_id: Id, cx: &mut Context<Self>) {
        let Some((host, forward)) = Profiles::get(cx)
            .forward(forward_id)
            .map(|(host, forward)| (host.clone(), forward.clone()))
        else {
            return;
        };
        let saved = host.auth == SshAuth::Password && keychain::has_password(host.id);
        let vault = match &host.auth {
            SshAuth::Vault { item, .. } => match Vault::identity(item, cx) {
                Some(identity) => Some(identity),
                None => {
                    let run = self.runs.entry(forward_id).or_insert_with(Run::new);
                    run.kill();
                    run.generation += 1;
                    run.status = Status::Failed("Vaultwarden is locked".into());
                    cx.notify();
                    return;
                }
            },
            _ => None,
        };
        let command = super::forwarding(&host, &forward, saved, vault.as_ref());

        let run = self.runs.entry(forward_id).or_insert_with(Run::new);
        run.kill();
        run.generation += 1;
        let generation = run.generation;
        run.status = Status::Connecting;
        run.log(format!("$ ssh {}", command.args.join(" ")));

        // Through a guard (this binary), so ssh never outlives the app; in its own process group
        // so stopping it stops both.
        let Ok(exe) = std::env::current_exe() else {
            run.status = Status::Failed("could not find the app's executable".into());
            cx.notify();
            return;
        };
        let mut process = Command::new(exe);
        process
            .env(super::guard::GUARD, "1")
            .process_group(0)
            .arg(&command.program)
            .args(&command.args)
            .envs(command.env.iter().map(|(key, value)| (key, value)))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::piped());
        let mut child = match process.spawn() {
            Ok(child) => child,
            Err(err) => {
                run.status = Status::Failed(format!("could not start ssh: {err}"));
                cx.notify();
                return;
            }
        };
        run.pid = Some(child.id());

        let (events, mut received) = futures::channel::mpsc::unbounded::<ProcessEvent>();
        let stderr = child.stderr.take();
        let spawned = thread::Builder::new()
            .name("ssh-forward".into())
            .spawn(move || {
                if let Some(stderr) = stderr {
                    for line in BufReader::new(stderr).lines().map_while(Result::ok) {
                        if events.unbounded_send(ProcessEvent::Line(line)).is_err() {
                            break;
                        }
                    }
                }
                let code = child.wait().ok().and_then(|status| status.code());
                send(&events, ProcessEvent::Exited(code));
            });
        if spawned.is_err() {
            run.status = Status::Failed("could not watch ssh".into());
        }
        run._task = cx.spawn(async move |this, cx| {
            while let Some(event) = received.next().await {
                if this
                    .update(cx, |this, cx| {
                        this.on_event(forward_id, generation, event, cx)
                    })
                    .is_err()
                {
                    break;
                }
            }
        });
        cx.notify();
    }

    fn on_event(
        &mut self,
        forward: Id,
        generation: u64,
        event: ProcessEvent,
        cx: &mut Context<Self>,
    ) {
        let Some(run) = self
            .runs
            .get_mut(&forward)
            .filter(|run| run.generation == generation)
        else {
            return;
        };
        match event {
            ProcessEvent::Line(line) => {
                if is_up(&line) && run.status != Status::Up {
                    run.status = Status::Up;
                    run.up_since = Some(Instant::now());
                }
                run.log(line);
            }
            ProcessEvent::Exited(code) => {
                run.pid = None;
                let was_up = run.status == Status::Up;
                // A connection that stayed up a while starts the backoff over; one that keeps
                // dropping right away waits longer each time.
                if run
                    .up_since
                    .take()
                    .is_some_and(|since| since.elapsed() >= STABLE_AFTER)
                {
                    run.attempt = 0;
                }
                let reason = failure_reason(run.logs.iter().map(|line| line.as_ref()), code);
                run.log(format!("ssh exited ({reason})."));
                let policy = Profiles::get(cx)
                    .forward(forward)
                    .map(|(host, _)| host.on_disconnect)
                    .unwrap_or_default();
                if policy == OnDisconnect::Reconnect {
                    let attempt = run.attempt;
                    run.attempt += 1;
                    run.status = Status::Retrying(attempt);
                    run._task = cx.spawn(async move |this, cx| {
                        cx.background_executor().timer(backoff(attempt)).await;
                        let _ = this.update(cx, |this, cx| {
                            if this
                                .runs
                                .get(&forward)
                                .is_some_and(|run| run.generation == generation)
                            {
                                this.start(forward, cx);
                            }
                        });
                    });
                } else {
                    run.status = Status::Failed(reason.clone());
                }
                if was_up {
                    cx.emit(Dropped {
                        forward,
                        reason,
                        notify: policy == OnDisconnect::Notify,
                    });
                }
            }
        }
        cx.notify();
    }
}

fn send(events: &UnboundedSender<ProcessEvent>, event: ProcessEvent) {
    let _ = events.unbounded_send(event);
}

/// Whether an ssh `-v` line means the forward is listening.
fn is_up(line: &str) -> bool {
    line.contains("forwarding listening on") || line.contains("remote forward success")
}

/// The most telling line of a failed connection: the last that is not debug chatter.
fn failure_reason<'a>(
    lines: impl DoubleEndedIterator<Item = &'a str>,
    code: Option<i32>,
) -> String {
    lines
        .rev()
        .take(50)
        .map(str::trim)
        .find(|line| {
            !line.is_empty()
                && !line.starts_with("debug")
                && !line.starts_with('$')
                && !line.starts_with("ssh exited")
        })
        .map(str::to_owned)
        .unwrap_or_else(|| {
            code.map_or_else(
                || "connection closed".to_owned(),
                |code| format!("exit code {code}"),
            )
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backoff_grows_then_holds() {
        let waits: Vec<u64> = (0..7).map(|attempt| backoff(attempt).as_secs()).collect();
        assert_eq!(waits, [1, 2, 5, 10, 30, 30, 30]);
    }

    #[test]
    fn reads_state_from_ssh_logs() {
        assert!(is_up(
            "debug1: Local forwarding listening on 127.0.0.1 port 8080."
        ));
        assert!(is_up(
            "debug1: remote forward success for: listen 9000, connect localhost:3000"
        ));
        assert!(!is_up("debug1: Connecting to example.com port 22."));

        let lines = [
            "debug1: Connecting to example.com [1.2.3.4] port 22.",
            "ssh: connect to host example.com port 22: Connection refused",
            "debug1: some trailing chatter",
        ];
        assert_eq!(
            failure_reason(lines.iter().copied(), Some(255)),
            "ssh: connect to host example.com port 22: Connection refused"
        );
        assert_eq!(
            failure_reason(["debug1: x"].iter().copied(), Some(255)),
            "exit code 255"
        );
    }
}
