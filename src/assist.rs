//! Prompt assistance: knows where the command line starts, reads what has been typed, offers a
//! history-based inline suggestion and a completion menu, and records finished commands.

use std::{
    path::{Path, PathBuf},
    time::Instant,
};

use crate::{
    completion::{self, Candidate, Completions},
    history::{self, History, HistoryEntry},
    terminal::{InputLine, ScreenPoint, Terminal},
};

/// A command that was started and not yet reported finished.
#[derive(Clone, Debug)]
struct PendingCommand {
    command: String,
    cwd: Option<String>,
    started: Instant,
    started_at: u64,
}

/// The open completion menu.
#[derive(Clone, Debug)]
pub struct CompletionMenu {
    pub completions: Completions,
    pub selected: usize,
    /// Command line (up to the cursor) the candidates were computed for.
    line: String,
}

impl CompletionMenu {
    pub fn selected_candidate(&self) -> Option<&Candidate> {
        self.completions.candidates.get(self.selected)
    }

    pub fn move_selection(&mut self, delta: isize) {
        let count = self.completions.candidates.len();
        if count > 0 {
            self.selected = (self.selected as isize + delta).rem_euclid(count as isize) as usize;
        }
    }
}

#[derive(Debug, Default)]
pub struct PromptAssist {
    /// Where typing starts on the current prompt; `None` while a command runs or without shell
    /// integration.
    input_start: Option<ScreenPoint>,
    cwd: Option<String>,
    path: Option<String>,
    executables: Option<(String, Vec<String>)>,
    pending: Option<PendingCommand>,
    /// The command line as last read from the screen.
    input: Option<InputLine>,
    /// Rest of the history suggestion after the typed text.
    suggestion: Option<String>,
    pub menu: Option<CompletionMenu>,
    /// Re-open the menu after the shell echoes an accepted directory.
    reopen_menu: bool,
}

impl PromptAssist {
    /// The shell finished drawing its prompt; typing starts at `start`.
    pub fn prompt_ready(
        &mut self,
        status: Option<i32>,
        cwd: Option<String>,
        start: Option<ScreenPoint>,
        history: &mut History,
    ) {
        if let Some(pending) = self.pending.take()
            && !pending.command.trim().is_empty()
        {
            history.record(HistoryEntry {
                command: pending.command,
                cwd: pending.cwd,
                exit_code: status,
                started_at: Some(pending.started_at),
                duration_ms: Some(pending.started.elapsed().as_millis() as u64),
                imported: false,
            });
        }
        if cwd.is_some() {
            self.cwd = cwd;
        }
        self.input_start = start;
        self.input = None;
        self.suggestion = None;
        self.menu = None;
    }

    /// Enter was pressed at the prompt: remember the typed line in case the shell does not
    /// report the command itself.
    pub fn enter_pressed(&mut self) {
        let typed = self
            .input
            .as_ref()
            .map(|input| input.text.trim().to_owned())
            .unwrap_or_default();
        self.begin_command(typed);
    }

    /// The shell reported the exact command line it is about to run.
    pub fn command_started(&mut self, command: String) {
        match &mut self.pending {
            Some(pending) => pending.command = command,
            None => self.begin_command(command),
        }
    }

    fn begin_command(&mut self, command: String) {
        if self.input_start.is_none() && self.pending.is_some() {
            return;
        }
        self.pending = Some(PendingCommand {
            command,
            cwd: self.cwd.clone(),
            started: Instant::now(),
            started_at: history::now_secs(),
        });
        self.input_start = None;
        self.input = None;
        self.suggestion = None;
        self.menu = None;
    }

    pub fn set_path(&mut self, path: String) {
        self.path = Some(path);
    }

    /// The shell's working directory as of its last prompt.
    pub fn cwd(&self) -> Option<&str> {
        self.cwd.as_deref()
    }

    pub fn is_at_prompt(&self) -> bool {
        self.input_start.is_some()
    }

    #[cfg(test)]
    pub fn input(&self) -> Option<&InputLine> {
        self.input.as_ref()
    }

