//! Sandboxed terminals, for running agents. Two engines, chosen per profile:
//! - **Seatbelt**, macOS's own sandbox (what Claude Code and Codex use): the user's shell and
//!   tools, but writes only inside the project and chosen paths, credentials hidden, network
//!   optionally cut, and some programs refused. With reads confined, file contents can only be
//!   read in the project, system folders and the shell's and toolchains' setup in the home folder;
//!   whether a path exists (its metadata) stays visible, since tools look up paths all the time.
//!   Profiles start from `(allow default)` and deny on top; later rules override earlier ones.
//! - **Docker**: a Linux container that sees only the terminal's folder (and chosen mounts).

pub mod profile_dialog;

use std::{
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

use crate::{
    profiles::{Network, SandboxEngine, SandboxProfile},
    workspace::{Id, expand_home},
};

/// A shell wrapped in a sandbox.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SandboxCommand {
    pub program: String,
    pub args: Vec<String>,
    /// Inherited variables to drop (the ssh-agent socket would hand out the user's keys).
    pub env_remove: Vec<String>,
}

/// Run `shell` (with `shell_args`) in `profile`'s sandbox: everything in the project folder `root`
/// (and `extra_writable`, such as the session's own history file) is writable, and it starts in
/// `dir` (inside `root`).
pub fn wrap(
    profile: &SandboxProfile,
    pane: Id,
    root: &Path,
    dir: &Path,
    shell: &str,
    shell_args: &[String],
    extra_writable: &[PathBuf],
) -> SandboxCommand {
    match &profile.engine {
        SandboxEngine::Seatbelt {
            writable,
            hidden,
            network,
            blocked,
            block_keychain,
            confine_reads,
            readable,
            allow_clipboard,
            allow_open,
        } => {
            let policy = seatbelt_profile(&Seatbelt {
                dir: root,
                writable,
                hidden,
                network: *network,
                blocked,
                block_keychain: *block_keychain,
                readable: confine_reads.then_some(readable.as_slice()),
                extra_writable,
                allow_clipboard: *allow_clipboard,
                allow_open: *allow_open,
            });
            let mut args = vec!["-p".to_owned(), policy, shell.to_owned()];
            args.extend(shell_args.iter().cloned());
            SandboxCommand {
                program: "/usr/bin/sandbox-exec".to_owned(),
                args,
                env_remove: vec!["SSH_AUTH_SOCK".to_owned()],
            }
        }
        SandboxEngine::Docker {
            image,
            network,
            mounts,
            env,
        } => {
            let inside = dir.strip_prefix(root).unwrap_or(Path::new(""));
            SandboxCommand {
                program: "docker".to_owned(),
                args: docker_args(pane, root, inside, image, *network, mounts, env),
                env_remove: Vec::new(),
            }
        }
    }
}

/// The container a Docker pane runs in.
pub fn container_name(pane: Id) -> String {
    format!("gpu-terminal-{pane}")
}

/// Remove a Docker pane's container (closing the terminal leaves it running otherwise).
pub fn stop_container(pane: Id) {
    let _ = Command::new("docker")
        .args(["rm", "-f", &container_name(pane)])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
}

/// `root` is mounted at `/workspace`; the shell starts in `inside` (relative to it).
fn docker_args(
    pane: Id,
    root: &Path,
    inside: &Path,
    image: &str,
    network: bool,
    mounts: &[String],
    env: &[String],
) -> Vec<String> {
    let mut args: Vec<String> = [
        "run",
        "--rm",
        "-it",
        "--init",
        "--name",
        &container_name(pane),
        "--hostname",
        "sandbox",
    ]
    .iter()
    .map(|arg| (*arg).to_owned())
    .collect();
    let workdir = Path::new("/workspace").join(inside);
    args.extend([
        "-v".to_owned(),
        format!("{}:/workspace", root.display()),
        "-w".to_owned(),
        workdir.display().to_string(),
    ]);
    if !network {
        args.extend(["--network".to_owned(), "none".to_owned()]);
    }
    for mount in mounts
        .iter()
        .map(|mount| mount.trim())
        .filter(|mount| !mount.is_empty())
    {
        let mount = match mount.split_once(':') {
            Some((host, rest)) => format!("{}:{rest}", expand_home(host).display()),
            None => mount.to_owned(),
        };
        args.extend(["-v".to_owned(), mount]);
    }
    for name in env
        .iter()
        .map(|name| name.trim())
        .filter(|name| !name.is_empty())
    {
        args.extend(["-e".to_owned(), name.to_owned()]);
    }
    args.push(if image.trim().is_empty() {
        "ubuntu:24.04".to_owned()
    } else {
        image.trim().to_owned()
    });
    args.extend([
        "/bin/sh".to_owned(),
        "-c".to_owned(),
        "if command -v bash >/dev/null 2>&1; then exec bash -l; else exec sh -l; fi".to_owned(),
    ]);
    args
}

