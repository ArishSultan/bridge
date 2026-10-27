# Bridge

A macOS workspace for your projects, servers and terminals.

This is **Bridge v2**, rewritten from scratch in Swift. SwiftUI and AppKit draw the window, and
[libghostty](https://github.com/ghostty-org/ghostty) (the core of the Ghostty terminal) runs every
terminal. v1 (Rust, gpui) lives on the `main` branch.

## What's in it

Everything v1 did, on native macOS components:

- **Terminals** rendered on the GPU by libghostty's Metal renderer, each with its own pty, I/O
  thread and renderer thread, so one flooding output doesn't slow the others or the UI.
- **Projects** (folders) in windows of their own, with terminals and views (split layouts) in
  the sidebar; panes rearranged by dragging their headers; shells, tasks (start, stop, restart,
  restart on exit) and SSH sessions; keep-alive; the git branch menu with worktrees; the Global
  and Welcome windows; windows reopened at launch. Uses v1's `projects.json`.
- **Sandboxed terminals**: macOS's sandbox (Seatbelt) with v1's policies, or Docker; profiles
  edited in the Global window; New Claude Terminal (⌘⌥C).
- **SSH hosts and port forwards** in the Global window: the system ssh, saved passwords in the
  Keychain, forwards supervised with reconnects and logs.
- **Vaultwarden**: unlock your own server and its SSH keys go into a private ssh-agent, in memory
  only, until it locks.
- **Shell integration** for zsh and bash (v1's prompt styles and Starship), command history
  (⌃R), attention for the bell, long commands and finished tasks, with notifications and the
  Dock badge.
- **Suggestions and completions** in zsh: gray history suggestions (→ accepts) and a completion
  menu at the cursor (Tab).
- v1's settings, color schemes and deep dark look. Settings, projects, profiles and history
  are the same files v1 uses, in `~/.config/bridge/`.

Requires macOS 26 on Apple Silicon.

## Building

Needs Xcode (with its Metal toolchain) and [Zig 0.15.2](https://ziglang.org/download/)
(`brew install zig@0.15`).

```sh
git submodule update --init
xcodebuild -downloadComponent MetalToolchain   # once, if Xcode doesn't have it yet
./scripts/build-ghostty.sh   # builds libghostty into vendor/ (a few minutes, once)
./scripts/bundle.sh          # builds build/Bridge.app (Apple Silicon)
cp -R build/Bridge.app /Applications/
```

`swift build` and `swift test` work for development; `swift run Bridge` starts the app from the
build folder.

### Layout

| Path | What |
|---|---|
| `Sources/BridgeCore` | Plain Swift logic, unit-tested: settings, projects and layouts, history, completions, shell integration scripts, sandbox policies, SSH commands, profiles. |
| `Sources/BridgeSystem` | Talking to the system: the shells' socket, the Keychain, Vaultwarden (client, crypto, ssh-agent). |
| `Sources/BridgeTerm` | The only code that calls libghostty's C API: the app with its callbacks, and `TerminalSurfaceView`, the AppKit view a terminal renders into. |
| `Sources/Bridge` | The SwiftUI app: windows, sidebar, panes, sheets, settings, port forwards. |
| `Sources/BridgeHelper` | `bridge-helper`, bundled in the app: messages from bash, SSH password prompts, and the guard that ends child processes with the app. |
| `Sources/CArgon2` | The Argon2 reference implementation, for Vaultwarden. |
| `vendor/ghostty` | Ghostty, pinned to a release as a submodule. |
| `patches/ghostty` | Fixes from newer Ghostty the pinned release needs, applied by the build script. |

## Shortcuts

| Keys | What |
|---|---|
| ⌘T / ⌘⇧T | New terminal (sandboxed / open) |
| ⌘⇧E / ⌘⌥C | New task / New Claude terminal |
| ⌘O / ⌘⇧G | Open a folder as a project / the Global window |
| ⌘D / ⌘⇧D | Add a terminal to the right / below (makes a view) |
| ⌘W / ⌘⇧W | Close a terminal of a view / the window |
| ⌘] / ⌘[ | Next / previous terminal of a view |
| ⌃Tab, ⌘⇧] / ⌘⇧[ | Next / previous item |
| ⌘1 … ⌘9 | Go to an item |
| ⌘B | Show or hide the sidebar |
| ⌃R | Command history |
| ⌘+ / ⌘- / ⌘0, ⌘K | Font size, clear |
| ⌘, | Settings |

## Releases

- **CI** (`.github/workflows/ci.yml`) builds and runs the tests on every push and pull request.
  libghostty is cached between runs and only rebuilt when the submodule or its patches change.
- **Release** (`.github/workflows/release.yml`) uses
  [release-please](https://github.com/googleapis/release-please) with
  [Conventional Commits](https://www.conventionalcommits.org): `feat: …` (minor), `fix: …`
  (patch), `feat!: …` (breaking). Merging its "Release v…" pull request tags the commit, publishes
  the release and attaches `Bridge-<version>-macos-arm64.dmg` and `.zip` with `SHA256SUMS.txt`.
  The version is in `version.txt`.

Releases are ad-hoc signed but not notarized, so macOS blocks the app the first time. Run
`xattr -dr com.apple.quarantine /Applications/Bridge.app`, or try to open it once and click
**Open Anyway** in System Settings → Privacy & Security.

See [docs/decisions.md](docs/decisions.md) for why things work the way they do.