    /// The suggested completion of the typed line (only the part not typed yet).
    pub fn suggestion(&self) -> Option<&str> {
        self.suggestion.as_deref()
    }

    /// Re-read the command line from the (synced) terminal and update suggestion and menu.
    /// Returns whether anything visible changed.
    pub fn refresh(
        &mut self,
        terminal: &Terminal,
        history: &History,
        suggestions: bool,
        as_you_type: bool,
    ) -> bool {
        let input = self
            .input_start
            .and_then(|start| terminal.prompt_input(start));
        let input_changed = input != self.input;
        self.input = input;

        // Checking suggestions touches the file system, so only when the line changed.
        let suggestion = match self
            .input
            .clone()
            .filter(|input| suggestions && input.cursor_at_end())
        {
            Some(input) if input_changed => self.suggest(&input.text, history),
            Some(_) => self.suggestion.clone(),
            None => None,
        };
        let suggestion_changed = suggestion != self.suggestion;
        self.suggestion = suggestion;

        let mut menu_changed = false;
        if input_changed {
            let line = self.input.as_ref().map(InputLine::before_cursor);
            let reopen = std::mem::take(&mut self.reopen_menu);
            let wanted = self.menu.is_some()
                || reopen
                || (as_you_type
                    && line.as_deref().is_some_and(|line| {
                        !line.trim().is_empty()
                            && (!line.ends_with(' ') || completion::opens_after_space(line))
                    }));
            match line {
                Some(line) if wanted => {
                    let unchanged = self.menu.as_ref().is_some_and(|menu| menu.line == line);
                    if !unchanged {
                        let completions = self.complete(&line, history);
                        self.menu =
                            (!completions.candidates.is_empty()).then_some(CompletionMenu {
                                completions,
                                selected: 0,
                                line,
                            });
                        menu_changed = true;
                    }
                }
                _ => menu_changed = self.menu.take().is_some(),
            }
        }
        input_changed || suggestion_changed || menu_changed
    }

    /// Completions for the current command line (up to the cursor).
    pub fn complete_current(&mut self, history: &History) -> Option<Completions> {
        let line = self.input.as_ref()?.before_cursor();
        Some(self.complete(&line, history))
    }

    pub fn open_menu(&mut self, completions: Completions) {
        let line = self
            .input
            .as_ref()
            .map(InputLine::before_cursor)
            .unwrap_or_default();
        self.menu = Some(CompletionMenu {
            completions,
            selected: 0,
            line,
        });
    }

    pub fn close_menu(&mut self) -> bool {
        self.menu.take().is_some()
    }

    /// Keep completing inside a directory after it was accepted.
    pub fn reopen_menu_after_echo(&mut self) {
        self.reopen_menu = true;
    }

    /// Gray text to show after the typed `line`: the rest of a command from history that fits
    /// this folder, else the rest of the best completion of the word being typed.
    fn suggest(&mut self, line: &str, history: &History) -> Option<String> {
        let cwd = self.cwd_path();
        if let Some(command) = history.suggest(line, self.cwd.as_deref(), |command| {
            completion::valid_in(command, &cwd)
        }) {
            return Some(command[line.len()..].to_owned());
        }
        let completions = self.complete(line, history);
        let word = completions.word.as_str();
        if word.is_empty() {
            return None;
        }
        completions
            .candidates
            .iter()
            .filter(|candidate| candidate.kind != completion::Kind::Argument)
            .find(|candidate| {
                candidate.replacement.len() > word.len() && candidate.replacement.starts_with(word)
            })
            .map(|candidate| candidate.replacement[word.len()..].to_owned())
    }

    /// The shell's folder, or home before the shell reported one.
    fn cwd_path(&self) -> PathBuf {
        let home = std::env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_default();
        self.cwd.as_deref().map_or(home, PathBuf::from)
    }

