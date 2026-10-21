//! Tab completions: fuzzy-matched commands, subcommands, git branches, package scripts, make
//! targets, files and directories, and arguments learned from history.

use std::{
    collections::{HashMap, HashSet},
    fs,
    path::{Path, PathBuf},
};

use crate::{fuzzy, history::History, icons::IconName};

const MAX_CANDIDATES: usize = 50;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Kind {
    Command,
    Subcommand,
    Branch,
    Script,
    Directory,
    File,
    Argument,
}

impl Kind {
    pub fn icon(self) -> IconName {
        match self {
            Self::Command => IconName::Terminal,
            Self::Subcommand => IconName::ChevronRight,
            Self::Branch => IconName::GitBranch,
            Self::Script => IconName::Play,
            Self::Directory => IconName::Folder,
            Self::File => IconName::File,
            Self::Argument => IconName::Ellipsis,
        }
    }

    /// Tie-breaker between kinds with equal match scores.
    fn priority(self) -> i64 {
        match self {
            Self::Subcommand | Self::Script | Self::Branch => 30,
            Self::Directory => 20,
            Self::File => 15,
            Self::Argument => 10,
            Self::Command => 5,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Candidate {
    /// Text that replaces the word being completed (already shell-escaped).
    pub replacement: String,
    /// Text shown in the menu.
    pub display: String,
    pub description: Option<String>,
    pub kind: Kind,
    /// Matched char positions in `display`.
    pub positions: Vec<usize>,
}

impl Candidate {
    /// What to type after the replacement: directories keep completing, everything else ends
    /// the word.
    pub fn suffix(&self) -> &'static str {
        if self.kind == Kind::Directory {
            ""
        } else {
            " "
        }
    }
}

/// The result of completing the word before the cursor.
#[derive(Clone, Debug, Default)]
pub struct Completions {
    /// The partial word being replaced, as typed.
    pub word: String,
    pub candidates: Vec<Candidate>,
}

/// Everything the completer reads.
pub struct Context<'a> {
    /// The command line up to the cursor.
    pub line: &'a str,
    pub cwd: &'a Path,
    pub executables: &'a [String],
    pub history: &'a History,
}

pub fn complete(context: &Context<'_>) -> Completions {
    let (words, word) = split_words(context.line);
    let mut raw = Vec::new();

    let command_index = words
        .iter()
        .position(|word| !PREFIX_COMMANDS.contains(&word.as_str()))
        .unwrap_or(words.len());
    let args = &words[command_index.min(words.len())..];

    if args.is_empty() {
        if is_path_like(&word) {
            raw.extend(paths(context.cwd, &word, false));
        } else {
            raw.extend(commands(context));
        }
    } else {
        let command = args[0].as_str();
        let position = args.len();
        if is_path_like(&word) {
            raw.extend(paths(
                context.cwd,
                &word,
                command == "cd" || command == "pushd",
            ));
        } else {
            match (command, args.get(1).map(String::as_str)) {
                ("cd" | "pushd" | "rmdir", _) => raw.extend(paths(context.cwd, &word, true)),
                ("git", None) => raw.extend(spec(GIT)),
                (
                    "git",
                    Some(
                        "checkout" | "switch" | "merge" | "rebase" | "branch" | "cherry-pick"
                        | "log" | "diff",
                    ),
                ) if position == 2 => {
                    raw.extend(git_branches(context.cwd));
                    if matches!(args[1].as_str(), "checkout" | "diff" | "log") {
                        raw.extend(paths(context.cwd, &word, false));
                    }
                }
                ("git", Some("push" | "pull" | "fetch")) if position == 2 => {
                    raw.extend(git_remotes(context.cwd))
                }
                ("git", Some("push" | "pull")) if position == 3 => {
                    raw.extend(git_branches(context.cwd))
                }
                ("cargo", None) => raw.extend(spec(CARGO)),
                ("npm" | "pnpm" | "yarn" | "bun", None) => {
                    raw.extend(spec(NPM));
                    if command != "npm" {
                        raw.extend(package_scripts(context.cwd));
                    }
                }
                ("npm" | "pnpm" | "yarn" | "bun", Some("run" | "run-script")) if position == 2 => {
                    raw.extend(package_scripts(context.cwd));
                }
                ("docker", None) => raw.extend(spec(DOCKER)),
                ("brew", None) => raw.extend(spec(BREW)),
                ("make", _) => raw.extend(make_targets(context.cwd)),
                _ => {}
            }
            if raw.is_empty() || word.starts_with('-') {
                raw.extend(history_arguments(context.history, args, &word));
            }
            if raw.is_empty() {
                raw.extend(paths(context.cwd, &word, false));
            }
        }
    }

    Completions {
        candidates: rank(raw, &word),
        word,
    }
}

/// Whether a command from history still makes sense in `cwd`, so it may be suggested there: a
/// `cd` must lead to a folder that exists, and arguments written as explicit paths (`./x`, `../x`,
/// `~/x`, `/x`) must exist. Arguments with variables or globs are not checked.
pub fn valid_in(command: &str, cwd: &Path) -> bool {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_default();
    let resolve = |arg: &str| match arg.strip_prefix('~') {
        Some(rest) => home.join(rest.trim_start_matches('/')),
        None => cwd.join(arg),
    };
    let checkable = |arg: &&String| !arg.contains(['$', '*', '?', '`']);
    segments(command).iter().all(|words| {
        let Some(index) = words
            .iter()
            .position(|word| !PREFIX_COMMANDS.contains(&word.as_str()))
        else {
            return true;
        };
        let (command, args) = (words[index].as_str(), &words[index + 1..]);
        match command {
            "cd" | "pushd" => args
                .iter()
                .find(|arg| !arg.starts_with('-'))
                .filter(checkable)
                .is_none_or(|dir| resolve(dir).is_dir()),
            _ => args
                .iter()
                .filter(checkable)
                .filter(|arg| {
                    ["./", "../", "~/", "/"]
                        .iter()
                        .any(|prefix| arg.starts_with(prefix))
                })
                .all(|path| resolve(path).exists()),
        }
    })
}

/// Whether the menu should open as soon as a space follows `line`: right after a command whose
/// next word comes from a known list (folders for `cd`, subcommands, branches, scripts, targets).
pub fn opens_after_space(line: &str) -> bool {
    let (words, word) = split_words(line);
    let words: Vec<&str> = words
        .iter()
        .map(String::as_str)
        .skip_while(|word| PREFIX_COMMANDS.contains(word))
        .collect();
    word.is_empty()
        && match words.as_slice() {
            [command] => matches!(
                *command,
                "cd" | "pushd"
                    | "rmdir"
                    | "git"
                    | "cargo"
                    | "npm"
                    | "pnpm"
                    | "yarn"
                    | "bun"
                    | "docker"
                    | "brew"
                    | "make"
            ),
            [
                "git",
                "checkout" | "switch" | "merge" | "rebase" | "cherry-pick" | "push" | "pull"
                | "fetch",
            ]
            | ["npm" | "pnpm" | "yarn" | "bun", "run" | "run-script"] => true,
            _ => false,
        }
}

/// Words that run the command after them.
const PREFIX_COMMANDS: &[&str] = &["sudo", "time", "nohup", "exec", "command", "builtin"];

/// The words of each command in a full command line, split at pipes and separators.
fn segments(line: &str) -> Vec<Vec<String>> {
    let mut out = Vec::new();
    let (mut start, mut quote, mut escaped) = (0, None, false);
    for (index, ch) in line.char_indices() {
        if escaped {
            escaped = false;
            continue;
        }
        match (quote, ch) {
            (_, '\\') if quote != Some('\'') => escaped = true,
            (Some(open), ch) if ch == open => quote = None,
            (Some(_), _) => {}
            (None, '\'' | '"') => quote = Some(ch),
            (None, '|' | ';' | '&' | '(' | ')') => {
                out.push(&line[start..index]);
                start = index + ch.len_utf8();
            }
            _ => {}
        }
    }
    out.push(&line[start..]);
    out.into_iter()
        .map(|segment| {
            let (mut words, last) = split_words(segment);
            if !last.is_empty() {
                words.push(unescape(&last));
            }
            words
        })
        .filter(|words| !words.is_empty())
        .collect()
}

/// Split a command line into finished words of the current pipeline segment and the partial
/// word at the end (empty after a space). Quotes and backslash escapes are understood.
fn split_words(line: &str) -> (Vec<String>, String) {
    let mut words = Vec::new();
    let mut current = String::new();
    let mut quote = None;
    let mut escaped = false;
    for ch in line.chars() {
        if escaped {
            current.push(ch);
            escaped = false;
            continue;
        }
        match (quote, ch) {
            (_, '\\') if quote != Some('\'') => {
                escaped = true;
                current.push(ch);
            }
            (Some(open), ch) if ch == open => {
                quote = None;
                current.push(ch);
            }
            (Some(_), ch) => current.push(ch),
            (None, '\'' | '"') => {
                quote = Some(ch);
                current.push(ch);
            }
            (None, ' ' | '\t') => {
                if !current.is_empty() {
                    words.push(std::mem::take(&mut current));
                }
            }
            (None, '|' | ';' | '&' | '(' | ')') => {
                // A new command starts after a pipe or separator.
                words.clear();
                current.clear();
            }
            (None, ch) => current.push(ch),
        }
    }
    let words = words.into_iter().map(|word| unescape(&word)).collect();
    (words, current)
}

fn unescape(word: &str) -> String {
    let mut out = String::with_capacity(word.len());
    let mut chars = word.chars();
    while let Some(ch) = chars.next() {
        match ch {
            '\\' => out.extend(chars.next()),
            '\'' | '"' => {}
            ch => out.push(ch),
        }
    }
    out
}

/// Escape a file name for the shell.
fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for ch in text.chars() {
        if matches!(
            ch,
            ' ' | '\t'
                | '\''
                | '"'
                | '\\'
                | '$'
                | '`'
                | '!'
                | '&'
                | ';'
                | '|'
                | '('
                | ')'
                | '<'
                | '>'
                | '*'
                | '?'
                | '['
                | ']'
                | '#'
                | '{'
                | '}'
        ) {
            out.push('\\');
        }
        out.push(ch);
    }
    out
}

