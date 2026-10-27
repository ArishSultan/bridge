# Decisions

**The name: Bridge.** It is a workspace, not only a terminal: projects, servers, tunnels,
sandboxes. Like a ship's bridge, everything is run from here. It is also where agents will cross
over to your machines (see *Next*), without being handed your keys.

Short notes on what we chose and why.

## v2: Swift and libghostty

**Swift instead of Rust.** v2 is a native macOS app: SwiftUI and AppKit for the windows, so the app
gets what macOS offers (input methods, menus, settings windows, system materials) without going
through gpui.

**libghostty renders the terminals, not SwiftUI.** SwiftUI isn't a fast way to draw a terminal
grid: Text and Canvas lay out on the CPU. Fast terminals draw the grid on the GPU with a glyph
atlas, which is what libghostty's Metal renderer does. v1 used only libghostty-vt (the parser and
screen) and drew the grid itself; v2 embeds all of libghostty, the same embedding API Ghostty's own
macOS app is built on. Each terminal gets its own pty, I/O thread and renderer thread drawing into
a Metal layer, synced to the display, so a terminal flooding output never holds up the others or
the window. SwiftUI only draws the chrome around them.

**One module talks to C.** Only `Sources/BridgeTerm` calls libghostty's C API. That API is
internal to Ghostty and changes between versions, so Ghostty is pinned as a submodule
(v1.3.1, the newest that builds with Zig 0.15) and moving it is a deliberate change. Fixes the
pinned release needs from newer Ghostty sit in `patches/ghostty` (so far: the libtool archive fix
needed with Xcode 27).

**Settings become a Ghostty config.** Bridge's settings are turned into a Ghostty config
(`TerminalConfig`) and applied to every open terminal at once. Keybindings stay at Ghostty's macOS
defaults; the actions they produce (split, new tab, move focus) are handled by the app.

**SwiftData, not JSON files.** Settings, projects, SSH hosts, port forwards, sandbox profiles, the
Vaultwarden account and command history are rows in a SwiftData store in
`~/Library/Application Support/Bridge`, a folder no sandbox can read. The app keeps working on its
value types and saving brings the rows in line, so the store never leaks into the views. Each
project, item, host, forward and command is a row of its own; only trees and variants (a split
layout, a sandbox's rules, the settings) are encoded in their row. v1's JSON files are read once,
the first time v2 starts; a file that can't be read is copied aside and reported, never taken for
an empty list (which once wiped projects on the next save). Settings are not in UserDefaults:
sandboxed programs could read and change those through cfprefsd.

**Native chrome, the terminal's colors only in the terminal.** Windows, the sidebar, toolbar,
sheets and menus are SwiftUI's own components and look the way the system draws them (Liquid Glass
on macOS 26): glass is for the toolbar, sidebar and floating controls, never for content. The
color scheme colors the terminals; the rest follows the system's appearance and accent color.
macOS 15 is supported, with materials where macOS 26 has glass.

**Bridge's own shell integration, over a socket.** libghostty owns the pty, so v1's private
escape codes can't reach the app. The scripts emit standard OSC 133 and OSC 7 for libghostty and
send commands and prompts to the app over a unix socket (zsh's `zsocket`; bash through
`bridge-helper`). They live in `shell-v2/`, so v1 and v2 never overwrite each other's scripts.

**Suggestions drawn by zsh.** v1 read the command line off the screen and painted suggestions
over it. In v2 zsh sends its line and draws the app's suggestion itself (`POSTDISPLAY`), so it
always lines up; bash gets history and ⌃R but no inline suggestions.

**Passwords through the app, not the helper.** The helper is its own (ad-hoc signed) binary, so
it can't read the app's Keychain items without a prompt. ssh's askpass asks the app instead,
with a nonce given only to that ssh, for that host, for two minutes, and never for a jump host's
prompt. The socket is in `$TMPDIR/bridge-run`, which sandboxes can't write: they can connect (their
shells report there) but can't move it aside and listen in its place.

**What sandboxes report isn't trusted.** Commands a sandboxed shell reports go into the history
marked as such and are never suggested in open terminals; completions in a sandbox never list a
folder it can't read; programs in a sandbox can't set the clipboard or open anything but web
links; git run by the app never runs hooks, fsmonitor or a pager from the repository.