    fn complete(&mut self, line: &str, history: &History) -> Completions {
        let path = self
            .path
            .clone()
            .or_else(|| std::env::var("PATH").ok())
            .unwrap_or_default();
        if self
            .executables
            .as_ref()
            .is_none_or(|(cached, _)| *cached != path)
        {
            let names = completion::executables(&path);
            self.executables = Some((path, names));
        }
        let cwd = self.cwd_path();
        completion::complete(&completion::Context {
            line,
            cwd: Path::new(&cwd),
            executables: self
                .executables
                .as_ref()
                .map_or(&[], |(_, names)| names.as_slice()),
            history,
        })
    }
}

/// The next word of a suggestion (leading spaces included), for partial accepts.
pub fn next_word(suggestion: &str) -> &str {
    let start = suggestion.len() - suggestion.trim_start().len();
    let end = suggestion[start..]
        .find(' ')
        .map_or(suggestion.len(), |index| start + index);
    &suggestion[..end]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::terminal::TerminalConfig;

    fn shell() -> (Terminal, PromptAssist, History) {
        let mut terminal = Terminal::new(TerminalConfig {
            cols: 40,
            rows: 5,
            scrollback: 100,
        })
        .unwrap();
        terminal.resize(40, 5, 8, 16).unwrap();
        (terminal, PromptAssist::default(), History::default())
    }

    fn prompt(terminal: &mut Terminal, assist: &mut PromptAssist, history: &mut History) {
        terminal.write(b"\r\n$ ");
        let start = terminal.cursor_anchor().ok();
        assist.prompt_ready(Some(0), Some("/tmp".into()), start, history);
    }

    #[test]
    fn records_commands_and_suggests_them() {
        let (mut terminal, mut assist, mut history) = shell();
        prompt(&mut terminal, &mut assist, &mut history);
        terminal.write(b"echo hello");
        terminal.sync().unwrap();
        assist.refresh(&terminal, &history, true, false);
        assert_eq!(assist.input().unwrap().text, "echo hello");
        assist.enter_pressed();
        assert!(!assist.is_at_prompt());
        terminal.write(b"\r\nhello");
        prompt(&mut terminal, &mut assist, &mut history);
        assert_eq!(history.entries().len(), 1);
        assert_eq!(history.entries()[0].command, "echo hello");
        assert_eq!(history.entries()[0].cwd.as_deref(), Some("/tmp"));

        terminal.write(b"ec");
        terminal.sync().unwrap();
        assert!(assist.refresh(&terminal, &history, true, false));
        assert_eq!(assist.suggestion(), Some("ho hello"));
        assert!(assist.refresh(&terminal, &history, false, false));
        assert_eq!(assist.suggestion(), None);
    }

    #[test]
    fn shell_reported_command_wins() {
        let (mut terminal, mut assist, mut history) = shell();
        prompt(&mut terminal, &mut assist, &mut history);
        assist.enter_pressed();
        assist.command_started("ls -la".into());
        prompt(&mut terminal, &mut assist, &mut history);
        assert_eq!(history.entries()[0].command, "ls -la");
    }

    #[test]
    fn menu_follows_typing() {
        let (mut terminal, mut assist, mut history) = shell();
        prompt(&mut terminal, &mut assist, &mut history);
        terminal.write(b"git ch");
        terminal.sync().unwrap();
        assist.refresh(&terminal, &history, true, false);
        let completions = assist.complete_current(&history).unwrap();
        assert_eq!(completions.word, "ch");
        assist.open_menu(completions);
        terminal.write(b"e");
        terminal.sync().unwrap();
        assert!(assist.refresh(&terminal, &history, true, false));
        let menu = assist.menu.as_ref().unwrap();
        assert_eq!(menu.completions.word, "che");
        assert_eq!(menu.selected_candidate().unwrap().display, "checkout");
        terminal.write(b"zzz");
        terminal.sync().unwrap();
        assist.refresh(&terminal, &history, true, false);
        assert!(assist.menu.is_none());
    }

    #[test]
    fn next_word_includes_leading_space() {
        assert_eq!(next_word(" status --short"), " status");
        assert_eq!(next_word("tus"), "tus");
    }
}
