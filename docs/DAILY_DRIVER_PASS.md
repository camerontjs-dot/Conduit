# Conduit daily-driver pass

## Goal

Make Conduit useful as Cameron's default MainFrame work surface without introducing autonomous orchestration or a second source of truth.

## Implemented additions

### Conduit Doctor

Checks configured CLI commands, reports resolved executable paths and versions, validates the public MainFrame lifecycle folders, detects tmux, and surfaces microphone and speech-recognition permission state.

A successful command-path check is not proof that the account is authenticated or that a provider service is available. It is a local readiness signal only.

### Durable sessions (tmux-first, rebuild pass 0.3)

When the setting is enabled and tmux is installed, Conduit creates the session **detached and out-of-band** (`tmux new-session -d`) with a deterministic name from the standardized project path and agent name, then attaches a SwiftTerm client to it. Launching the same agent in the same project focuses the existing tab, or reconnects to the surviving tmux session after an app restart. Closing a tab detaches via `tmux detach-client` — a real tmux command, never emulated prefix keystrokes, so any operator tmux configuration works.

When tmux is unavailable, the UI labels the session `PTY` and closing it terminates the process explicitly. Conduit does not pretend direct PTYs survived.

### Prompt delivery

Composer text and forwarded selections are delivered with paste semantics, not typing semantics: tmux sessions receive them through `load-buffer`/`paste-buffer -p` (bracketed paste when the agent requested it) plus one explicit Enter; direct PTYs get bracketed-paste wrapping when the foreground application enabled it. Multiline prompts arrive as one block. Delivery to a just-launched agent is queued until the session produces its first output — no timers, no lost prompts.

### Terminal-output forwarding

SwiftTerm selections use the normal macOS clipboard. Conduit can move copied output into the composer or launch another agent with the selection wrapped in an evidence boundary:

- terminal output is unverified
- actual files and repository state must be inspected
- deterministic checks should be rerun

### Work-session receipts (event-sourced, rebuild pass 0.3)

Launching the first agent in a project starts a work session for that project; each project keeps its own, so switching projects never discards one. Every observable fact is appended to a JSONL event log under `~/.conduit/worklog/` as it happens. Closing the work session renders the log into a new Markdown receipt under:

```text
20_live/conduit/sessions/
```

The receipt records timestamps, project provenance, active and detached session outcomes, observed exit codes, a Git snapshot, and operator notes. It does not claim task success. If Conduit crashes or is force-quit, the next launch renders the interrupted log into a receipt marked with a recovery note.

### Context bundles

Conduit nominates project files such as README, AGENTS, decisions, log, status, and recent plans. The operator selects sources and previews the exact bundle before attaching it. Every section retains its local path and a trust label.

The bundle is capped in size and marked when truncated. It is context for inspection, not verification.

### Resource Deck

Shows approximate used and total memory, the largest resident processes, and currently loaded Ollama models. The only destructive control in this pass is explicit Ollama model unloading. General process killing remains in Activity Monitor.

### Pixel operator strip

Each session receives a tiny native pixel operator. Its state is projected from observable runtime facts:

- working: output received recently
- ready: process running without recent output
- detached: tmux client detached
- exited: process ended without a nonzero code
- failed: nonzero exit code observed

The strip is decorative telemetry, not the source of truth.

## Deferred deliberately

- Autonomous routing and agent-to-agent loops
- Automatic task-completion judgments
- Hidden transcript indexing
- Silent process resurrection
- General-purpose process termination
- MindGraph retrieval blending
- Private project wiring

## Verification

The portable context, receipt, and forwarding logic has deterministic unit tests. macOS CI compiles and tests the AppKit, Speech, SwiftTerm, tmux-launch, and packaging surfaces. A local smoke test remains required for CLI authentication, microphone permissions, tmux behavior, and the user's private MainFrame tree.
