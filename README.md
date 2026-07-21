# Conduit

Conduit is a native macOS work surface for operating **MainFrame** through the CLI agents already installed on your computer.

It is deliberately not an orchestration platform. Version 0.1 focuses on the daily loop:

1. Choose a MainFrame root.
2. Select the root workspace or a project discovered under `30_projects/`.
3. Launch Claude, Codex, Gemini, OpenCode, or a normal shell in a real pseudo-terminal.
4. Compose multiline prompts, dictate them, paste screenshots, capture a screen region, or attach files and folders.
5. Inspect the project README beside the terminal.
6. Capture unfinished thoughts directly into `00_inbox/` without silently overwriting history.

## Current features

- MainFrame root autodetection plus folder picker
- Lifecycle-aware project discovery from `30_projects/*/README.md`
- Real PTY terminals powered by SwiftTerm
- Configurable CLI agent profiles
- Multiple project-scoped terminal tabs
- Rich multiline composer with `⌘↩` send
- macOS speech-to-text with editable transcription
- Clipboard image paste and native region screenshot capture
- Drag-and-drop and file/folder attachments
- Project goal, next action, state, and README context panel
- Provenance-bearing `00_inbox` capture
- Native settings stored in `~/.conduit/config.json`

## Requirements

- macOS 13 or newer
- Xcode 15 or newer
- Your preferred agent CLIs installed and authenticated separately
- A local MainFrame tree containing at least `00_inbox/` and `30_projects/`

## Build and run

```bash
swift test
swift run Conduit
```

To produce a normal `.app` bundle:

```bash
./scripts/build-app.sh
open dist/Conduit.app
```

The first speech-to-text use prompts for microphone and speech-recognition access. The app must remain unsandboxed because its purpose is to launch local shells and access your chosen MainFrame tree.

## MainFrame compatibility

Conduit follows the public MainFrame contract rather than any private project inventory:

- The file tree remains the source of truth.
- `00_inbox` is fast, temporary capture.
- `30_projects` contains outcome-oriented workspaces.
- Project README frontmatter supplies `title`, `project_state`, `goal`, and `next_action`.
- Captures append new files and preserve provenance.
- Retrieved or displayed context is context for inspection, not verification.

See [`docs/MASTER_PLAN.md`](docs/MASTER_PLAN.md).

## Status

This repository contains the complete 0.1 application source and tests. The macOS CI workflow is the authoritative compile check because the app depends on AppKit, Speech, AVFoundation, and SwiftTerm's macOS PTY view.
