# Conduit

Conduit is a native macOS work surface for operating **MainFrame** through the CLI agents already installed on your computer.

It is deliberately a personal daily driver before it becomes an orchestration platform. The current app gives MainFrame a focused desktop face without replacing its file tree, its evidence rules, or the native agent CLIs underneath it.

## Daily loop

1. Choose a MainFrame root.
2. Select the root workspace or a project discovered under `30_projects/`.
3. Launch or reconnect to Claude, Codex, Gemini, OpenCode, or a normal shell in a real pseudo-terminal.
4. Compose multiline prompts, dictate them, paste screenshots, capture a screen region, or attach files and folders.
5. Build a labeled context bundle from project coordination files.
6. Forward selected terminal output to another agent with an explicit verification boundary.
7. Close the work session and write an append-only receipt under `20_live/conduit/sessions/`.

## Current features

### Agent workspace

- MainFrame root autodetection plus a security-scoped folder picker. If macOS
  invalidates access after a rebuild, Conduit shows an explicit recovery step
  instead of freezing during project discovery.
- Searchable project discovery from `30_projects/*/README.md`, grouped by
  explicit lifecycle state without inventing a second inventory
- Real PTY terminals powered by SwiftTerm
- Configurable CLI agent profiles
- Multiple project-scoped terminal tabs
- Durable tmux sessions created detached and out-of-band, with deterministic project-and-agent names
- Reconnection to an existing tmux session by launching the same agent again; deterministic detach via `tmux detach-client`
- Paste-semantics prompt delivery (bracketed paste aware) queued until the agent produces output
- Compact Codex and Claude character sprites inside session controls, with
  deterministic pose changes driven only by observed terminal state
- An explicitly generic pixel character for Shell, Gemini, OpenCode, and custom
  profiles without copied identity art

### Rich input

- Multiline composer with `⌘↩` send
- macOS speech-to-text with editable transcription
- Clipboard image paste and native region screenshot capture
- Drag-and-drop and file/folder attachments
- Copied terminal selection forwarding between agents
- Automatic warning that forwarded terminal prose is unverified

### MainFrame continuity

- Project goal, next action, state, and README context panel
- Previewable context bundles with per-file trust labels
- Provenance-bearing `00_inbox` capture
- Evidence-aware work-session receipts containing objective, observed exit codes, detached state, Git branch/status, and operator notes
- Event-sourced session logs with crash recovery: interrupted sessions render into receipts marked with a recovery note on next launch
- One concurrent work session per project; switching projects never discards one
- Collision-safe append-only writes

### Local operations

- Conduit Doctor for CLI paths, versions, MainFrame structure, tmux, microphone, and speech permissions
- Resource Deck for memory use, largest processes, loaded Ollama models, and one-click Ollama unloading
- Native settings stored in `~/.conduit/config.json`

## Requirements

- macOS 13 or newer
- Xcode 15 or newer for source builds
- Your preferred agent CLIs installed and authenticated separately
- A local MainFrame tree containing `00_inbox/`, `20_live/`, and `30_projects/`
- `tmux` is optional but recommended for durable sessions, for example `brew install tmux`

## Build and run

```bash
swift test                    # full suite (requires Xcode)
swift run conduit-selftest    # dependency-free core checks (works with Command Line Tools)
swift run Conduit
```

To produce a normal `.app` bundle:

```bash
./scripts/build-app.sh
open dist/Conduit.app
```

The packaging script copies SwiftPM resource bundles into
`Contents/Resources`, signs the complete app bundle with its local bundle
identifier, and verifies the result. The installed app does not read sprite
assets from another MainFrame project at runtime.

The first MainFrame selection grants persistent access to that folder. The
first speech-to-text use prompts for microphone and speech-recognition access.
The app must remain unsandboxed because its purpose is to launch local shells
and access your chosen MainFrame tree.

## MainFrame compatibility

Conduit follows the public MainFrame contract rather than any private project inventory:

- The file tree remains the source of truth.
- `00_inbox` is fast, temporary capture.
- `20_live` contains volatile operational state and Conduit session receipts.
- `30_projects` contains outcome-oriented workspaces.
- Project README frontmatter supplies `title`, `project_state`, `goal`, and `next_action`.
- Captures and receipts append new files and preserve provenance.
- Retrieved or displayed context is context for inspection, not verification.
- Terminal output is never promoted into completion evidence merely because an agent said it was done.

See [`DECISIONS.md`](DECISIONS.md) (public product ADRs), [`docs/MASTER_PLAN.md`](docs/MASTER_PLAN.md), and [`docs/DAILY_DRIVER_PASS.md`](docs/DAILY_DRIVER_PASS.md).

## Status

The repository contains the complete application source, core tests, macOS CI, and a packaged Apple-silicon application artifact on successful pull-request runs. Hardware permissions, installed CLIs, and private MainFrame paths still require a local smoke test.
