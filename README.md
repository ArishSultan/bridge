# Bridge

A macOS workspace for your projects, servers and terminals. Open a project folder in its own
window, arrange its terminals, run tasks and agents in sandboxed terminals that can only see that
project, and keep SSH hosts and port forwards in one place.

Built in Rust with [gpui](https://www.gpui.rs), gpui-component and libghostty-vt.

```sh
./scripts/bundle.sh      # builds target/release/bundle/Bridge.app (Apple Silicon)
cp -R target/release/bundle/Bridge.app /Applications/
```

Run it as an app like this, so macOS shows its name and menus in the menu bar and it gets its own
place in the Dock. `cargo run --release` also works for quick tries. Building needs Rust and
[Zig 0.15](https://ziglang.org/download/) (`brew install zig`), which builds Ghostty's terminal core.

## Releases

Releases are made by GitHub Actions on GitHub's free macOS runners:

- **CI** (`.github/workflows/ci.yml`) checks formatting, runs Clippy and the tests on every push
  and pull request.
- **Release** (`.github/workflows/release.yml`) uses
  [release-please](https://github.com/googleapis/release-please). Write commit messages as
  [Conventional Commits](https://www.conventionalcommits.org): `feat: …` (new version's minor
  number), `fix: …` (patch), `feat!: …` (breaking). Each push to `main` keeps a "Release v…" pull
  request up to date with the next version and its `CHANGELOG.md` entry. Merging it tags the
  commit, publishes the GitHub release, and attaches an Apple Silicon
  `Bridge-<version>-macos-arm64.dmg` and `.zip` with `SHA256SUMS.txt`.
- To rebuild the files of an existing release, run the Release workflow by hand with its tag.

Releases are ad-hoc signed but not notarized (no Apple Developer certificate), so macOS blocks
the app the first time. Run `xattr -dr com.apple.quarantine /Applications/Bridge.app`, or try
to open it once and click **Open Anyway** in System Settings → Privacy & Security.

Once per repository: in Settings → Actions → General, turn on **Allow GitHub Actions to create and
approve pull requests**. Pull requests opened by release-please don't start CI unless you add a
fine-grained token (contents and pull requests: read and write) as the `RELEASE_PLEASE_TOKEN`
secret.

## Windows

- **A window per project.** Open a folder (⌘O, or File → Open Folder) and it becomes a project in
  a window of its own. Opening it again brings that window to the front: one window per project.
- **The Global window** (⌘⇧G, or the globe in a project's title bar) is for everything outside a
  project: terminals in your home folder (shells, tasks, SSH sessions; these are always open, not
  sandboxed), and what every project shares: SSH hosts, port forwards, sandbox profiles and
  Vaultwarden. There is only ever one.
- A window's title is just its project's name; the menu bar already says Bridge.
- **The Welcome window** shows when nothing else is open: recent projects, Open Folder and Global.
- The app reopens the windows that were open when you quit.
- Closing the last window does not quit. Port forwards and anything else running keep going, and
  clicking the Dock icon brings the Welcome window back. ⌘Q quits.
- Closing a project window while its terminals run asks first; closing it stops them.

### Projects, views and terminals

- A **project** is a folder you pick. Nothing else to set up.
- A project holds **terminals**. Each one is listed in its window's sidebar and fills the
  window when selected, with no header of its own; its controls sit in the title bar.
- Add a terminal beside one (⌘D / ⌘⇧D) and it becomes a **view**: a grid of terminals, for
  example "Dev servers" or "Claude". In a view each terminal gets a header, and can be resized,
  renamed, tagged and closed (right-click the header for more). Drag a header onto another
  terminal: drop it on an edge to split there (the landing spot is highlighted), or in the middle
  to swap the two. Close all but one and it is a terminal again.
- A **terminal** is one of three types, chosen when you create it (and fixed after that):
  - **Shell** — your normal shell.
  - **Task** — bound to one command, like `npx nx serve api`. Start, stop and restart it from its
    header. When it stops you see its output, not a shell prompt.
  - **SSH** — a session to one of the SSH hosts in the Global window.

New projects start empty. You create every terminal yourself, and delete one from the sidebar
(right-click).

### What runs, and when

- A terminal (or a view's terminals) only starts when you open it. What you don't open costs
  nothing.
- Tasks wait for ▶ unless you set them to start when opened.
- **Keep alive** (in the terminal's settings, or right-click it) lets a terminal keep running when
  you switch to another terminal or view. Otherwise switching away stops it — the app asks first.
- Closing or deleting a running terminal also asks first.

## Sandboxed and open terminals

Every project terminal is **sandboxed** by default. An **open** terminal is not, and is marked with
an amber edge and an "open" tag.

A sandboxed terminal, and every program it starts:

- can read and change the project folder;
- can read the system folders tools need and your shell's and toolchains' setup (found
  automatically from your shell startup files and PATH);
- **cannot read or list** anything else: other projects, your home folder, `~/.ssh`, your shell
  history;
- **cannot reach** the Keychain, the clipboard, Spotlight, other apps, your ssh-agent, or Docker;
- keeps its own shell history per project.

This uses macOS's own sandbox (Seatbelt), the same one Claude Code and Codex use. The rules are on
files and system services and the kernel enforces them, so it does not matter which program or
script tries — a script an agent writes gets the same answer as `cat`.

Pasting with ⌘V still works in a sandboxed terminal: the app types the text in for you.

**Use open terminals for** Docker (`docker compose up`), SSH, deploys, and tools that log in
through a browser. Docker in particular can never be allowed inside a sandbox: the Docker engine
can run anything with full access, so reaching it would undo the sandbox.

**One habit:** an agent can edit files in the project, and open terminals run things from the
project. Check what changed (`git diff`) before re-running open tasks after an agent session,
especially compose files, scripts and `package.json`.

Sandbox profiles are edited in the Global window. The built-in **Project** profile is the
default. A profile can also be a **Docker** container that only sees the project folder.

## SSH, port forwards and Vaultwarden

- **SSH hosts** are registered once in the Global window (name, address, user, how to sign in) and used in any
  project. The app uses your system `ssh`, so `~/.ssh/config` and known hosts keep working.
- **Passwords** are saved in the macOS Keychain, never in the app's files.
- **Port forwards** belong to a host. Each one has its own switch, status dot and optional log, and
  runs as its own connection. When a connection drops, the host's setting decides: do nothing,
  notify you, or reconnect (waiting a little longer each time).
- **Vaultwarden**: unlock your vault and its SSH keys are loaded into a private ssh-agent, in
  memory only. Locking (by hand, after an idle time, or on quit) removes them. The server is your
  own: type its address when you link it (`vault.example.com`, `https://example.com/vault` behind a
  reverse proxy, or `http://192.168.1.10:8080` on your network), and change it in the same dialog
  from the lock button. A server whose certificate comes from your own CA works once macOS trusts
  that CA (add it to Keychain Access).
- SSH terminals are always open on your Mac, since they need your keys. On the server, an agent
  can only do what that server account allows — use a limited account per server for agents.

## Where things are saved

All in `~/.config/bridge/` (moved there from `~/.config/gpu-terminal/` the first time Bridge runs):

| File | What |
|---|---|
| `settings.json` | App settings |
| `projects.json` | Projects, their terminals and views, and which windows were open |
| `profiles.json` | SSH hosts, port forwards, sandbox profiles, the Vaultwarden server and email |
| `history.jsonl` | Command history (for search and suggestions) |
| `sandbox-history/` | Each project's sandboxed shell history |
| `icons/` | Custom project icons |
| `shell/` | Shell integration scripts the app writes |

Passwords are in the Keychain. Vault keys are never written anywhere. Sandboxed terminals can never
read `profiles.json`, `history.jsonl`, `projects.json` or `settings.json`, whatever their profile says.

## Shortcuts

| Keys | What |
|---|---|
| ⌘T / ⌘⇧T | New terminal in the project (sandboxed / open shell preselected) |
| ⌘⇧E | New task |
| ⌘O | Open a folder as a project |
| ⌘⇧G | Global window |
| ⌘D / ⌘⇧D | Add a terminal to the right / below (makes a view) |
| ⌘W | Close a terminal of a view, else the window |
| ⌘] / ⌘[ | Next / previous terminal of a view |
| ⌃Tab, ⌘⇧] / ⌘⇧[ | Next / previous terminal or view of the project |
| ⌘1 … ⌘9 | Go to a terminal or view of the project |
| ⌘B | Show / hide the sidebar |
| ⌘, | Settings |
| ⌃R | Command history |

See [docs/decisions.md](docs/decisions.md) for why things work the way they do.
