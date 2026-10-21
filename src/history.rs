//! Command history: every command run in this terminal (with directory, exit status, time and
//! duration), plus the commands already in the shell's own history file.
//!
//! Stored as JSON lines in `~/.config/bridge/history.jsonl`.

use std::{
    collections::{HashMap, HashSet},
    fs::{self, OpenOptions},
    io::{self, Write as _},
    path::PathBuf,
    time::{SystemTime, UNIX_EPOCH},
};

use gpui::Global;
use serde::{Deserialize, Serialize};

use crate::{fuzzy, settings::TerminalSettings};

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct HistoryEntry {
    pub command: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<i32>,
    /// Unix seconds.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub started_at: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<u64>,
    /// Imported from the shell's history file rather than recorded here.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub imported: bool,
}

/// A search hit: the newest entry for a distinct command and the matched char positions.
#[derive(Clone, Debug)]
pub struct HistoryMatch {
    pub index: usize,
    pub positions: Vec<usize>,
}

#[derive(Debug, Default)]
pub struct History {
    /// Oldest first.
    entries: Vec<HistoryEntry>,
    file: Option<PathBuf>,
}

impl Global for History {}

impl History {
    /// Load recorded history, optionally preceded by the shell's own history files.
    pub fn load(import_shell_history: bool) -> Self {
        let file = TerminalSettings::path()
            .parent()
            .map(|dir| dir.join("history.jsonl"));
        let mut entries = Vec::new();
        if import_shell_history {
            let home = std::env::var_os("HOME")
                .map(PathBuf::from)
                .unwrap_or_default();
            if let Ok(bytes) = fs::read(home.join(".zsh_history")) {
                entries.extend(parse_zsh_history(&bytes));
            }
            if let Ok(text) = fs::read_to_string(home.join(".bash_history")) {
                entries.extend(parse_bash_history(&text));
            }
            entries.sort_by_key(|entry: &HistoryEntry| entry.started_at.unwrap_or(0));
        }
        if let Some(text) = file.as_ref().and_then(|file| fs::read_to_string(file).ok()) {
            entries.extend(
                text.lines()
                    .filter_map(|line| serde_json::from_str::<HistoryEntry>(line).ok()),
            );
        }
        Self { entries, file }
    }

    pub fn entries(&self) -> &[HistoryEntry] {
        &self.entries
    }

    /// Append a command and persist it.
    pub fn record(&mut self, entry: HistoryEntry) {
        if entry.command.trim().is_empty() {
            return;
        }
        if let Some(file) = &self.file
            && let Err(err) = append_line(file, &entry)
        {
            eprintln!("failed to save history to {}: {err}", file.display());
        }
        self.entries.push(entry);
    }

    /// Distinct commands, newest first, as indices into [`Self::entries`].
    pub fn recent_unique(&self) -> impl Iterator<Item = usize> + '_ {
        let mut seen = HashSet::new();
        (0..self.entries.len())
            .rev()
            .filter(move |&index| seen.insert(self.entries[index].command.as_str()))
    }

    /// The newest single-line command that extends `prefix` (fish/zsh-autosuggestions style).
    /// The command to suggest for a typed prefix, the way fish picks one: the newest match run
    /// in `cwd`, else the newest match from anywhere, skipping commands `valid` rejects (such as a
    /// `cd` into a folder that does not exist here).
    pub fn suggest(
        &self,
        prefix: &str,
        cwd: Option<&str>,
        valid: impl Fn(&str) -> bool,
    ) -> Option<&str> {
        /// Distinct matches checked per keystroke; each check may touch the file system.
        const MAX_CHECKED: usize = 64;
        if prefix.trim().is_empty() {
            return None;
        }
        let mut checked: HashMap<&str, bool> = HashMap::new();
        let mut anywhere = None;
        for entry in self.entries.iter().rev() {
            let command = entry.command.as_str();
            if command.len() <= prefix.len()
                || !command.starts_with(prefix)
                || command.contains('\n')
            {
                continue;
            }
            if !checked.contains_key(command) && checked.len() >= MAX_CHECKED {
                break;
            }
            if !*checked.entry(command).or_insert_with(|| valid(command)) {
                continue;
            }
            if cwd.is_none() || entry.cwd.as_deref() == cwd {
                return Some(command);
            }
            anywhere.get_or_insert(command);
        }
        anywhere
    }

    /// Fuzzy search over distinct commands; an empty query lists them newest first.
    pub fn search(&self, query: &str, limit: usize) -> Vec<HistoryMatch> {
        let query = query.trim();
        let mut hits: Vec<(i64, usize, HistoryMatch)> = self
            .recent_unique()
            .enumerate()
            .filter_map(|(rank, index)| {
                let found = fuzzy::fuzzy_match(query, &self.entries[index].command)?;
                Some((
                    found.score,
                    rank,
                    HistoryMatch {
                        index,
                        positions: found.positions,
                    },
                ))
            })
            .collect();
        if !query.is_empty() {
            // Best score first; among equal scores the most recent wins.
            hits.sort_by(|a, b| b.0.cmp(&a.0).then(a.1.cmp(&b.1)));
        }
        hits.into_iter()
            .take(limit)
            .map(|(_, _, hit)| hit)
            .collect()
    }
}

pub fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |time| time.as_secs())
}

fn append_line(file: &PathBuf, entry: &HistoryEntry) -> io::Result<()> {
    if let Some(dir) = file.parent() {
        fs::create_dir_all(dir)?;
    }
    let mut line = serde_json::to_string(entry).map_err(io::Error::other)?;
    line.push('\n');
    OpenOptions::new()
        .create(true)
        .append(true)
        .open(file)?
        .write_all(line.as_bytes())
}

