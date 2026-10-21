//! Shell integration for zsh and bash.
//!
//! Small generated startup scripts load the user's own startup files first, then install a
//! prompt hook that runs last before every prompt. The hook re-reads a prompt file that the app
//! rewrites whenever the prompt settings change, so a new prompt style applies at the next prompt
//! without restarting the shell.
//!
//! Prompts are written as patterns with `{token}` placeholders (see [`TOKENS`]), translated into
//! each shell's native prompt escapes.

use std::{fs, io, path::PathBuf};

use crate::settings::{PromptStyle, TerminalSettings};

/// Placeholders accepted in prompt patterns, with a description for the settings panel.
pub const TOKENS: &[(&str, &str)] = &[
    ("{dir}", "current folder name"),
    ("{path}", "full path (~ for home)"),
    ("{git}", "git branch, with a leading space"),
    ("{user}", "user name"),
    ("{host}", "computer name"),
    ("{time}", "time (HH:MM)"),
    ("{symbol}", "❯"),
    ("{newline}", "line break"),
    (
        "{red} {green} {yellow} {blue} {magenta} {cyan} {gray}",
        "text color",
    ),
    ("{bold} / {reset}", "bold / back to normal"),
];

const SYMBOL: &str = "❯";

/// One parsed piece of a prompt pattern.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Token<'a> {
    Text(&'a str),
    User,
    Host,
    Dir,
    Path,
    Git,
    Time,
    Symbol,
    Newline,
    /// ANSI color index 0-7, or 8 for gray.
    Color(u8),
    Bold,
    Reset,
}

pub fn parse(pattern: &str) -> Vec<Token<'_>> {
    let mut tokens = Vec::new();
    let mut rest = pattern;
    while !rest.is_empty() {
        let Some(open) = rest.find('{') else {
            tokens.push(Token::Text(rest));
            break;
        };
        if open > 0 {
            tokens.push(Token::Text(&rest[..open]));
        }
        let after = &rest[open..];
        let Some(close) = after.find('}') else {
            tokens.push(Token::Text(after));
            break;
        };
        let token = match &after[1..close] {
            "user" => Token::User,
            "host" => Token::Host,
            "dir" => Token::Dir,
            "path" => Token::Path,
            "git" => Token::Git,
            "time" => Token::Time,
            "symbol" => Token::Symbol,
            "newline" => Token::Newline,
            "black" => Token::Color(0),
            "red" => Token::Color(1),
            "green" => Token::Color(2),
            "yellow" => Token::Color(3),
            "blue" => Token::Color(4),
            "magenta" => Token::Color(5),
            "cyan" => Token::Color(6),
            "white" => Token::Color(7),
            "gray" | "grey" => Token::Color(8),
            "bold" => Token::Bold,
            "reset" => Token::Reset,
            _ => Token::Text(&after[..=close]),
        };
        tokens.push(token);
        rest = &after[close + 1..];
    }
    tokens
}

/// Translate a pattern into a zsh `PROMPT`. Returns the prompt and whether git info is needed.
pub fn zsh_prompt(pattern: &str) -> (String, bool) {
    let tokens = parse(pattern);
    let git = tokens.contains(&Token::Git);
    let mut out = String::new();
    for token in tokens {
        match token {
            Token::Text(text) => {
                for ch in text.chars() {
                    match ch {
                        '%' => out.push_str("%%"),
                        // With prompt_subst on, these would start expansions.
                        '$' | '`' | '\\' if git => {
                            out.push('\\');
                            out.push(ch);
                        }
                        _ => out.push(ch),
                    }
                }
            }
            Token::User => out.push_str("%n"),
            Token::Host => out.push_str("%m"),
            Token::Dir => out.push_str("%1~"),
            Token::Path => out.push_str("%~"),
            Token::Git => out.push_str("${_gpu_terminal_git}"),
            Token::Time => out.push_str("%T"),
            Token::Symbol => out.push_str(SYMBOL),
            Token::Newline => out.push('\n'),
            Token::Color(index) => out.push_str(&format!("%F{{{index}}}")),
            Token::Bold => out.push_str("%B"),
            Token::Reset => out.push_str("%f%b"),
        }
    }
    (out, git)
}