fn is_path_like(word: &str) -> bool {
    word.contains('/') || word.starts_with('.') || word.starts_with('~')
}

fn candidate(kind: Kind, text: &str, description: Option<&str>) -> Candidate {
    Candidate {
        replacement: escape(text),
        display: text.to_owned(),
        description: description.map(str::to_owned),
        kind,
        positions: Vec::new(),
    }
}

/// Fuzzy-filter by the partial word, then order by score, kind and name.
fn rank(candidates: Vec<Candidate>, word: &str) -> Vec<Candidate> {
    let query = unescape(word);
    // For paths, match only the last component.
    let query = query.rsplit('/').next().unwrap_or_default().to_owned();
    let mut seen = HashSet::new();
    let mut scored: Vec<(i64, Candidate)> = candidates
        .into_iter()
        .filter(|candidate| seen.insert((candidate.kind, candidate.display.clone())))
        .filter_map(|mut candidate| {
            let name_start = if candidate.kind == Kind::Directory || candidate.kind == Kind::File {
                candidate
                    .display
                    .trim_end_matches('/')
                    .rfind('/')
                    .map_or(0, |index| index + 1)
            } else {
                0
            };
            let name: String = candidate.display.chars().skip(name_start).collect();
            let found = fuzzy::fuzzy_match(&query, &name)?;
            candidate.positions = found
                .positions
                .iter()
                .map(|position| position + name_start)
                .collect();
            Some((found.score * 10 + candidate.kind.priority(), candidate))
        })
        .collect();
    scored.sort_by(|a, b| {
        b.0.cmp(&a.0)
            .then_with(|| a.1.display.len().cmp(&b.1.display.len()))
            .then_with(|| a.1.display.cmp(&b.1.display))
    });
    scored
        .into_iter()
        .take(MAX_CANDIDATES)
        .map(|(_, candidate)| candidate)
        .collect()
}