struct Seatbelt<'a> {
    dir: &'a Path,
    writable: &'a [String],
    hidden: &'a [String],
    network: Network,
    blocked: &'a [String],
    block_keychain: bool,
    /// With reads confined: what is readable besides the project, system folders and what is
    /// writable. `None` leaves reads open.
    readable: Option<&'a [String]>,
    extra_writable: &'a [PathBuf],
    allow_clipboard: bool,
    allow_open: bool,
}

/// Files in the app's folder that no sandbox may read or change.
const APP_PRIVATE: &[&str] = &[
    "profiles.json",
    "history.jsonl",
    "projects.json",
    "settings.json",
];

/// System locations programs need to read: binaries, libraries, frameworks, Homebrew, settings
/// like the time zone and DNS resolver, and the shell links in `/var/select`.
const SYSTEM_READABLE: &[&str] = &[
    "/usr",
    "/bin",
    "/sbin",
    "/System",
    "/Library",
    "/opt",
    "/Applications",
    "/dev",
    "/private/etc",
    "/private/var/db",
    "/private/var/run",
    "/private/var/select",
];

/// The SBPL profile text.
fn seatbelt_profile(policy: &Seatbelt<'_>) -> String {
    let mut writable = vec![
        resolve(policy.dir),
        PathBuf::from("/private/tmp"),
        PathBuf::from("/private/var/folders"),
    ];
    if let Some(tmp) = std::env::var_os("TMPDIR") {
        writable.push(resolve(Path::new(&tmp)));
    }
    writable.extend(
        policy
            .writable
            .iter()
            .map(|path| resolve(&expand_home(path.trim()))),
    );
    writable.extend(policy.extra_writable.iter().map(|path| resolve(path)));
    let mut hidden: Vec<PathBuf> = policy
        .hidden
        .iter()
        .filter(|path| !path.trim().is_empty())
        .map(|path| resolve(&expand_home(path.trim())))
        .collect();
    // The app's own records are never readable, whatever the profile says: the SSH hosts and
    // vault account, every command typed in open terminals, and the app's settings.
    let app = crate::settings::config_dir();
    hidden.extend(APP_PRIVATE.iter().map(|name| resolve(&app.join(name))));

    let mut profile = String::from("(version 1)\n(allow default)\n");
    if let Some(readable) = policy.readable {
        // Contents only where allowed; metadata (does it exist, what is it) stays visible.
        profile.push_str("(deny file-read-data)\n(allow file-read-data\n");
        profile.push_str("  (literal \"/\") (literal \"/etc\") (literal \"/var\") (literal \"/tmp\") (literal \"/private\")\n");
        for path in SYSTEM_READABLE {
            profile.push_str(&format!("  (subpath \"{path}\")\n"));
        }
        let listed = readable
            .iter()
            .filter(|path| !path.trim().is_empty())
            .map(|path| resolve(&expand_home(path.trim())));
        let detected = shell_setup_paths(&expand_home("~"), std::env::var("PATH").ok().as_deref())
            .into_iter()
            .map(|path| resolve(&path));
        for path in writable.iter().cloned().chain(listed).chain(detected) {
            push_path_rules(&mut profile, &path);
        }
        let names = ANCESTOR_CONFIG
            .iter()
            .map(|name| regex_escape(Path::new(name)))
            .collect::<Vec<_>>()
            .join("|");
        for ancestor in resolve(policy.dir)
            .ancestors()
            .skip(1)
            .filter(|dir| dir.parent().is_some())
        {
            profile.push_str(&format!(
                "  (regex #\"^{}/({names})$\")\n",
                regex_escape(ancestor)
            ));
        }
        profile.push_str(")\n");
    }
    profile.push_str("(deny file-write*)\n(allow file-write*\n");
    for path in &writable {
        push_path_rules(&mut profile, path);
    }
    // The terminal itself and the usual device files.
    profile.push_str("  (literal \"/dev/null\") (literal \"/dev/zero\") (literal \"/dev/tty\") (literal \"/dev/dtracehelper\")\n");
    profile.push_str("  (regex #\"^/dev/ttys[0-9]+$\") (regex #\"^/dev/fd/\"))\n");
    if !hidden.is_empty() {
        profile.push_str("(deny file-read* file-write*\n");
        for path in &hidden {
            profile.push_str(&format!("  (subpath {})\n", quote(path)));
        }
        profile.push_str(")\n");
    }
    match policy.network {
        Network::All => {}
        Network::Localhost => {
            profile.push_str("(deny network-outbound (remote ip))\n(allow network-outbound (remote ip \"localhost:*\"))\n");
        }
        Network::None => profile
            .push_str("(deny network-outbound (remote ip))\n(deny network-bind (local ip))\n"),
    }
    let blocked: Vec<PathBuf> = policy
        .blocked
        .iter()
        .flat_map(|program| program_paths(program.trim()))
        .collect();
    if !blocked.is_empty() {
        profile.push_str("(deny process-exec\n");
        for path in &blocked {
            profile.push_str(&format!("  (literal {})\n", quote(path)));
        }
        profile.push_str(")\n");
    }
    if policy.block_keychain {
        profile.push_str("(deny mach-lookup (global-name \"com.apple.SecurityServer\") (global-name \"com.apple.securityd\"))\n");
    }
    // Other programs and services are not sandboxed, so asking them is closed off too: no
    // scripting other apps, no Spotlight (it would list and search files anywhere), and local
    // sockets only in /tmp (local databases), system ones in /var/run (DNS) and the project, never
    // the user's ssh-agent or a Docker daemon (a container could mount anything).
    profile.push_str("(deny appleevent-send)\n");
    profile.push_str("(deny mach-lookup (global-name-regex #\"^com\\.apple\\.metadata\\.mds\"))\n");
    profile.push_str("(deny network-outbound (remote unix-socket))\n(allow network-outbound\n");
    profile.push_str("  (remote unix-socket (path-regex #\"^/private/tmp/\"))\n");
    profile.push_str("  (remote unix-socket (path-regex #\"^/private/var/run/\"))\n");
    profile.push_str(&format!(
        "  (remote unix-socket (path-regex #\"^{}/\")))\n",
        regex_escape(&resolve(policy.dir))
    ));
    profile.push_str("(deny network-outbound\n");
    profile.push_str(
        "  (remote unix-socket (path-regex #\"^/private/tmp/com\\.apple\\.launchd\\.\"))\n",
    );
    profile.push_str("  (remote unix-socket (path-regex #\"docker\\.sock$\")))\n");
    if !policy.allow_clipboard {
        profile.push_str("(deny mach-lookup (global-name \"com.apple.pasteboard.1\"))\n");
    }
    if !policy.allow_open {
        // LaunchServices: how `open` (and any app) starts apps and opens files and links.
        profile.push_str("(deny mach-lookup (global-name-regex #\"^com\\.apple\\.lsd\\.\"))\n");
    }
    profile
}