/// Translate a pattern into a bash `PS1`. Returns the prompt and whether git info is needed.
pub fn bash_prompt(pattern: &str) -> (String, bool) {
    let tokens = parse(pattern);
    let git = tokens.contains(&Token::Git);
    let mut out = String::new();
    for token in tokens {
        match token {
            Token::Text(text) => {
                for ch in text.chars() {
                    if matches!(ch, '\\' | '$' | '`') {
                        out.push('\\');
                    }
                    out.push(ch);
                }
            }
            Token::User => out.push_str("\\u"),
            Token::Host => out.push_str("\\h"),
            Token::Dir => out.push_str("\\W"),
            Token::Path => out.push_str("\\w"),
            Token::Git => out.push_str("${_gpu_terminal_git}"),
            Token::Time => out.push_str("\\A"),
            Token::Symbol => out.push_str(SYMBOL),
            Token::Newline => out.push_str("\\n"),
            Token::Color(8) => out.push_str("\\[\\e[90m\\]"),
            Token::Color(index) => out.push_str(&format!("\\[\\e[3{index}m\\]")),
            Token::Bold => out.push_str("\\[\\e[1m\\]"),
            Token::Reset => out.push_str("\\[\\e[0m\\]"),
        }
    }
    (out, git)
}

/// How to launch the shell, possibly wrapped by the integration scripts.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Launch {
    /// `None` runs the user's login shell.
    pub program: Option<String>,
    pub args: Vec<String>,
    pub env: Vec<(String, String)>,
}

/// Decide the shell command line and environment for a new session.
pub fn launch(settings: &TerminalSettings) -> Launch {
    let mut parts = settings.shell.split_whitespace().map(str::to_owned);
    let program = parts.next();
    let args: Vec<String> = parts.collect();
    let mut launch = Launch {
        program: program.clone(),
        args,
        env: Vec::new(),
    };
    if !settings.shell_integration {
        return launch;
    }

    let shell = program
        .clone()
        .or_else(|| std::env::var("SHELL").ok())
        .unwrap_or_else(|| "/bin/zsh".to_owned());
    let name = shell.rsplit('/').next().unwrap_or_default();
    let dir = integration_dir();
    match name {
        "zsh" => {
            if let Ok(user_zdotdir) = std::env::var("ZDOTDIR") {
                launch
                    .env
                    .push(("GPU_TERMINAL_USER_ZDOTDIR".into(), user_zdotdir));
            }
            launch
                .env
                .push(("ZDOTDIR".into(), path_string(dir.join("zsh"))));
            launch.env.push((
                "GPU_TERMINAL_INTEGRATION".into(),
                path_string(dir.join("integration.zsh")),
            ));
            launch.env.push((
                "GPU_TERMINAL_PROMPT_FILE".into(),
                path_string(dir.join("prompt.zsh")),
            ));
        }
        // Only wrap a plain `bash`; explicit arguments are the user's to control.
        "bash" if launch.args.is_empty() => {
            if launch.program.is_none() {
                launch.env.push(("GPU_TERMINAL_LOGIN".into(), "1".into()));
            }
            launch.program = Some(shell);
            launch.args = vec![
                "--rcfile".into(),
                path_string(dir.join("integration.bash")),
                "-i".into(),
            ];
            launch.env.push((
                "GPU_TERMINAL_PROMPT_FILE".into(),
                path_string(dir.join("prompt.bash")),
            ));
        }
        _ => {}
    }
    launch
}

/// Write the static integration scripts and the prompt files for the current settings.
pub fn install(settings: &TerminalSettings) -> io::Result<()> {
    let dir = integration_dir();
    fs::create_dir_all(dir.join("zsh"))?;
    fs::write(dir.join("zsh").join(".zshenv"), ZSHENV)?;
    for (name, script) in ZSH_WRAPPERS {
        fs::write(
            dir.join("zsh").join(name),
            format!("# Generated by Bridge.\n{script}"),
        )?;
    }
    fs::write(dir.join("integration.zsh"), INTEGRATION_ZSH)?;
    fs::write(dir.join("integration.bash"), INTEGRATION_BASH)?;
    write_prompts(settings)
}

