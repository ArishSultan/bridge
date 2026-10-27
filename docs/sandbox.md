# How sandboxed terminals work

Every terminal you make in a project with ⌘T is **sandboxed**. Programs in it, and every program
they start (a coding agent, the scripts it writes, `npm install`'s postinstall scripts), run inside
macOS's own sandbox, Seatbelt. The kernel enforces the rules on every file and service, so it
doesn't matter which program tries.

## What a sandboxed terminal can do

- Read and change the **project folder**, and use its git repository (worktrees included).
- Read the system's programs and libraries, and your shell's and toolchains' setup (found from
  your shell startup files and `PATH`), so your tools work as usual.
- Write temporary files (`/tmp`, and a temporary folder of its own), npm's cache and the system's
  caches. Tools that keep code they run later (Go, Cargo, pip, uv, pre-commit) get caches of their
  own for the project.
- Use the network (unless the sandbox's profile says otherwise) and local databases' sockets in
  `/tmp`.
- Paste with ⌘V (Bridge types the text in for it).

## What it can't do

- **Read your other files**: other projects, Documents, Desktop, your home folder.
- **Read credentials**: `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.config/gh`, `~/.netrc`, Docker's and
  Cargo's logins, your shell history, and Bridge's own records (hosts, history, settings).
- **Change what runs outside it**: your shell startup files, `~/.local/bin` and `~/.cargo/bin`,
  LaunchAgents, coding agents' hooks and settings, the project's git hooks and git config.
- **Reach other programs**: the Keychain, your ssh-agent, Docker, tmux, Spotlight, scripting other
  apps, other terminals, the clipboard (it can't set it with escape codes either).

## When something is refused

The program sees "Operation not permitted". Bridge shows what was refused on the terminal (the
hand at its top right): "cat couldn't read ~/.ssh/config". From there you can:

- **Allow Reading** or **Allow Changes** for that path, in the terminal's sandbox profile (it takes
  effect when a terminal restarts). Credentials and the files listed above can't be allowed.
- **Open Terminal Instead**: a terminal in the same folder that isn't sandboxed.

## Open terminals

Make one with New Terminal… (⌘⇧T) and choose *Open*. It isn't sandboxed and is marked in orange.
Use open terminals for:

- `git push` and anything else that needs your SSH keys (SSH sessions are always open);
- Docker (`docker compose up`): the Docker engine can run anything with full access, so reaching it
  would undo the sandbox;
- deploys, and tools that sign in through a browser or the Keychain.

**One habit:** an agent in a sandboxed terminal can change the project's files, and an open terminal
runs them. Look at what changed (`git diff`) before running the project's scripts, compose files or
`package.json` tasks in an open terminal.

## Coding agents

File → New Agent Terminal starts Claude Code (⌘⌥C), Codex or Gemini in the **Agents** sandbox: the
Project sandbox, plus the agents' own state folders, the Keychain (Claude Code keeps its login
there) and opening a browser to sign in. Their hooks, commands and settings stay read-only, so an
agent can't make itself run something outside the sandbox later. The Home window has no project to
confine an agent to, so agents there aren't sandboxed.

## Profiles

Settings → Sandboxes lists the profiles. The built-in **Project** profile is the default; you can
edit it, make others (with other writable or hidden paths, no network, blocked programs) or use a
Docker container that only sees the project folder, and pick one per terminal.

## Limits

- The sandbox can't reach your servers. On an SSH host an agent can do what that account can, so
  give agents a limited account of their own on each server.
- `sandbox-exec` is marked deprecated by Apple, but it is what macOS itself, Claude Code and Codex
  use, and it is enforced by the kernel.