fn commands(context: &Context<'_>) -> Vec<Candidate> {
    let mut frequency: HashMap<&str, usize> = HashMap::new();
    for entry in context.history.entries().iter().rev().take(5000) {
        if let Some(first) = entry.command.split_whitespace().next() {
            *frequency.entry(first).or_default() += 1;
        }
    }
    let mut out: Vec<Candidate> = BUILTINS
        .iter()
        .map(|(name, description)| candidate(Kind::Command, name, Some(description)))
        .collect();
    let mut used: Vec<(&str, usize)> = frequency.into_iter().collect();
    used.sort_by_key(|(_, count)| std::cmp::Reverse(*count));
    out.extend(
        used.into_iter()
            .take(200)
            .map(|(name, count)| candidate(Kind::Command, name, Some(&used_label(count)))),
    );
    out.extend(
        context
            .executables
            .iter()
            .map(|name| candidate(Kind::Command, name, None)),
    );
    out
}

/// Executable names on `PATH` (deduplicated, sorted).
pub fn executables(path: &str) -> Vec<String> {
    let mut names = HashSet::new();
    for dir in std::env::split_paths(path) {
        let Ok(entries) = fs::read_dir(dir) else {
            continue;
        };
        for entry in entries.flatten() {
            if let Some(name) = entry.file_name().to_str()
                && !name.starts_with('.')
            {
                names.insert(name.to_owned());
            }
        }
    }
    let mut names: Vec<String> = names.into_iter().collect();
    names.sort();
    names
}

