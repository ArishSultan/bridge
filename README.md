# Bridge

A macOS workspace for your projects, servers and terminals.

This is **Bridge v2**, rewritten from scratch in Swift. SwiftUI and AppKit draw the window, and
[libghostty](https://github.com/ghostty-org/ghostty) (the core of the Ghostty terminal) runs every
terminal. v1 (Rust, gpui) lives on the `main` branch.

## Status

The first milestone is the terminal itself:

- Terminals rendered on the GPU by libghostty's Metal renderer. Each terminal has its own pty,
  I/O thread and renderer thread, synced to the display, so one flooding output (`yes`,
  `cat huge.log`) doesn't slow the others or the UI.
- Tabs and splits, with draggable dividers (double-click one to even it out) and zoom.
- The nine color schemes from v1, with the window chrome matched to the scheme.
- Settings applied live to every open terminal, saved to the same `~/.config/bridge/settings.json`
  as v1. Settings v2 doesn't use yet are kept in the file untouched.
- Shell integration (zsh, bash, fish, elvish) reports the working directory, which titles the
  tab and is where new tabs and splits start.
- Input methods (Japanese, Korean, Chinese), Option as Meta, clipboard prompts for pastes that could
  run commands.

Still to port from v1: projects and the Global and Welcome windows, SSH hosts and port forwards,
Vaultwarden, sandboxed terminals, and command history and completions.

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
| `Sources/BridgeCore` | Plain Swift models: settings, color schemes, the split tree, and the mapping from settings to libghostty's config. Tested. |
| `Sources/BridgeTerm` | The only code that calls libghostty's C API: the app with its callbacks, and `TerminalSurfaceView`, the AppKit view a terminal renders into. |
| `Sources/Bridge` | The SwiftUI app: windows, tabs, split layout, settings. |
| `vendor/ghostty` | Ghostty, pinned to a release as a submodule. |
| `patches/ghostty` | Fixes from newer Ghostty the pinned release needs, applied by the build script. |

## Shortcuts

Ghostty's macOS key bindings:

| Keys | What |
|---|---|
| ⌘N / ⌘T | New window / tab (in the current terminal's folder) |
| ⌘D / ⌘⇧D | Split right / down |
| ⌘W | Close the terminal (the tab and window close with their last one) |
| ⌘[ / ⌘] | Previous / next split |
| ⌘⌥ Arrow | Split in that direction |
| ⌘⇧↩ | Zoom the split in or out |
| ⌘⌃= | Even out splits |
| ⌘1 … ⌘9, ⌘⇧[ / ⌘⇧] | Go to a tab |
| ⌘+ / ⌘- / ⌘0 | Font size |
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