**A sandbox fix carried over from v1.** Seatbelt lets a more specific operation win over a
wildcard whatever the order, so `deny file-read*` didn't hide a path inside a folder allowed by
`allow file-read-data`. Hidden paths now deny `file-read-data` by name.

## Changed after the 2026 review

These replace the v1 notes below where they disagree.

**⌘T is a sandboxed shell, right away.** The idea of the app is that a terminal in a project is
sandboxed, so the quickest way to get one is to press ⌘T. Every other kind (open shells, tasks,
SSH, other sandboxes) is made with New Terminal… (⌘⇧T). A new project starts with a sandboxed
shell instead of an empty window.

**Terminals keep running when you switch away.** That is what every terminal does; "Stop when
hidden" is a terminal's own choice (Keep Alive off), not the default.

**⌘W closes the terminal, ⌘Z brings it back.** Closing asks only when a program is busy.

**The shell stays the user's.** Bridge's prompt, Tab completion and ⌃R history are offered, not
imposed: the shell's own prompt and Tab by default, and ⌃R goes to Bridge's history only when the
shell has no ⌃R of its own (fzf, atuin and the like).

**Shared things live in Settings.** SSH hosts, sandboxes and Vaultwarden are Settings pages, where
Mac users look for them. The Global window is now Home: terminals in the home folder.

**"…" when more is asked.** Menu items and buttons that open a sheet end in "…", as on every Mac.

**A sandbox says what it refused.** Every deny rule carries the terminal's marker; the app reads
denials from the system log and shows them on that terminal, with a way forward (allow the path,
or open an unsandboxed terminal there). Paths every sandbox hides can't be allowed.

## Sandbox rules in v2