fn paths(cwd: &Path, word: &str, directories_only: bool) -> Vec<Candidate> {
    let typed = unescape(word);
    let (dir_part, name_part) = match typed.rfind('/') {
        Some(index) => typed.split_at(index + 1),
        None => ("", typed.as_str()),
    };
    let base = if let Some(rest) = dir_part.strip_prefix('~') {
        std::env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_default()
            .join(rest.trim_start_matches('/'))
    } else if dir_part.starts_with('/') {
        PathBuf::from(dir_part)
    } else {
        cwd.join(dir_part)
    };
    let Ok(entries) = fs::read_dir(&base) else {
        return Vec::new();
    };
    let show_hidden = name_part.starts_with('.');
    let mut out = Vec::new();
    for entry in entries.flatten().take(2000) {
        let Some(name) = entry.file_name().to_str().map(str::to_owned) else {
            continue;
        };
        if name.starts_with('.') && !show_hidden {
            continue;
        }
        let is_dir = entry.path().is_dir();
        if directories_only && !is_dir {
            continue;
        }
        let display = format!("{dir_part}{name}{}", if is_dir { "/" } else { "" });
        out.push(Candidate {
            // Keep `~` unescaped so the shell still expands it.
            replacement: match display.strip_prefix('~') {
                Some(rest) => format!("~{}", escape(rest)),
                None => escape(&display),
            },
            display,
            description: None,
            kind: if is_dir { Kind::Directory } else { Kind::File },
            positions: Vec::new(),
        });
    }
    out
}

/// Arguments that followed the same words in past commands (e.g. flags, hostnames).
fn history_arguments(history: &History, args: &[String], word: &str) -> Vec<Candidate> {
    let mut counts: HashMap<String, usize> = HashMap::new();
    for index in history.recent_unique().take(5000) {
        let (words, last) = split_words(&history.entries()[index].command);
        let mut words = words;
        if !last.is_empty() {
            words.push(unescape(&last));
        }
        if words.len() > args.len() && words[..args.len()] == *args {
            let next = &words[args.len()];
            if word.starts_with('-') == next.starts_with('-') {
                *counts.entry(next.clone()).or_default() += 1;
            }
        }
    }
    counts
        .into_iter()
        .map(|(arg, count)| candidate(Kind::Argument, &arg, Some(&used_label(count))))
        .collect()
}

fn used_label(count: usize) -> String {
    if count == 1 {
        "used once".to_owned()
    } else {
        format!("used {count} times")
    }
}

