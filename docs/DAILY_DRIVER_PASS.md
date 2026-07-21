# Conduit daily-driver pass

## Goal

Make Conduit useful as Cameron's default MainFrame work surface without introducing autonomous orchestration or a second source of truth.

## Implemented additions

### Conduit Doctor

Checks configured CLI commands, reports resolved executable paths and versions, validates the public MainFrame lifecycle folders, detects tmux, and surfaces microphone and speech-recognition permission state.

A successful command-path check is not proof that the account is authenticated or that a provider service is available. It is a local readiness signal only.

### Durable sessions

When the setting is enabled and tmux is installed, Conduit creates deterministic session names from the standardized project path and agent name. Launching the same agent in the same project reconnects to that session. Closing a tab detaches rather than terminating the underlying tmux work.

When tmux is unavailable, the UI labels the session `PTY` and closing it terminates the process explicitly. Conduit does not pretend direct PTYs survived.

### Terminal-output forwarding

SwiftTerm selections use the normal macOS clipboard. Conduit can move copied output into the composer or launch another agent with the selection wrapped in an evidence boundary:

- terminal output is unverified
- actual files and repository state must be inspected
- deterministic checks should be rerun

### Work-session receipts

Launching the first agent in a project starts a lightweight work session. The operator can edit the objective and add a receipt note. Closing the work session creates a new Markdown receipt under:

```text
20_live/conduit/sessions/
```

The receipt records timestamps, project provenance, active and detached session outcomes, observed exit codes, a Git snapshot, and operator notes. It does not claim task success.

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
