//! `SSH_ASKPASS` mode: ssh runs this binary with a prompt as its argument and reads the answer
//! from its stdout. Password prompts are answered from the Keychain; any other prompt (a new host
//! key to confirm, a one-time code) is asked on the terminal ssh runs in.

use std::{
    fs::OpenOptions,
    io::{BufRead as _, BufReader, Write as _},
    os::fd::AsRawFd as _,
};

use super::ASKPASS_HOST;
use crate::{profiles::keychain, workspace::Id};

/// Run askpass if this process was started as one; returns `false` otherwise.
pub fn run_if_requested() -> bool {
    let Some(host) = std::env::var(ASKPASS_HOST)
        .ok()
        .and_then(|host| host.parse::<Id>().ok())
    else {
        return false;
    };
    let prompt = std::env::args().nth(1).unwrap_or_default();
    let answer = if is_password_prompt(&prompt) {
        keychain::password(host)
    } else {
        ask_on_terminal(&prompt)
    };
    match answer {
        Some(answer) => {
            println!("{answer}");
            std::process::exit(0);
        }
        None => std::process::exit(1),
    }
}

fn is_password_prompt(prompt: &str) -> bool {
    let prompt = prompt.to_lowercase();
    prompt.contains("password") && !prompt.contains("yes/no")
}

/// Ask on the controlling terminal; input is hidden unless it is a yes/no question.
fn ask_on_terminal(prompt: &str) -> Option<String> {
    let tty = OpenOptions::new()
        .read(true)
        .write(true)
        .open("/dev/tty")
        .ok()?;
    let mut out = tty.try_clone().ok()?;
    let _ = write!(out, "{prompt}");
    let _ = out.flush();
    let hide = !prompt.to_lowercase().contains("yes/no");
    let fd = tty.as_raw_fd();
    // SAFETY: plain termios calls on a terminal file descriptor this function owns.
    let saved = unsafe {
        let mut termios = std::mem::zeroed::<libc::termios>();
        (libc::tcgetattr(fd, &mut termios) == 0).then_some(termios)
    };
    if let (true, Some(mut quiet)) = (hide, saved) {
        quiet.c_lflag &= !libc::ECHO;
        unsafe { libc::tcsetattr(fd, libc::TCSANOW, &quiet) };
    }
    let mut line = String::new();
    let read = BufReader::new(&tty).read_line(&mut line);
    if let (true, Some(saved)) = (hide, saved) {
        unsafe { libc::tcsetattr(fd, libc::TCSANOW, &saved) };
        let _ = writeln!(out);
    }
    read.ok()?;
    Some(line.trim_end_matches(['\r', '\n']).to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_password_prompts_are_answered_from_the_keychain() {
        assert!(is_password_prompt("me@example.com's password: "));
        assert!(is_password_prompt("Password: "));
        assert!(!is_password_prompt(
            "Are you sure you want to continue connecting (yes/no/[fingerprint])? "
        ));
        assert!(!is_password_prompt("Verification code: "));
        assert!(!is_password_prompt(
            "Enter passphrase for key '/Users/me/.ssh/id_ed25519': "
        ));
    }
}