fn git_dir(cwd: &Path) -> Option<PathBuf> {
    cwd.ancestors().find_map(|dir| {
        let git = dir.join(".git");
        if git.is_dir() {
            Some(git)
        } else if git.is_file() {
            let text = fs::read_to_string(&git).ok()?;
            let target = PathBuf::from(text.trim().strip_prefix("gitdir: ")?);
            Some(if target.is_absolute() {
                target
            } else {
                dir.join(target)
            })
        } else {
            None
        }
    })
}

fn git_branches(cwd: &Path) -> Vec<Candidate> {
    let Some(git) = git_dir(cwd) else {
        return Vec::new();
    };
    // Worktrees keep refs in the common directory.
    let common = fs::read_to_string(git.join("commondir"))
        .ok()
        .map(|dir| git.join(dir.trim()))
        .unwrap_or_else(|| git.clone());
    let mut branches = HashSet::new();
    collect_refs(&common.join("refs/heads"), "", &mut branches);
    if let Ok(packed) = fs::read_to_string(common.join("packed-refs")) {
        for line in packed.lines() {
            if let Some(name) = line
                .split_whitespace()
                .nth(1)
                .and_then(|name| name.strip_prefix("refs/heads/"))
            {
                branches.insert(name.to_owned());
            }
        }
    }
    branches
        .into_iter()
        .map(|name| candidate(Kind::Branch, &name, Some("branch")))
        .collect()
}

fn collect_refs(dir: &Path, prefix: &str, out: &mut HashSet<String>) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let Some(name) = entry.file_name().to_str().map(str::to_owned) else {
            continue;
        };
        let full = format!("{prefix}{name}");
        if entry.path().is_dir() {
            collect_refs(&entry.path(), &format!("{full}/"), out);
        } else {
            out.insert(full);
        }
    }
}

fn git_remotes(cwd: &Path) -> Vec<Candidate> {
    let Some(config) = git_dir(cwd).and_then(|git| fs::read_to_string(git.join("config")).ok())
    else {
        return Vec::new();
    };
    config
        .lines()
        .filter_map(|line| {
            line.trim()
                .strip_prefix("[remote \"")?
                .strip_suffix("\"]")
                .map(str::to_owned)
        })
        .map(|remote| candidate(Kind::Argument, &remote, Some("remote")))
        .collect()
}

fn package_scripts(cwd: &Path) -> Vec<Candidate> {
    let Some(package) = cwd
        .ancestors()
        .map(|dir| dir.join("package.json"))
        .find(|path| path.is_file())
    else {
        return Vec::new();
    };
    let Ok(json) =
        fs::read_to_string(package).map(|text| serde_json::from_str::<serde_json::Value>(&text))
    else {
        return Vec::new();
    };
    let Some(scripts) = json.ok().and_then(|json| {
        json.get("scripts")
            .and_then(|value| value.as_object())
            .cloned()
    }) else {
        return Vec::new();
    };
    scripts
        .iter()
        .map(|(name, command)| candidate(Kind::Script, name, command.as_str()))
        .collect()
}

fn make_targets(cwd: &Path) -> Vec<Candidate> {
    let Some(text) = ["Makefile", "makefile", "GNUmakefile"]
        .iter()
        .find_map(|name| fs::read_to_string(cwd.join(name)).ok())
    else {
        return Vec::new();
    };
    text.lines()
        .filter_map(|line| {
            let (target, rest) = line.split_once(':')?;
            let valid = !target.is_empty()
                && !rest.starts_with('=')
                && target
                    .chars()
                    .all(|ch| ch.is_alphanumeric() || matches!(ch, '_' | '-' | '.' | '/'))
                && !target.starts_with('.');
            valid.then(|| candidate(Kind::Script, target, Some("make target")))
        })
        .collect()
}

fn spec(entries: &[(&str, &str)]) -> Vec<Candidate> {
    entries
        .iter()
        .map(|(name, description)| candidate(Kind::Subcommand, name, Some(description)))
        .collect()
}