/// Rewrite the prompt files; running shells pick them up at their next prompt.
pub fn write_prompts(settings: &TerminalSettings) -> io::Result<()> {
    let dir = integration_dir();
    fs::create_dir_all(&dir)?;
    let prompt = PromptChoice::from_settings(settings);
    let starship_config = path_string(dir.join("starship.toml"));
    fs::write(
        dir.join("prompt.zsh"),
        zsh_prompt_file(&prompt, &starship_config, settings.hide_partial_line_marker),
    )?;
    fs::write(
        dir.join("prompt.bash"),
        bash_prompt_file(&prompt, &starship_config),
    )
}

/// Whether the `starship` program can be found (also outside the app's minimal launch PATH).
pub fn starship_installed() -> bool {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_default();
    let path = std::env::var_os("PATH").unwrap_or_default();
    std::env::split_paths(&path)
        .chain([
            PathBuf::from("/opt/homebrew/bin"),
            PathBuf::from("/usr/local/bin"),
            home.join(".cargo/bin"),
            home.join(".local/bin"),
        ])
        .any(|dir| dir.join("starship").is_file())
}

/// The prompt the shells should show.
struct PromptChoice<'a> {
    /// Use Starship when installed.
    starship: bool,
    /// Pattern to show (the fallback when Starship is chosen but missing); `None` keeps the
    /// shell's own prompt.
    pattern: Option<&'a str>,
}

impl<'a> PromptChoice<'a> {
    fn from_settings(settings: &'a TerminalSettings) -> Self {
        Self {
            starship: settings.prompt_style == PromptStyle::Starship,
            pattern: settings.prompt_style.template(&settings.prompt_template),
        }
    }
}

fn zsh_prompt_file(prompt: &PromptChoice<'_>, starship_config: &str, hide_marker: bool) -> String {
    let mut file = String::from("# Generated by Bridge from your prompt settings.\n");
    let pattern_block = match prompt.pattern {
        Some(pattern) => {
            let (prompt, git) = zsh_prompt(pattern);
            format!(
                "{}PROMPT={}\nRPROMPT=''\n_gpu_terminal_overridden=1\n",
                if git {
                    "setopt prompt_subst\n_gpu_terminal_git_branch\n"
                } else {
                    ""
                },
                shell_quote(&prompt)
            )
        }
        None => "if (( _gpu_terminal_overridden )); then\n  \
                   PROMPT=\"$_gpu_terminal_user_prompt\"\n  \
                   RPROMPT=\"$_gpu_terminal_user_rprompt\"\n  \
                   _gpu_terminal_overridden=0\n\
                 fi\n"
            .to_owned(),
    };
    if prompt.starship {
        // Start Starship once it is installed (no ~/.zshrc changes needed). Without a Starship
        // config of the user's own, use the preset that needs no special icon fonts.
        file.push_str(&format!(
            "if (( ! ${{_gpu_terminal_starship:-0}} )) && whence -p starship >/dev/null; then\n  \
               if [[ -z \"${{STARSHIP_CONFIG-}}\" && ! -e \"${{XDG_CONFIG_HOME:-$HOME/.config}}/starship.toml\" ]]; then\n    \
                 export STARSHIP_CONFIG={config}\n    \
                 [[ -e \"$STARSHIP_CONFIG\" ]] || starship preset no-nerd-font -o \"$STARSHIP_CONFIG\" 2>/dev/null\n  \
               fi\n  \
               if [[ \"$_gpu_terminal_user_prompt\" == *starship* ]]; then\n    \
                 typeset -g _gpu_terminal_starship_prompt=\"$_gpu_terminal_user_prompt\" _gpu_terminal_starship_rprompt=\"$_gpu_terminal_user_rprompt\"\n  \
               else\n    \
                 eval \"$(starship init zsh)\"\n    \
                 typeset -g _gpu_terminal_starship_prompt=\"$PROMPT\" _gpu_terminal_starship_rprompt=\"$RPROMPT\"\n  \
               fi\n  \
               typeset -g _gpu_terminal_starship=1\n\
             fi\n\
             if (( ${{_gpu_terminal_starship:-0}} )); then\n  \
               setopt prompt_subst\n  \
               PROMPT=\"$_gpu_terminal_starship_prompt\"\n  \
               RPROMPT=\"$_gpu_terminal_starship_rprompt\"\n  \
               _gpu_terminal_overridden=1\n\
             else\n{pattern_block}fi\n",
            config = shell_quote(starship_config),
        ));
    } else {
        file.push_str(&pattern_block);
    }
    file.push_str(if hide_marker {
        "PROMPT_EOL_MARK=''\n"
    } else {
        "PROMPT_EOL_MARK='%B%S%#%s%b'\n"
    });
    file
}