/// The real path, so `/tmp` matches as `/private/tmp` and symlinked folders as their target. A
/// path that does not exist yet keeps its resolved parent.
fn resolve(path: &Path) -> PathBuf {
    if let Ok(real) = path.canonicalize() {
        return real;
    }
    match (
        path.parent().and_then(|parent| parent.canonicalize().ok()),
        path.file_name(),
    ) {
        (Some(parent), Some(name)) => parent.join(name),
        _ => path.to_path_buf(),
    }
}

/// Every path a blocked program could be run from: each match on PATH, and what it links to.
fn program_paths(program: &str) -> Vec<PathBuf> {
    if program.is_empty() {
        return Vec::new();
    }
    let candidates: Vec<PathBuf> = if program.contains('/') {
        vec![expand_home(program)]
    } else {
        std::env::var_os("PATH")
            .map(|path| {
                std::env::split_paths(&path)
                    .map(|dir| dir.join(program))
                    .filter(|path| path.is_file())
                    .collect()
            })
            .unwrap_or_default()
    };
    let mut paths = Vec::new();
    for candidate in candidates {
        let real = resolve(&candidate);
        if !paths.contains(&candidate) {
            paths.push(candidate);
        }
        if !paths.contains(&real) {
            paths.push(real);
        }
    }
    paths
}

