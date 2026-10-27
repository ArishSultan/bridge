# Bridge

**Terminals your coding agents can't escape.** Bridge is a Mac app where every terminal in a
project is sandboxed by macOS itself: Claude Code, Codex or any script can change the project, but
can't read your SSH keys, your other repositories or the Keychain. Your SSH hosts, port forwards
and Vaultwarden keys live in the same app, set up once.

**[Download for Mac](https://github.com/ArishSultan/bridge/releases/latest)** · Apple Silicon ·
macOS 15 or later · free and open source (MIT)

```text
~/code/app % cat ~/.ssh/id_ed25519
cat: /Users/me/.ssh/id_ed25519: Operation not permitted        ✋ cat couldn't read ~/.ssh/id_ed25519
```

## Why Bridge

| | Bridge | Terminal, iTerm2, Ghostty, Warp |
|---|---|---|
| Agents and scripts confined to the project | Every project terminal, by default | No |
| Credentials, shell history, other repos | Hidden from sandboxed programs | Readable by anything you run |
| What the sandbox refused | Shown on the terminal, with a fix | — |
| SSH hosts, port forwards with reconnects | Built in | Separate tools |
| SSH keys from your own Vaultwarden | Loaded in memory while unlocked | — |
| Terminal engine | Ghostty's (GPU-rendered) | Varies |

## How it works

- **Open a folder** (⌘O) and it becomes a project, in a window of its own.
- **⌘T** opens a sandboxed shell in it right away. **⌘⇧T** makes any other kind: an *open*
  (unsandboxed) shell for SSH, Docker and deploys, a task like `npm run dev`, an SSH session, or a
  terminal in another sandbox profile.
- **⌘⌥C** starts Claude Code in the Agents sandbox (File → New Agent Terminal also has Codex and
  Gemini).
- **Splits**: ⌘D and ⌘⇧D add a terminal beside the one you're in; drag a terminal's header to
  rearrange.
- When the sandbox refuses something, the terminal shows what, with *Allow* and *Open Terminal
  Instead*. See [how sandboxed terminals work](docs/sandbox.md) for exactly what is and isn't allowed.
- **Settings** (⌘,) hold SSH hosts (import them from `~/.ssh/config`), port forwards, sandbox
  profiles and Vaultwarden. **Home** (⌘⇧H) has terminals in your home folder, outside any project.

Your shell stays yours: your prompt, your Tab completion, your ⌃R (Bridge's history, suggestions and
prompt styles are there when you turn them on in Settings).

## Install

Download the `.dmg` from the [latest release](https://github.com/ArishSultan/bridge/releases/latest),
open it and drag Bridge to Applications. Bridge updates itself. Each release lists how to check
where a download came from (`gh attestation verify`).

Release builds that aren't notarized yet need one extra step the first time: open Bridge once, then
click **Open Anyway** in System Settings → Privacy & Security.

## Shortcuts

| Keys | What |
|---|---|
| ⌘T / ⌘⇧T | New sandboxed terminal / new terminal of any kind |
| ⌘⇧E / ⌘⌥C | New task / new Claude Code terminal |
| ⌘D / ⌘⇧D | Split right / down |
| ⌘W / ⌘⇧W | Close the terminal (⌘Z brings it back) / the window |
| ⌘] / ⌘[ | Next / previous pane of a split |
| ⌃Tab, ⌘⇧] / ⌘⇧[ | Next / previous in the sidebar |
| ⌘1 … ⌘9 | Go to a terminal in the sidebar |
| ⌘F, ⌘G / ⌘⇧G | Find in the scrollback, next / previous match |
| ⌘K | Clear the scrollback |
| ⌘+ / ⌘- / ⌘0 | Font size |
| ⌘O / ⌘⇧H | Open a folder / the Home window |
| ⌃⌘S | Show or hide the sidebar |
| ⌘, | Settings |

## Where things are kept

| Where | What |
|---|---|
| `~/Library/Application Support/Bridge` | Settings, projects, SSH hosts, sandboxes, the Vaultwarden account and command history (SwiftData) |
| Keychain | Saved SSH passwords |
| Memory only | Vaultwarden keys, while unlocked |
| `~/.config/bridge` | Shell integration scripts, sandboxed shells' own histories, project icons |

No sandbox can read the first or the last. v1's JSON files in `~/.config/bridge` are read once, the
first time this version starts.

## Building and contributing

See [CONTRIBUTING.md](CONTRIBUTING.md), and [docs/decisions.md](docs/decisions.md) for why things
work the way they do. Bridge is MIT licensed; it embeds [libghostty](https://github.com/ghostty-org/ghostty)
(MIT) and [Sparkle](https://sparkle-project.org) (MIT).