fn bash_prompt_file(prompt: &PromptChoice<'_>, starship_config: &str) -> String {
    let mut file = String::from("# Generated by Bridge from your prompt settings.\n");
    let pattern_block = match prompt.pattern {
        Some(pattern) => {
            let (prompt, git) = bash_prompt(pattern);
            format!(
                "{}PS1={}\n_gpu_terminal_overridden=1\n",
                if git {
                    "_gpu_terminal_git_branch\n"
                } else {
                    ""
                },
                shell_quote(&prompt)
            )
        }
        None => "if [[ \"$_gpu_terminal_overridden\" == 1 ]]; then\n  \
                   PS1=\"$_gpu_terminal_user_ps1\"\n  \
                   _gpu_terminal_overridden=0\n\
                 fi\n"
            .to_owned(),
    };
    if prompt.starship {
        file.push_str(&format!(
            "if [[ \"${{_gpu_terminal_starship:-0}}\" != 1 ]] && command -v starship >/dev/null; then\n  \
               if [[ -z \"${{STARSHIP_CONFIG-}}\" && ! -e \"${{XDG_CONFIG_HOME:-$HOME/.config}}/starship.toml\" ]]; then\n    \
                 export STARSHIP_CONFIG={config}\n    \
                 [[ -e \"$STARSHIP_CONFIG\" ]] || starship preset no-nerd-font -o \"$STARSHIP_CONFIG\" 2>/dev/null\n  \
               fi\n  \
               [[ \"$_gpu_terminal_user_ps1\" == *starship* ]] || eval \"$(starship init bash)\"\n  \
               _gpu_terminal_starship=1\n\
             fi\n\
             if [[ \"${{_gpu_terminal_starship:-0}}\" != 1 ]]; then\n{pattern_block}fi\n",
            config = shell_quote(starship_config),
        ));
    } else {
        file.push_str(&pattern_block);
    }
    file
}

/// Single-quote a string for zsh/bash.
fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn integration_dir() -> PathBuf {
    TerminalSettings::path()
        .parent()
        .map_or_else(|| PathBuf::from("."), |dir| dir.join("shell"))
}

fn path_string(path: PathBuf) -> String {
    path.to_string_lossy().into_owned()
}

/// Environment variable giving a sandboxed shell its own history file.
pub const HISTFILE_ENV: &str = "GPU_TERMINAL_HISTFILE";

/// Our `ZDOTDIR` points here: restore the user's `ZDOTDIR` so zsh reads their own `.zprofile`,
/// `.zshrc` and `.zlogin` next, source their `.zshenv`, then load the integration.
///
/// A sandboxed session (with `GPU_TERMINAL_HISTFILE`) keeps our `ZDOTDIR` instead: the wrappers
/// below load the user's startup files and then point `HISTFILE` at the session's own history, so
/// the user's history (which the sandbox cannot read) is never opened.
const ZSHENV: &str = r#"# Generated by Bridge. Restores your ZDOTDIR and loads your own startup files.
if [[ -n "${GPU_TERMINAL_HISTFILE-}" ]]; then
  typeset -g _gpu_terminal_user_zdotdir="${GPU_TERMINAL_USER_ZDOTDIR:-$HOME}"
  unset GPU_TERMINAL_USER_ZDOTDIR
  [[ -r "$_gpu_terminal_user_zdotdir/.zshenv" ]] && source "$_gpu_terminal_user_zdotdir/.zshenv"