/// What the user's shell setup needs to read in the home folder, found by reading it: the files the
/// startup files source (one level deeper too) and the home toolchains they and `path` put on
/// PATH (`~/.bun/bin` stands for `~/.bun`, `~/.local/share/vite-plus/bin` for
/// `~/.local/share/vite-plus`).
fn shell_setup_paths(home: &Path, path: Option<&str>) -> Vec<PathBuf> {
    const STARTUP: &[&str] = &[
        ".zshenv",
        ".zprofile",
        ".zshrc",
        ".zlogin",
        ".bashrc",
        ".bash_profile",
        ".profile",
    ];
    let mut found: Vec<PathBuf> = Vec::new();
    let add = |path: PathBuf, found: &mut Vec<PathBuf>| {
        if path.starts_with(home) && path != home && !found.contains(&path) {
            found.push(path);
        }
    };
    let mut queue: Vec<(PathBuf, u8)> = STARTUP.iter().map(|name| (home.join(name), 0)).collect();
    while let Some((file, depth)) = queue.pop() {
        let Ok(text) = std::fs::read_to_string(&file) else {
            continue;
        };
        for line in text
            .lines()
            .map(str::trim)
            .filter(|line| !line.starts_with('#'))
        {
            // `source FILE` / `. FILE`
            let sourced = line
                .strip_prefix("source ")
                .or_else(|| line.strip_prefix(". "));
            if let Some(target) = sourced
                .and_then(|rest| rest.split_whitespace().next())
                .and_then(|word| home_path(word, home))
            {
                if depth < 2 && target.is_file() {
                    queue.push((target.clone(), depth + 1));
                }
                // A tool's file comes with the tool's folder (`~/.config/vite-plus/env`).
                if let Some(folder) = target
                    .parent()
                    .filter(|folder| *folder != home && *folder != home.join(".config"))
                {
                    add(folder.to_path_buf(), &mut found);
                }
                add(target, &mut found);
            }
            if line.contains("PATH") {
                for entry in line.split([':', '"', '\'', '=', ' ', '(', ')']) {
                    if let Some(dir) = home_path(entry, home) {
                        add(tool_root(&dir, home), &mut found);
                    }
                }
            }
        }
    }
    for dir in path.map(std::env::split_paths).into_iter().flatten() {
        if dir.starts_with(home) {
            add(tool_root(&dir, home), &mut found);
        }
    }
    // A tool found under one standard folder keeps its state under the others too.
    const XDG: &[&str] = &[".config", ".local/share", ".local/state", ".cache"];
    let tools: Vec<String> = found
        .iter()
        .filter_map(|path| {
            let relative = path.strip_prefix(home).ok()?;
            let parent = relative.parent()?.to_string_lossy().into_owned();
            let name = relative.file_name()?.to_string_lossy().into_owned();
            XDG.contains(&parent.as_str()).then_some(name)
        })
        .collect();
    for tool in tools {
        for base in XDG {
            let dir = home.join(base).join(&tool);
            if dir.is_dir() {
                add(dir, &mut found);
            }
        }
    }
    found
}

/// A word of a shell file as a path in the home folder (`~/x`, `$HOME/x`, `${HOME}/x`, absolute).
fn home_path(word: &str, home: &Path) -> Option<PathBuf> {
    let word = word.trim_matches(|ch| ch == '"' || ch == '\'' || ch == ';');
    let rest = word
        .strip_prefix("~/")
        .or_else(|| word.strip_prefix("$HOME/"))
        .or_else(|| word.strip_prefix("${HOME}/"));
    let path = match rest {
        Some(rest) => home.join(rest),
        None if word.starts_with('/') && !word.contains('$') => PathBuf::from(word),
        None => return None,
    };
    Some(path).filter(|path| path.starts_with(home))
}