**Policies on the command line.** The policy is passed to `sandbox-exec -p` (through
`bridge-helper sandbox`, which puts the terminal's own tty into it), never written to a file a
sandboxed program could replace before the next start.

**Temporary files of its own.** Each sandboxed terminal gets its own `TMPDIR`; `/tmp` stays
writable (local databases keep sockets there), but not the rest of `/var/folders`, where other
programs and the app keep their temporary files and sockets.

**Caches of its own for runnable code.** Go, Cargo, pip, uv, pre-commit and other tools that keep
code they run later get per-project caches (`~/Library/Caches/Bridge/Sandboxes`), so a sandbox
can't plant something a build outside it would run.

**Never writable, whatever the profile.** Shell startup files and completion dumps, LaunchAgents,
`~/.local/bin`, `~/.cargo/bin`, agents' hooks, commands and settings, git hooks and config, and the
links between a worktree and its repository: everything a program outside the sandbox runs or
follows later. **Never readable:** the app's records, shell histories, other projects' caches and
credential files.

**Sockets by allowlist.** The project, the terminal's own folders, `/tmp` (minus launchd's
ssh-agent, tmux and X11) and `/var/run` (minus launchd's ssh-agent); the app's socket by exact path.

**Agents preset.** Claude Code, Codex and Gemini get a preset with their state folders writable,
the Keychain (Claude Code keeps its login there) and opening a browser to sign in. Their hooks and
settings stay read-only.

## v1

## The product

**A window per project.** A project is a folder, opened in a window of its own, once. The Global
window is like a project window for your home folder: terminals that belong to no project, next to
the presets every project shares. Its terminals are open, since a sandbox around the whole home
folder protects little. A project window shows only that project. The app
keeps running with no window open, so port forwards stay up, and it reopens the windows you had.

**Projects, not groups of tabs.** The app is organised around project folders. A project holds
terminals and views (grids of terminals). This matches how work actually happens: one repo, a few
dev servers, an agent and a couple of shells to check on it.

**A terminal until it has company.** Most of the time you want one terminal, so that is what a
project's item is: no header, no close button, its controls in the title bar. Adding a terminal
beside it makes it a view, and only then does each terminal get a header to select, drag and close
it by. Deleting a terminal is done from the sidebar.

**Drag to arrange, like Zed.** Dropping a terminal on another one's edge splits it there; the
middle swaps them. A highlight shows where it will land before you let go. The focused terminal is
marked by an accent-tinted header rather than a border, which would get in the way of the split
handles.

**Three terminal types, fixed at creation.** Shell, Task (one long-running command) and SSH. The
type is chosen when a terminal is created and cannot be changed later; delete it and create another
instead. This keeps each terminal simple and predictable.

**No default terminals.** New projects start empty. You decide what runs.

**Nothing runs until you open it.** A terminal starts when it is opened, tasks wait for ▶ unless
set to start automatically, and switching away stops what is not marked to keep running in the
background (after asking). This keeps memory and processes low.

**Global presets.** SSH hosts, port forwards, sandbox profiles and Vaultwarden live in the Global
window and are shared by every project, so they are set up once.

## Sandboxing

**Sandboxed by default, open on purpose.** Agents can read anything they are given, so project
terminals are sandboxed unless you choose otherwise. Open terminals are clearly marked.

**macOS's own sandbox (Seatbelt).** It is built in, light, and used by Claude Code and Codex. The
kernel enforces the rules on every file access and system service request, for every program and
everything it starts. A program cannot turn it off from inside.

**Rules on files and services, not on commands.** Blocking commands is not reliable — an agent can
write a script or use another tool. So the protection is about paths and services: what can be read,
what can be written, what can be reached. (A "blocked programs" list exists, but only as a
deterrent.)

**Reads are confined too.** A sandboxed terminal can read the project, system folders and your
shell's and toolchains' setup — nothing else. Whether a path exists stays visible (tools look paths
up all the time); contents and folder listings do not. Toolchain folders are found automatically
from your shell startup files and PATH, so your tools keep working without manual setup.

**Side channels are closed.** Other programs and services are not sandboxed, so a sandboxed program
could ask them to do the work. The sandbox refuses: the Keychain, the clipboard, Spotlight,
scripting other apps, opening apps, your ssh-agent, and Docker. Clipboard access and opening apps
can be allowed per profile; the rest cannot.

**Docker stays out of the sandbox.** The Docker engine runs with full access and can start anything.
Letting a sandboxed program reach it would undo the sandbox (for example, by starting a container
that mounts your home folder). Docker work belongs in open terminals.

**Separate history for sandboxed shells.** Your shell history can contain secrets, so sandboxed
shells cannot read it. Each project's sandboxed shells keep their own history instead.

**The app's own files are always off limits.** Whatever a profile says, a sandbox cannot read the
app's records: SSH hosts, the vault account, command history, projects and settings.

**Known limit.** An agent can edit project files, and open terminals run project files. Review
changes before re-running open tasks.

## SSH and secrets

**System OpenSSH.** Using the `ssh` already on the Mac means `~/.ssh/config`, known hosts and agents
just work, and we don't maintain our own SSH code.

**Passwords in the Keychain.** Encrypted by macOS and never in the app's files. The app's own binary
answers ssh's password prompt from the Keychain, and passes any other prompt to you.

**Vaultwarden through a built-in client.** The app talks to the server itself, decrypts only the SSH
keys, and loads them into a private ssh-agent. Keys stay in memory; only the server address and
email are saved. Locking stops the agent.

**One connection per port forward.** Each forward can be switched on and off on its own. A small
guard process makes sure no connection (or the vault's agent) outlives the app, even if it crashes.

**SSH servers need their own limits.** The Mac's sandbox cannot reach a remote server. Give agents
a limited account on each server, with its own key.

## Look and feel

**A real Mac app.** Built with `scripts/bundle.sh` it is a normal `.app` with its name and menus in
the menu bar, several windows, and the usual Mac behavior when the last one closes.

**Plain labels.** Buttons and menu items say what they do. (v2 adds "…" where more is asked.)

**Theme from the terminal colours.** The window's colours are derived from the terminal's colour
scheme, so every scheme gives a matching app. Only the terminal is solid; the rest is one surface.

**Short animations.** Animations use the theme's timing (about 120–180ms). They should be felt, not
waited for.

**Box and block characters are drawn, not taken from the font.** Fonts rarely fill the cell exactly,
which breaks logos and box borders (Claude Code's, for one). Drawing them like Ghostty and kitty do
keeps them seamless.

**Tried and dropped: the glass effect.** macOS's window blur did not look right, and Liquid Glass is
not available to gpui apps.

## Next

**Agent connectors.** Coding agents (Claude Code, Codex and others) should be able to ask Bridge
to run things instead of being given access themselves: run a command in a project's sandbox, or
connect to an SSH host and run a command there. Bridge holds the keys and makes the connection;
the agent only gets the output. Every command shows up in a terminal you can watch, and what an
agent may do is set per project. This will most likely be an MCP server built into the app.