/// Parse `~/.zsh_history`, plain or `EXTENDED_HISTORY` (`: <start>:<elapsed>;<command>`), with
/// zsh's metafied bytes and backslash-continued multi-line commands.
fn parse_zsh_history(bytes: &[u8]) -> Vec<HistoryEntry> {
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut iter = bytes.iter();
    while let Some(&byte) = iter.next() {
        if byte == 0x83 {
            if let Some(&next) = iter.next() {
                decoded.push(next ^ 0x20);
            }
        } else {
            decoded.push(byte);
        }
    }
    let text = String::from_utf8_lossy(&decoded);

    let mut entries = Vec::new();
    let mut current: Option<HistoryEntry> = None;
    for line in text.lines() {
        if let Some(entry) = current.as_mut() {
            entry.command.push('\n');
            entry.command.push_str(line);
        } else {
            let mut entry = HistoryEntry {
                imported: true,
                ..HistoryEntry::default()
            };
            match line
                .strip_prefix(": ")
                .and_then(|rest| rest.split_once(';'))
            {
                Some((meta, command)) => {
                    let (start, elapsed) = meta.split_once(':').unwrap_or((meta, ""));
                    entry.started_at = start.trim().parse().ok();
                    entry.duration_ms = elapsed.trim().parse::<u64>().ok().map(|secs| secs * 1000);
                    entry.command = command.to_owned();
                }
                None => entry.command = line.to_owned(),
            }
            current = Some(entry);
        }
        let entry = current.as_mut().expect("set above");
        if entry.command.ends_with('\\') {
            entry.command.pop();
        } else if let Some(entry) = current.take()
            && !entry.command.trim().is_empty()
        {
            entries.push(entry);
        }
    }
    entries
}

/// Parse `~/.bash_history`, with optional `#<unix time>` lines.
fn parse_bash_history(text: &str) -> Vec<HistoryEntry> {
    let mut entries = Vec::new();
    let mut time = None;
    for line in text.lines() {
        if let Some(stamp) = line
            .strip_prefix('#')
            .and_then(|rest| rest.trim().parse::<u64>().ok())
        {
            time = Some(stamp);
            continue;
        }
        if !line.trim().is_empty() {
            entries.push(HistoryEntry {
                command: line.to_owned(),
                started_at: time.take(),
                imported: true,
                ..HistoryEntry::default()
            });
        }
    }
    entries
}

#[cfg(test)]
mod tests {
    use super::*;

    fn history(commands: &[&str]) -> History {
        History {
            entries: commands
                .iter()
                .map(|command| HistoryEntry {
                    command: (*command).to_owned(),
                    ..HistoryEntry::default()
                })
                .collect(),
            file: None,
        }
    }

    #[test]
    fn suggests_newest_matching_single_line_command() {
        let history = history(&[
            "git status",
            "git stash",
            "echo 'a\nb'",
            "git status --short",
        ]);
        let suggest = |prefix| history.suggest(prefix, None, |_| true);
        assert_eq!(suggest("git st"), Some("git status --short"));
        assert_eq!(suggest("git sta"), Some("git status --short"));
        assert_eq!(suggest("echo"), None);
        assert_eq!(suggest(""), None);
        assert_eq!(suggest("git status --short"), None);
    }

    #[test]
    fn suggests_from_the_current_directory_first_and_skips_invalid_commands() {
        let mut history = History::default();
        for (command, cwd) in [
            ("cd src", "/project"),
            ("cd docs", "/elsewhere"),
            ("cd gone", "/project"),
        ] {
            history.entries.push(HistoryEntry {
                command: command.into(),
                cwd: Some(cwd.into()),
                ..HistoryEntry::default()
            });
        }
        let valid = |command: &str| command != "cd gone";
        // Newest valid match from this folder wins over a newer one from elsewhere.
        assert_eq!(
            history.suggest("cd ", Some("/project"), valid),
            Some("cd src")
        );
        // With nothing from this folder, the newest valid match from anywhere is used.
        assert_eq!(history.suggest("cd ", Some("/new"), valid), Some("cd docs"));
        assert_eq!(history.suggest("cd g", Some("/project"), valid), None);
    }

    #[test]
    fn search_is_fuzzy_and_deduplicated() {
        let history = history(&["cargo build", "ls", "cargo build", "cargo test"]);
        let all: Vec<_> = history.search("", 10).iter().map(|hit| hit.index).collect();
        assert_eq!(all, vec![3, 2, 1]);
        let hits = history.search("cb", 10);
        assert_eq!(hits.len(), 1);
        assert_eq!(history.entries()[hits[0].index].command, "cargo build");
    }

    #[test]
    fn parses_zsh_extended_and_multiline_history() {
        let raw = b": 1700000000:2;git status\n: 1700000100:0;echo one\\\ntwo\nplain command\n";
        let entries = parse_zsh_history(raw);
        assert_eq!(entries.len(), 3);
        assert_eq!(entries[0].command, "git status");
        assert_eq!(entries[0].started_at, Some(1_700_000_000));
        assert_eq!(entries[0].duration_ms, Some(2000));
        assert_eq!(entries[1].command, "echo one\ntwo");
        assert_eq!(entries[2].command, "plain command");
    }

    #[test]
    fn unmetafies_zsh_bytes() {
        // "é" is 0xC3 0xA9; zsh stores 0xA9 as 0x83 0x89.
        let entries = parse_zsh_history(b"echo caf\xc3\x83\x89\n");
        assert_eq!(entries[0].command, "echo café");
    }

    #[test]
    fn parses_bash_history_with_timestamps() {
        let entries = parse_bash_history("#1700000000\nls -la\nmake\n");
        assert_eq!(entries[0].started_at, Some(1_700_000_000));
        assert_eq!(entries[1].command, "make");
        assert_eq!(entries[1].started_at, None);
    }
}