/// The folder a toolchain lives in, from a `bin` folder on PATH; `~/.local/bin` stays itself
/// (`~/.local` holds unrelated apps' data).
fn tool_root(dir: &Path, home: &Path) -> PathBuf {
    let name = dir
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default();
    match dir.parent() {
        Some(parent)
            if (name == "bin" || name.ends_with("-bin"))
                && parent != home
                && parent != home.join(".local") =>
        {
            parent.to_path_buf()
        }
        _ => dir.to_path_buf(),
    }
}

/// Filters matching `path`: the folder and what is in it; or the file, with the lock, temporary
/// and per-host files written beside it under its name plus a `.` or `-` suffix (zsh's
/// `.zsh_history.LOCK` and `.zcompdump-host-5.9`, Claude Code's `.claude.json.backup`).
fn push_path_rules(profile: &mut String, path: &Path) {
    profile.push_str(&format!("  (subpath {})\n", quote(path)));
    if !path.is_dir() {
        // An alternation, not `[.-]`: Seatbelt's regex engine misreads that bracket as a range.
        profile.push_str(&format!(
            "  (regex #\"^{}((\\.|-)[^/]*)?$\")\n",
            regex_escape(path)
        ));
    }
}

/// Config files tools look for in the folders above a project (version pins, workspace roots);
/// only these, not the folders' other contents, are readable there.
const ANCESTOR_CONFIG: &[&str] = &[
    "package.json",
    "package-lock.json",
    "pnpm-workspace.yaml",
    ".node-version",
    ".nvmrc",
    ".tool-versions",
    ".python-version",
    ".ruby-version",
    ".go-version",
    "rust-toolchain",
    "rust-toolchain.toml",
    ".editorconfig",
    ".gitignore",
    ".git",
    "tsconfig.json",
    "deno.json",
    "bunfig.toml",
    "nx.json",
    "turbo.json",
    "lerna.json",
    ".prettierrc",
    ".prettierrc.json",
    ".eslintrc.json",
];

/// A path as the start of an SBPL regex, its metacharacters escaped.
fn regex_escape(path: &Path) -> String {
    let mut out = String::new();
    for ch in path.to_string_lossy().chars() {
        if r#".^$|()[]{}*+?\""#.contains(ch) {
            out.push('\\');
        }
        out.push(ch);
    }
    out
}