const BUILTINS: &[(&str, &str)] = &[
    ("cd", "Change directory"),
    ("ls", "List directory contents"),
    ("echo", "Print text"),
    ("export", "Set an environment variable"),
    ("source", "Run a script in this shell"),
    ("alias", "Define a command alias"),
    ("history", "Show command history"),
    ("exit", "Exit the shell"),
    ("clear", "Clear the screen"),
    ("pwd", "Print the working directory"),
];

const GIT: &[(&str, &str)] = &[
    ("status", "Show the working tree status"),
    ("add", "Add file contents to the index"),
    ("commit", "Record changes to the repository"),
    ("push", "Update remote refs"),
    ("pull", "Fetch and integrate remote changes"),
    ("fetch", "Download objects and refs"),
    ("checkout", "Switch branches or restore files"),
    ("switch", "Switch branches"),
    ("branch", "List, create or delete branches"),
    ("merge", "Join two histories together"),
    ("rebase", "Reapply commits on top of another base"),
    ("log", "Show commit logs"),
    ("diff", "Show changes"),
    ("stash", "Stash away changes"),
    ("restore", "Restore working tree files"),
    ("reset", "Reset HEAD to a state"),
    ("clone", "Clone a repository"),
    ("init", "Create an empty repository"),
    ("remote", "Manage remotes"),
    ("tag", "Create, list or delete tags"),
    ("show", "Show objects"),
    ("cherry-pick", "Apply changes from commits"),
    ("revert", "Revert commits"),
    ("blame", "Show who changed each line"),
];

const CARGO: &[(&str, &str)] = &[
    ("build", "Compile the package"),
    ("run", "Build and run a binary"),
    ("test", "Run tests"),
    ("check", "Check for errors without building"),
    ("clippy", "Run lints"),
    ("fmt", "Format the code"),
    ("add", "Add a dependency"),
    ("remove", "Remove a dependency"),
    ("new", "Create a new package"),
    ("init", "Create a package in this directory"),
    ("update", "Update dependencies"),
    ("doc", "Build documentation"),
    ("bench", "Run benchmarks"),
    ("install", "Install a binary"),
    ("clean", "Remove build artifacts"),
    ("publish", "Publish to crates.io"),
];

const NPM: &[(&str, &str)] = &[
    ("install", "Install dependencies"),
    ("run", "Run a package script"),
    ("test", "Run tests"),
    ("start", "Run the start script"),
    ("build", "Run the build script"),
    ("add", "Add a dependency"),
    ("remove", "Remove a dependency"),
    ("update", "Update dependencies"),
    ("init", "Create a package.json"),
    ("publish", "Publish the package"),
    ("outdated", "Check for outdated packages"),
    ("audit", "Audit dependencies"),
];

const DOCKER: &[(&str, &str)] = &[
    ("ps", "List containers"),
    ("run", "Run a container"),
    ("build", "Build an image"),
    ("exec", "Run a command in a container"),
    ("images", "List images"),
    ("pull", "Download an image"),
    ("push", "Upload an image"),
    ("logs", "Show container logs"),
    ("stop", "Stop containers"),
    ("start", "Start containers"),
    ("rm", "Remove containers"),
    ("rmi", "Remove images"),
    ("compose", "Multi-container apps"),
];

