//! Guard mode: forwards run as `<this binary> ssh …` with [`GUARD`] set, and this process runs
//! ssh and stops it as soon as the app is gone, even when the app was killed or crashed and could
//! not stop it itself. Without it an orphaned `ssh -N` would keep its port open.

use std::{
    process::{Command, exit},
    thread,
    time::Duration,
};

/// Environment variable that starts this binary in guard mode.
pub const GUARD: &str = "GPU_TERMINAL_GUARD";

/// Run as a guard if this process was started as one; returns `false` otherwise.
pub fn run_if_requested() -> bool {
    if std::env::var_os(GUARD).is_none() {
        return false;
    }
    let mut args = std::env::args_os().skip(1);
    let Some(program) = args.next() else {
        exit(127);
    };
    // SAFETY: getppid has no preconditions.
    let parent = unsafe { libc::getppid() };
    let mut child = match Command::new(program).args(args).env_remove(GUARD).spawn() {
        Ok(child) => child,
        Err(err) => {
            eprintln!("could not start ssh: {err}");
            exit(127);
        }
    };
    loop {
        if let Ok(Some(status)) = child.try_wait() {
            exit(status.code().unwrap_or(1));
        }
        // Orphans are adopted by launchd, so a new parent means the app is gone.
        if unsafe { libc::getppid() } != parent {
            let _ = child.kill();
            exit(1);
        }
        thread::sleep(Duration::from_millis(500));
    }
}