/// A path as an SBPL string literal.
fn quote(path: &Path) -> String {
    format!(
        "\"{}\"",
        path.to_string_lossy()
            .replace('\\', "\\\\")
            .replace('"', "\\\"")
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn confined_reads_keep_contents_outside_the_project_out_of_reach() {
        let root = std::env::current_dir()
            .unwrap()
            .join("target")
            .join(format!("sbx-reads-{}", std::process::id()));
        let (project, other, tools) = (
            root.join("repo"),
            root.join("other-repo"),
            root.join("tools"),
        );
        for dir in [&project.join("src"), &other, &tools] {
            fs::create_dir_all(dir).unwrap();
        }
        fs::write(project.join("src/main.rs"), "fn main() {}").unwrap();
        fs::write(other.join("secret.txt"), "private").unwrap();
        fs::write(tools.join("config"), "ok").unwrap();
        let readable = vec![tools.to_string_lossy().into_owned()];
        let profile = seatbelt_profile(&Seatbelt {
            dir: &project,
            writable: &[],
            hidden: &[],
            network: Network::All,
            blocked: &[],
            block_keychain: true,
            readable: Some(&readable),
            extra_writable: &[],
            allow_clipboard: false,
            allow_open: false,
        });
        let quoted = |path: &Path| format!("'{}'", path.display());
        let in_project = format!("cd {} && ", quoted(&project));

        assert!(
            allowed(
                &profile,
                &format!("cat {}", quoted(&project.join("src/main.rs")))
            ),
            "the project is readable"
        );
        // (git refuses to run if it cannot read its config, so it gets the project as its home here;
        // the default readable list has `~/.gitconfig`.)
        assert!(
            allowed(
                &profile,
                &format!("{in_project}ls src && HOME=. git --version")
            ),
            "listing it and running tools works"
        );
        assert!(
            allowed(&profile, &format!("cat {}", quoted(&tools.join("config")))),
            "listed paths are readable"
        );
        assert!(
            allowed(&profile, "cat /etc/hosts && /usr/bin/env true"),
            "system files and programs work"
        );
        assert!(
            !allowed(
                &profile,
                &format!("cat {}", quoted(&other.join("secret.txt")))
            ),
            "other folders' contents are not"
        );
        assert!(
            !allowed(&profile, &format!("ls {}", quoted(&other))),
            "nor can they be listed"
        );
        assert!(
            !allowed(&profile, &format!("ls {}", quoted(&root))),
            "nor the folder above the project"
        );
        // Metadata stays visible: a path can be looked up and entered, not read.
        assert!(allowed(
            &profile,
            &format!(
                "test -f {} && cd {}",
                quoted(&other.join("secret.txt")),
                quoted(&other)
            )
        ));
        // Above the project only well-known config files can be read, so tools that look for a
        // version pin in parent folders still work.
        fs::write(root.join("package.json"), "{}").unwrap();
        fs::write(root.join("notes.txt"), "private").unwrap();
        assert!(allowed(
            &profile,
            &format!("cat {}", quoted(&root.join("package.json")))
        ));
        assert!(!allowed(
            &profile,
            &format!("cat {}", quoted(&root.join("notes.txt")))
        ));
        assert!(
            !allowed(
                &profile,
                &format!("cat {}", quoted(&root.join("package.json.bak")))
            ),
            "only exact names"
        );
        // A listed path that is not there (like `~/.zsh`) must not open files that merely start
        // with its name (`~/.zsh_history`).
        let zsh = tools.join(".zsh");
        let history = tools.join(".zsh_history");
        fs::write(&history, "secret").unwrap();
        let readable = vec![zsh.to_string_lossy().into_owned()];
        let profile = seatbelt_profile(&Seatbelt {
            dir: &project,
            writable: &[],
            hidden: &[],
            network: Network::All,
            blocked: &[],
            block_keychain: true,
            readable: Some(&readable),
            extra_writable: &[],
            allow_clipboard: false,
            allow_open: false,
        });
        assert!(
            !allowed(&profile, &format!("cat {}", quoted(&history))),
            "a name sharing a prefix is not covered"
        );
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn project_sandboxes_write_anywhere_in_the_project_but_nowhere_else() {
        let root = std::env::current_dir()
            .unwrap()
            .join("target")
            .join(format!("sbx-project-{}", std::process::id()));
        let (project, app, outside) = (
            root.join("repo"),
            root.join("repo/apps/api"),
            root.join("elsewhere"),
        );
        for dir in [&app, &outside] {
            fs::create_dir_all(dir).unwrap();
        }
        let profile = SandboxProfile {
            id: 0,
            name: "Project".into(),
            engine: crate::profiles::SandboxEngine::seatbelt_defaults(),
        };
        let wrapped = wrap(&profile, 1, &project, &app, "/bin/sh", &[], &[]);
        let policy = &wrapped.args[1];
        let file = |dir: &Path| dir.join("f").to_string_lossy().into_owned();
        assert!(
            allowed(policy, &format!("echo x > '{}'", file(&app))),
            "its own folder"
        );
        assert!(
            allowed(policy, &format!("echo x > '{}'", file(&project))),
            "the rest of the project"
        );
        assert!(
            !allowed(policy, &format!("echo x > '{}'", file(&outside))),
            "outside the project"
        );
        assert_eq!(wrapped.env_remove, ["SSH_AUTH_SOCK"]);
        fs::remove_dir_all(&root).unwrap();
    }

    /// Run a shell command under a profile; returns whether it succeeded.
    fn allowed(profile: &str, command: &str) -> bool {
        Command::new("/usr/bin/sandbox-exec")
            .args(["-p", profile, "/bin/sh", "-c", command])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|status| status.success())
    }

    #[test]
    fn seatbelt_confines_writes_hides_secrets_and_blocks_programs() {
        // Not under the temporary folders, which every sandbox may write to.
        let root = std::env::current_dir()
            .unwrap()
            .join("target")
            .join(format!("sbx-test-{}", std::process::id()));
        let (work, extra, secret, outside) = (
            root.join("work"),
            root.join("cache"),
            root.join("secret"),
            root.join("outside"),
        );
        for dir in [&work, &extra, &secret, &outside] {
            fs::create_dir_all(dir).unwrap();
        }
        fs::write(secret.join("key"), "s3cret").unwrap();
        let history = root.join("history");
        let writable = vec![
            extra.to_string_lossy().into_owned(),
            history.to_string_lossy().into_owned(),
        ];
        let hidden = vec![secret.to_string_lossy().into_owned()];
        let blocked = vec!["curl".to_owned()];
        let profile = seatbelt_profile(&Seatbelt {
            dir: &work,
            writable: &writable,
            hidden: &hidden,
            network: Network::None,
            blocked: &blocked,
            block_keychain: true,
            readable: None,
            extra_writable: &[],
            allow_clipboard: false,
            allow_open: false,
        });
        let path = |dir: &Path, name: &str| dir.join(name).to_string_lossy().into_owned();

        assert!(
            allowed(&profile, &format!("echo ok > '{}'", path(&work, "file"))),
            "the terminal's folder is writable"
        );
        assert!(
            allowed(&profile, &format!("echo ok > '{}'", path(&extra, "file"))),
            "listed folders are writable"
        );
        assert!(
            allowed(
                &profile,
                "echo ok > /tmp/gpu-term-sbx-tmp && rm /tmp/gpu-term-sbx-tmp"
            ),
            "temporary files work"
        );
        // A writable file, with the lock and temporary files written next to it (zsh history).
        assert!(
            allowed(&profile, &format!("echo ok > '{}'", history.display())),
            "listed files are writable"
        );
        assert!(
            allowed(&profile, &format!("echo ok > '{}.LOCK'", history.display())),
            "and their lock files"
        );
        assert!(
            allowed(&profile, &format!("echo ok > '{}.new'", history.display())),
            "and their temporary files"
        );
        assert!(
            !allowed(&profile, &format!("echo no > '{}'", path(&root, "other"))),
            "but not other files beside them"
        );
        assert!(
            !allowed(&profile, &format!("echo no > '{}'", path(&outside, "file"))),
            "other folders are read-only"
        );
        assert!(
            !allowed(&profile, &format!("cat '{}'", path(&secret, "key"))),
            "hidden paths cannot be read"
        );
        assert!(
            !allowed(&profile, "curl --version"),
            "blocked programs cannot run"
        );
        assert!(
            allowed(&profile, "cat /etc/hosts"),
            "everything else stays readable"
        );
        assert!(
            !allowed(&profile, "/usr/bin/nc -z -G 2 1.1.1.1 443"),
            "the network can be cut"
        );
        // Local sockets: /tmp (where local databases listen) is fine, anywhere else is not.
        let socket = |path: &Path| {
            format!(
                "/usr/bin/python3 -c 'import socket; socket.socket(socket.AF_UNIX).connect(\"{}\")'",
                path.display()
            )
        };
        let listeners: Vec<std::os::unix::net::UnixListener> = [
            outside.join("agent.sock"),
            PathBuf::from("/private/tmp/gpu-term-sbx-test.sock"),
        ]
        .iter()
        .map(|path| {
            let _ = fs::remove_file(path);
            std::os::unix::net::UnixListener::bind(path).unwrap()
        })
        .collect();
        assert!(
            allowed(
                &profile,
                &socket(Path::new("/private/tmp/gpu-term-sbx-test.sock"))
            ),
            "sockets in /tmp"
        );
        assert!(
            !allowed(&profile, &socket(&outside.join("agent.sock"))),
            "not sockets elsewhere"
        );
        drop(listeners);
        let _ = fs::remove_file("/private/tmp/gpu-term-sbx-test.sock");
        assert!(!allowed(&profile, "pbpaste"), "no clipboard");
        // Works outside the sandbox, refused inside: the Keychain service is out of reach.
        assert!(allowed(
            "(version 1)(allow default)",
            "security list-keychains"
        ));
        assert!(!allowed(&profile, "security list-keychains"), "no Keychain");
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn finds_what_the_shell_setup_reads() {
        let home = std::env::current_dir()
            .unwrap()
            .join("target")
            .join(format!("sbx-home-{}", std::process::id()));
        for dir in [
            ".config/tool",
            ".local/share/tool/bin",
            ".local/state/tool",
            ".bun/bin",
            ".local/bin",
            ".orbstack/shell",
        ] {
            fs::create_dir_all(home.join(dir)).unwrap();
        }
        let h = home.display();
        fs::write(
            home.join(".zshenv"),
            format!(". \"{h}/.config/tool/env\"\n# source ~/.ignored\n"),
        )
        .unwrap();
        fs::write(
            home.join(".config/tool/env"),
            "export PATH=\"$HOME/.local/share/tool/bin:$PATH\"\n",
        )
        .unwrap();
        fs::write(
            home.join(".zprofile"),
            "export PATH=\"$HOME/.bun/bin:$PATH\"\nexport PATH=\"~/.local/bin:$PATH\"\nsource ~/.orbstack/shell/init.zsh 2>/dev/null || :\n",
        )
        .unwrap();
        fs::write(home.join(".orbstack/shell/init.zsh"), "").unwrap();

        let found = shell_setup_paths(&home, Some(&format!("/usr/bin:{h}/.cargo/bin")));
        let has = |path: &str| found.contains(&home.join(path));
        assert!(has(".config/tool/env"), "a sourced file: {found:?}");
        assert!(has(".config/tool"), "and its tool's folder");
        assert!(
            has(".local/share/tool"),
            "a toolchain the sourced file puts on PATH"
        );
        assert!(has(".bun"), "a toolchain on PATH, as its folder");
        assert!(has(".local/bin"), "~/.local/bin stays itself");
        assert!(!has(".local"), "not all of ~/.local");
        assert!(has(".orbstack/shell/init.zsh"), "`source ~/…`");
        assert!(has(".cargo"), "from the PATH the app runs with");
        assert!(has(".local/state/tool"), "a tool's other standard folders");
        assert!(!has(".ignored"), "comments are skipped");
        assert!(!found.contains(&home) && found.iter().all(|path| path.starts_with(&home)));
        fs::remove_dir_all(&home).unwrap();
    }

    /// Prints the default Project profile for `SANDBOX_ROOT`, to try it by hand:
    /// `SANDBOX_ROOT=$PWD cargo test print_default_profile -- --ignored --nocapture`.
    #[test]
    #[ignore]
    fn print_default_profile() {
        let root = PathBuf::from(std::env::var("SANDBOX_ROOT").unwrap_or_else(|_| ".".into()));
        let profile = SandboxProfile {
            id: 0,
            name: "Project".into(),
            engine: crate::profiles::SandboxEngine::seatbelt_defaults(),
        };
        println!(
            "{}",
            wrap(&profile, 0, &root, &root, "/bin/zsh", &[], &[]).args[1]
        );
    }

    #[test]
    fn the_apps_own_records_are_always_hidden() {
        // Even a profile that hides nothing.
        let profile = SandboxProfile {
            id: 0,
            name: "Bare".into(),
            engine: crate::profiles::SandboxEngine::Seatbelt {
                writable: Vec::new(),
                hidden: Vec::new(),
                network: Network::All,
                blocked: Vec::new(),
                block_keychain: false,
                confine_reads: false,
                readable: Vec::new(),
                allow_clipboard: false,
                allow_open: false,
            },
        };
        let root = PathBuf::from("/work/app");
        let text = &wrap(&profile, 0, &root, &root, "/bin/zsh", &[], &[]).args[1];
        let app = crate::settings::config_dir();
        for name in APP_PRIVATE {
            let path = resolve(&app.join(name)).to_string_lossy().into_owned();
            assert!(
                text.contains(&format!("(subpath \"{path}\")")),
                "{name} not hidden"
            );
        }
    }

    #[test]
    fn docker_sees_only_the_folder_and_chosen_mounts() {
        let args = docker_args(
            7,
            Path::new("/work/app"),
            Path::new("apps/api"),
            "node:22",
            false,
            &["~/data:/data:ro".into()],
            &["ANTHROPIC_API_KEY".into()],
        );
        let line = args.join(" ");
        assert!(
            line.starts_with("run --rm -it --init --name gpu-terminal-7"),
            "{line}"
        );
        assert!(
            line.contains("-v /work/app:/workspace -w /workspace/apps/api --network none"),
            "{line}"
        );
        assert!(
            line.contains(":/data:ro") && !line.contains("~/data"),
            "{line}"
        );
        assert!(
            line.contains("-e ANTHROPIC_API_KEY node:22 /bin/sh -c"),
            "{line}"
        );
    }
}