const BREW: &[(&str, &str)] = &[
    ("install", "Install a formula or cask"),
    ("uninstall", "Uninstall a formula or cask"),
    ("upgrade", "Upgrade outdated packages"),
    ("update", "Update Homebrew"),
    ("search", "Search for packages"),
    ("info", "Show package information"),
    ("list", "List installed packages"),
    ("outdated", "List outdated packages"),
    ("services", "Manage background services"),
    ("cleanup", "Remove old versions"),
    ("doctor", "Check for problems"),
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn history_commands_must_fit_the_current_folder() {
        let dir = std::env::temp_dir().join(format!("gpu-terminal-valid-{}", std::process::id()));
        fs::create_dir_all(dir.join("src")).unwrap();
        fs::write(dir.join("notes.txt"), "").unwrap();
        assert!(valid_in("cd src", &dir));
        assert!(valid_in("cd", &dir));
        assert!(valid_in("cd -", &dir));
        assert!(valid_in("cd $HOME", &dir));
        assert!(!valid_in("cd missing", &dir));
        assert!(!valid_in("git pull && cd missing", &dir));
        assert!(valid_in("cat ./notes.txt | wc -l", &dir));
        assert!(!valid_in("cat ./gone.txt", &dir));
        // Plain words are not taken for paths.
        assert!(valid_in("git push origin feature/x", &dir));
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn menu_opens_after_space_only_where_the_next_word_is_known() {
        assert!(opens_after_space("cd "));
        assert!(opens_after_space("sudo make "));
        assert!(opens_after_space("git checkout "));
        assert!(!opens_after_space("cd"));
        assert!(!opens_after_space("cd src "));
        assert!(!opens_after_space("echo "));
    }

    fn complete_line(line: &str, cwd: &Path) -> Completions {
        let history = History::default();
        complete(&Context {
            line,
            cwd,
            executables: &["cargo".into(), "cat".into(), "git".into()],
            history: &history,
        })
    }

    fn displays(completions: &Completions) -> Vec<&str> {
        completions
            .candidates
            .iter()
            .map(|candidate| candidate.display.as_str())
            .collect()
    }

    #[test]
    fn splits_words_with_quotes_and_pipes() {
        assert_eq!(
            split_words("git commit -m \"a b\" "),
            (
                vec!["git".into(), "commit".into(), "-m".into(), "a b".into()],
                String::new()
            )
        );
        assert_eq!(split_words("ls | gr"), (vec![], "gr".into()));
        assert_eq!(
            split_words("cd my\\ fo"),
            (vec!["cd".into()], "my\\ fo".into())
        );
    }

    #[test]
    fn completes_commands_and_subcommands() {
        let cwd = std::env::temp_dir();
        let completions = complete_line("ca", &cwd);
        assert!(displays(&completions).contains(&"cargo"));
        assert_eq!(completions.word, "ca");
        let completions = complete_line("git chk", &cwd);
        assert_eq!(displays(&completions)[0], "checkout");
        let completions = complete_line("sudo git st", &cwd);
        assert!(displays(&completions).contains(&"status"));
    }

    #[test]
    fn completes_paths_with_escaping() {
        let dir =
            std::env::temp_dir().join(format!("gpu-terminal-complete-{}", std::process::id()));
        fs::create_dir_all(dir.join("my folder")).unwrap();
        fs::write(dir.join("notes.txt"), "").unwrap();
        let completions = complete_line("cd my", &dir);
        assert_eq!(displays(&completions), vec!["my folder/"]);
        assert_eq!(completions.candidates[0].replacement, "my\\ folder/");
        assert_eq!(completions.candidates[0].suffix(), "");
        let completions = complete_line("cat no", &dir);
        assert_eq!(displays(&completions), vec!["notes.txt"]);
        assert_eq!(completions.candidates[0].suffix(), " ");
        let completions = complete_line("cat ./", &dir);
        assert!(displays(&completions).contains(&"./notes.txt"));
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn completes_git_branches_and_package_scripts() {
        let dir = std::env::temp_dir().join(format!("gpu-terminal-git-{}", std::process::id()));
        fs::create_dir_all(dir.join(".git/refs/heads/feature")).unwrap();
        fs::write(dir.join(".git/refs/heads/main"), "").unwrap();
        fs::write(dir.join(".git/refs/heads/feature/login"), "").unwrap();
        fs::write(
            dir.join("package.json"),
            r#"{"scripts": {"dev": "vite", "build": "vite build"}}"#,
        )
        .unwrap();
        let completions = complete_line("git checkout fe", &dir);
        assert_eq!(displays(&completions)[0], "feature/login");
        let completions = complete_line("npm run d", &dir);
        assert_eq!(displays(&completions)[0], "dev");
        assert_eq!(
            completions.candidates[0].description.as_deref(),
            Some("vite")
        );
        fs::remove_dir_all(dir).unwrap();
    }
}
