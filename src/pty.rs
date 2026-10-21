//! Shell process on a pseudo-terminal.
//!
//! A reader thread forwards PTY output to the UI through an unbounded channel; a writer thread
//! drains input so a slow child can never block the UI thread.

use std::{
    io::{ErrorKind, Read, Write},
    path::PathBuf,
    sync::mpsc,
    thread,
};

use futures::channel::mpsc::UnboundedSender;
use portable_pty::{ChildKiller, CommandBuilder, MasterPty, PtySize, native_pty_system};

pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

/// Something the shell side produced.
pub enum PtyEvent {
    Output(Vec<u8>),
    /// The child exited; carries its exit code when known.
    Exited(Option<u32>),
}

/// How to launch the shell.
#[derive(Clone, Debug, Default)]
pub struct ShellConfig {
    /// `None` runs the user's login shell (in which case `args` must be empty).
    pub program: Option<String>,
    pub args: Vec<String>,
    /// Extra environment variables.
    pub env: Vec<(String, String)>,
    /// Inherited variables to leave out.
    pub env_remove: Vec<String>,
    /// Starting directory. `None` means `$HOME`.
    pub working_directory: Option<PathBuf>,
    pub cols: u16,
    pub rows: u16,
}

pub struct Pty {
    master: Box<dyn MasterPty + Send>,
    input: mpsc::Sender<Vec<u8>>,
    killer: Box<dyn ChildKiller + Send + Sync>,
}

impl Pty {
    pub fn spawn(config: &ShellConfig, events: UnboundedSender<PtyEvent>) -> Result<Self> {
        let pair = native_pty_system().openpty(PtySize {
            rows: config.rows.max(1),
            cols: config.cols.max(1),
            pixel_width: 0,
            pixel_height: 0,
        })?;

        let mut command = match &config.program {
            Some(program) => {
                let mut command = CommandBuilder::new(program);
                command.args(&config.args);
                command
            }
            None => CommandBuilder::new_default_prog(),
        };
        command.env("TERM", "xterm-256color");
        command.env("COLORTERM", "truecolor");
        command.env("TERM_PROGRAM", "gpu-terminal");
        command.env("TERM_PROGRAM_VERSION", env!("CARGO_PKG_VERSION"));
        for (key, value) in &config.env {
            command.env(key, value);
        }
        for key in &config.env_remove {
            command.env_remove(key);
        }
        let cwd = config
            .working_directory
            .clone()
            .filter(|dir| dir.is_dir())
            .or_else(|| std::env::var_os("HOME").map(PathBuf::from));
        if let Some(cwd) = cwd {
            command.cwd(cwd);
        }

        let mut child = pair.slave.spawn_command(command)?;
        // Only the child may hold the slave side, otherwise reads never see EOF on exit.
        drop(pair.slave);
        let killer = child.clone_killer();

        let mut reader = pair.master.try_clone_reader()?;
        thread::Builder::new()
            .name("pty-reader".into())
            .spawn(move || {
                let mut buf = vec![0u8; 64 * 1024];
                loop {
                    match reader.read(&mut buf) {
                        Ok(0) => break,
                        Ok(len) => {
                            if events
                                .unbounded_send(PtyEvent::Output(buf[..len].to_vec()))
                                .is_err()
                            {
                                return;
                            }
                        }
                        Err(err) if err.kind() == ErrorKind::Interrupted => continue,
                        // macOS reports EIO once the child side is closed.
                        Err(_) => break,
                    }
                }
                let code = child.wait().ok().map(|status| status.exit_code());
                let _ = events.unbounded_send(PtyEvent::Exited(code));
            })?;

        let mut writer = pair.master.take_writer()?;
        let (input, input_rx) = mpsc::channel::<Vec<u8>>();
        thread::Builder::new()
            .name("pty-writer".into())
            .spawn(move || {
                for bytes in input_rx {
                    if writer
                        .write_all(&bytes)
                        .and_then(|()| writer.flush())
                        .is_err()
                    {
                        break;
                    }
                }
            })?;

        Ok(Self {
            master: pair.master,
            input,
            killer,
        })
    }

    /// Queue bytes for the child's stdin.
    pub fn write(&self, bytes: &[u8]) {
        if !bytes.is_empty() {
            let _ = self.input.send(bytes.to_vec());
        }
    }

    /// Name of the process in the foreground of the terminal (the shell, or what it is running).
    pub fn foreground_process(&self) -> Option<String> {
        process_name(self.master.process_group_leader()?)
    }

    /// Tell the kernel (and so the child, via SIGWINCH) about a new grid size.
    pub fn resize(&self, cols: u16, rows: u16, cell_width: u32, cell_height: u32) {
        let size = PtySize {
            rows: rows.max(1),
            cols: cols.max(1),
            pixel_width: (u32::from(cols) * cell_width).min(u32::from(u16::MAX)) as u16,
            pixel_height: (u32::from(rows) * cell_height).min(u32::from(u16::MAX)) as u16,
        };
        if let Err(err) = self.master.resize(size) {
            eprintln!("failed to resize pty: {err}");
        }
    }
}

#[cfg(target_os = "macos")]
fn process_name(pid: libc::pid_t) -> Option<String> {
    let mut buf = [0u8; 256];
    // SAFETY: `proc_name` writes at most `buf.len()` bytes and returns how many it wrote.
    let len = unsafe { libc::proc_name(pid, buf.as_mut_ptr().cast(), buf.len() as u32) };
    (len > 0).then(|| String::from_utf8_lossy(&buf[..len as usize]).into_owned())
}

#[cfg(target_os = "linux")]
fn process_name(pid: libc::pid_t) -> Option<String> {
    let name = std::fs::read_to_string(format!("/proc/{pid}/comm")).ok()?;
    Some(name.trim_end().to_owned()).filter(|name| !name.is_empty())
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn process_name(_pid: i32) -> Option<String> {
    None
}

impl Drop for Pty {
    fn drop(&mut self) {
        let _ = self.killer.kill();
    }
}