else
  if [[ -n "${GPU_TERMINAL_USER_ZDOTDIR-}" ]]; then
    export ZDOTDIR="$GPU_TERMINAL_USER_ZDOTDIR"
  else
    unset ZDOTDIR
  fi
  unset GPU_TERMINAL_USER_ZDOTDIR
  [[ -r "${ZDOTDIR:-$HOME}/.zshenv" ]] && source "${ZDOTDIR:-$HOME}/.zshenv"
fi
if [[ -o interactive && -r "${GPU_TERMINAL_INTEGRATION-}" ]]; then
  source "$GPU_TERMINAL_INTEGRATION"
fi
"#;

/// The rest of a sandboxed session's startup files: each loads the user's own, and the history
/// file is set after them (and before zsh reads it).
const ZSH_WRAPPERS: [(&str, &str); 4] = [
    (
        ".zprofile",
        "[[ -r \"$_gpu_terminal_user_zdotdir/.zprofile\" ]] && source \"$_gpu_terminal_user_zdotdir/.zprofile\"\n",
    ),
    (
        ".zshrc",
        "[[ -r \"$_gpu_terminal_user_zdotdir/.zshrc\" ]] && source \"$_gpu_terminal_user_zdotdir/.zshrc\"\n\
         [[ -n \"${GPU_TERMINAL_HISTFILE-}\" ]] && HISTFILE=\"$GPU_TERMINAL_HISTFILE\"\n",
    ),
    (
        ".zlogin",
        "[[ -r \"$_gpu_terminal_user_zdotdir/.zlogin\" ]] && source \"$_gpu_terminal_user_zdotdir/.zlogin\"\n\
         [[ -n \"${GPU_TERMINAL_HISTFILE-}\" ]] && HISTFILE=\"$GPU_TERMINAL_HISTFILE\"\n",
    ),
    (
        ".zlogout",
        "[[ -r \"$_gpu_terminal_user_zdotdir/.zlogout\" ]] && source \"$_gpu_terminal_user_zdotdir/.zlogout\"\n",
    ),
];

const INTEGRATION_ZSH: &str = r#"# Generated by Bridge: applies prompt settings after your own startup files.
typeset -g _gpu_terminal_overridden=0

_gpu_terminal_prompt() {
  [[ -r "${GPU_TERMINAL_PROMPT_FILE-}" ]] && source "$GPU_TERMINAL_PROMPT_FILE"
  # Invisible end-of-prompt marker with the last exit status and the current directory: tells the
  # terminal where typing starts. Re-appended each time so it is never duplicated.
  local mark=$'%{\e]7700;P;%?;%d\a%}'
  PROMPT="${PROMPT%"$mark"}$mark"
  # Report PATH changes so the terminal can complete command names.
  if [[ "$PATH" != "${_gpu_terminal_reported_path-}" ]]; then
    typeset -g _gpu_terminal_reported_path="$PATH"
    builtin print -rn -- $'\e]7700;E;'"${PATH//[$'\a\e']/}"$'\a'
  fi
}

# Reports the command line when a command starts (for history, and to keep the cursor hidden
# while its output streams in).
_gpu_terminal_preexec() {
  builtin print -rn -- $'\e]7700;C;'"${1//[$'\a\e']/}"$'\a'
}

