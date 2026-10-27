# Contributing

This is **Bridge v2**, written in Swift: SwiftUI and AppKit draw the windows, and
[libghostty](https://github.com/ghostty-org/ghostty) (the core of the Ghostty terminal) runs every
terminal. v1 (Rust, gpui) is on the `main` branch's history.

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

## Layout

| Path | What |
|---|---|
| `Sources/BridgeCore` | Plain Swift logic, unit-tested: settings, projects and layouts, history, completions, shell integration scripts, sandbox policies, SSH commands, profiles. |
| `Sources/BridgeSystem` | Talking to the system: the data store (SwiftData), the shells' socket, the Keychain, Vaultwarden (client, crypto, ssh-agent). |
| `Sources/BridgeTerm` | The only code that calls libghostty's C API: the app with its callbacks, and `TerminalSurfaceView`, the AppKit view a terminal renders into. |
| `Sources/Bridge` | The SwiftUI app: windows, sidebar, panes, sheets, settings, port forwards, updates. |
| `Sources/BridgeHelper` | `bridge-helper`, bundled in the app: starting sandboxes, messages from bash, SSH password prompts, and the guard that ends child processes with the app. |
| `Sources/CArgon2` | The Argon2 reference implementation (CC0 / Apache-2.0), for Vaultwarden. |
| `vendor/ghostty` | Ghostty, pinned to a release as a submodule. |
| `patches/ghostty` | Fixes the pinned release needs, applied by the build script. |
| `packaging/homebrew` | A Homebrew cask to put in a tap. |

## Commits and releases

Write commit messages as [Conventional Commits](https://www.conventionalcommits.org): `feat: …`
(new minor version), `fix: …` (patch), `feat!: …` (breaking).

- **CI** (`.github/workflows/ci.yml`) builds and runs the tests on every push and pull request.
  libghostty is cached between runs and only rebuilt when the submodule or its patches change.
- **Release** (`.github/workflows/release.yml`) uses
  [release-please](https://github.com/googleapis/release-please). Each push to `main` keeps a
  "Release v…" pull request up to date with the next version (`version.txt`) and its
  `CHANGELOG.md` entry. Merging it tags the commit, publishes the release, and attaches
  `Bridge-<version>-macos-arm64.dmg` and `.zip`, `SHA256SUMS.txt`, a build provenance attestation
  and Sparkle's `appcast.xml`.

Once per repository: in Settings → Actions → General, turn on **Allow GitHub Actions to create and
approve pull requests**, and add the secrets the workflow describes at its top:

- **Signing and notarization** (so macOS opens the app without warnings): `DEVELOPER_ID_P12`,
  `DEVELOPER_ID_P12_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`. These need an
  Apple Developer Program membership.
- **Updates**: run `.build/artifacts/sparkle/Sparkle/bin/generate_keys` once (it keeps the private
  key in your Keychain), export it with `generate_keys -x key.txt` into the `SPARKLE_PRIVATE_KEY`
  secret, and put the public key it prints into the `SPARKLE_PUBLIC_KEY` repository variable.
  Without them, releases don't update themselves.
- Optionally `RELEASE_PLEASE_TOKEN`, a fine-grained token (contents and pull requests: read and
  write), so release pull requests start CI.

To rebuild the files of an existing release, run the Release workflow by hand with its tag.