# Current git branch (with a leading space) in $_gpu_terminal_git. Reads .git/HEAD directly
# instead of running git, so it costs microseconds rather than tens of milliseconds per prompt.
_gpu_terminal_git_branch() {
  typeset -g _gpu_terminal_git=''
  local dir=$PWD git head
  while true; do
    git=$dir/.git
    if [[ -f $git ]]; then
      # Worktrees and submodules: .git is a file pointing at the real git directory.
      read -r head < $git
      git=${head#gitdir: }
      [[ $git == /* ]] || git=$dir/$git
    fi
    if [[ -r $git/HEAD ]]; then
      read -r head < $git/HEAD
      if [[ $head == 'ref: refs/heads/'* ]]; then
        head=${head#ref: refs/heads/}
      else
        head=${head[1,7]}
      fi
      _gpu_terminal_git=" ${head//\%/%%}"
      return
    fi
    [[ $dir == / || -z $dir ]] && return
    dir=${dir:h}
  done
}

_gpu_terminal_setup() {
  # Runs once at the first prompt, when ~/.zshrc and friends have already been loaded.
  precmd_functions=(${precmd_functions:#_gpu_terminal_setup})
  typeset -g _gpu_terminal_user_prompt="$PROMPT" _gpu_terminal_user_rprompt="$RPROMPT"
  # Keep the prompt hook last so it wins over prompt frameworks that also use precmd.
  precmd_functions=(${precmd_functions:#_gpu_terminal_prompt} _gpu_terminal_prompt)
  bindkey -M emacs '^[[3~' delete-char 2>/dev/null
  _gpu_terminal_prompt
}

typeset -ga precmd_functions
precmd_functions+=(_gpu_terminal_setup)
typeset -ga preexec_functions
preexec_functions+=(_gpu_terminal_preexec)
"#;

const INTEGRATION_BASH: &str = r#"# Generated by Bridge: loads your startup files, then applies prompt settings.
if [[ -n "${GPU_TERMINAL_LOGIN-}" ]]; then
  unset GPU_TERMINAL_LOGIN
  [[ -r /etc/profile ]] && . /etc/profile
  for _gpu_terminal_rc in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
    if [[ -r "$_gpu_terminal_rc" ]]; then
      . "$_gpu_terminal_rc"
      break
    fi
  done
  unset _gpu_terminal_rc
elif [[ -r "$HOME/.bashrc" ]]; then
  . "$HOME/.bashrc"
fi
# A sandboxed session keeps its own history (bash reads it after this file).
[[ -n "${GPU_TERMINAL_HISTFILE-}" ]] && HISTFILE="$GPU_TERMINAL_HISTFILE"

# Current git branch (with a leading space) in $_gpu_terminal_git, read from .git/HEAD without
# running git.
_gpu_terminal_git_branch() {
  _gpu_terminal_git=''
  local dir=$PWD git head
  while true; do
    git=$dir/.git
    if [[ -f $git ]]; then
      read -r head < "$git"
      git=${head#gitdir: }
      [[ $git == /* ]] || git=$dir/$git
    fi
    if [[ -r $git/HEAD ]]; then
      read -r head < "$git/HEAD"
      if [[ $head == 'ref: refs/heads/'* ]]; then
        head=${head#ref: refs/heads/}
      else
        head=${head:0:7}
      fi
      _gpu_terminal_git=" $head"
      return
    fi
    [[ $dir == / || -z $dir ]] && return
    dir=${dir%/*}
    [[ -z $dir ]] && dir=/
  done
}

_gpu_terminal_user_ps1="$PS1"
_gpu_terminal_overridden=0
_gpu_terminal_prompt() {
  local status=$?
  [[ -r "${GPU_TERMINAL_PROMPT_FILE-}" ]] && . "$GPU_TERMINAL_PROMPT_FILE"
  # Invisible end-of-prompt marker with the last exit status and the current directory.
  local mark='\[\e]7700;P;$?;$PWD\a\]'
  PS1="${PS1%"$mark"}$mark"
  if [[ "$PATH" != "${_gpu_terminal_reported_path-}" ]]; then
    _gpu_terminal_reported_path="$PATH"
    printf '\e]7700;E;%s\a' "$PATH"
  fi
  return $status
}
PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND;}_gpu_terminal_prompt"
"#;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_tokens_and_keeps_unknown_braces() {
        assert_eq!(
            parse("{blue}{dir}{reset} {nope} x"),
            vec![
                Token::Color(4),
                Token::Dir,
                Token::Reset,
                Token::Text(" "),
                Token::Text("{nope}"),
                Token::Text(" x"),
            ]
        );
        assert_eq!(parse("a { b"), vec![Token::Text("a "), Token::Text("{ b")]);
    }

    #[test]
    fn translates_to_zsh() {
        assert_eq!(
            zsh_prompt("{blue}{dir}{reset} 100% "),
            ("%F{4}%1~%f%b 100%% ".to_owned(), false)
        );
        let (prompt, git) = zsh_prompt("{path}{git} $ ");
        assert!(git);
        assert_eq!(prompt, "%~${_gpu_terminal_git} \\$ ");
    }

    #[test]
    fn translates_to_bash() {
        assert_eq!(
            bash_prompt("{user}@{host} {gray}{dir}{reset}{git} $"),
            (
                "\\u@\\h \\[\\e[90m\\]\\W\\[\\e[0m\\]${_gpu_terminal_git} \\$".to_owned(),
                true
            )
        );
    }

    /// `GPU_TERMINAL_DUMP_DIR=/some/dir cargo test -- --ignored dump_scripts` writes the scripts
    /// (with default settings) for checking them in a real shell.
    #[test]
    #[ignore = "writes files for manual shell checks"]
    fn dump_scripts() {
        let dir =
            PathBuf::from(std::env::var("GPU_TERMINAL_DUMP_DIR").expect("GPU_TERMINAL_DUMP_DIR"));
        fs::create_dir_all(dir.join("zsh")).unwrap();
        fs::write(dir.join("zsh").join(".zshenv"), ZSHENV).unwrap();
        fs::write(dir.join("integration.zsh"), INTEGRATION_ZSH).unwrap();
        fs::write(dir.join("integration.bash"), INTEGRATION_BASH).unwrap();
        let settings = TerminalSettings::default();
        let prompt = PromptChoice::from_settings(&settings);
        fs::write(
            dir.join("prompt.zsh"),
            zsh_prompt_file(&prompt, "/nonexistent", true),
        )
        .unwrap();
        fs::write(
            dir.join("prompt.bash"),
            bash_prompt_file(&prompt, "/nonexistent"),
        )
        .unwrap();
    }

    #[test]
    fn quotes_single_quotes() {
        assert_eq!(shell_quote("it's"), "'it'\\''s'");
    }

    fn choice(starship: bool, pattern: Option<&str>) -> PromptChoice<'_> {
        PromptChoice { starship, pattern }
    }

    #[test]
    fn default_style_restores_the_shell_prompt() {
        let file = zsh_prompt_file(&choice(false, None), "/cfg", true);
        assert!(file.contains("_gpu_terminal_user_prompt"));
        assert!(file.contains("PROMPT_EOL_MARK=''"));
        let file = zsh_prompt_file(&choice(false, Some("{dir} ")), "/cfg", false);
        assert!(file.contains("PROMPT='%1~ '"));
        assert!(!file.contains("_gpu_terminal_git_branch"));
        assert!(!file.contains("starship"));
        let file = zsh_prompt_file(&choice(false, Some("{dir}{git} ")), "/cfg", false);
        assert!(file.contains("_gpu_terminal_git_branch"));
    }

    #[test]
    fn starship_style_falls_back_to_pattern() {
        let file = zsh_prompt_file(&choice(true, Some("{dir} ")), "/cfg", true);
        assert!(file.contains("starship init zsh"));
        assert!(file.contains("export STARSHIP_CONFIG='/cfg'"));
        assert!(file.contains("else\nPROMPT='%1~ '"));
        let file = bash_prompt_file(&choice(true, Some("{dir} ")), "/cfg");
        assert!(file.contains("starship init bash"));
        assert!(file.contains("PS1='\\W '"));
    }

    #[test]
    fn wraps_zsh_and_plain_bash_only() {
        let zsh = launch(&TerminalSettings {
            shell: "/bin/zsh".into(),
            ..TerminalSettings::default()
        });
        assert!(zsh.env.iter().any(|(key, _)| key == "ZDOTDIR"));

        let bash = launch(&TerminalSettings {
            shell: "/bin/bash".into(),
            ..TerminalSettings::default()
        });
        assert_eq!(bash.args[0], "--rcfile");

        let custom = launch(&TerminalSettings {
            shell: "/bin/bash --norc".into(),
            ..TerminalSettings::default()
        });
        assert_eq!(custom.args, vec!["--norc"]);
        assert!(custom.env.is_empty());

        let disabled = launch(&TerminalSettings {
            shell: "/bin/zsh".into(),
            shell_integration: false,
            ..TerminalSettings::default()
        });
        assert!(disabled.env.is_empty());
    }
}
