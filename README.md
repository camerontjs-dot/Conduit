# Conduit

Conduit is a native macOS work surface for operating **MainFrame** through the CLI agents already installed on your computer.

**Changelog:** [`CHANGELOG.md`](CHANGELOG.md) — update on every user-visible product change (see `AGENTS.md`).

It is deliberately a personal daily driver before it becomes an orchestration platform. The current app gives MainFrame a focused desktop face without replacing its file tree, its evidence rules, or the native agent CLIs underneath it.

## Daily loop

1. Choose a MainFrame root.
2. Choose a task from the left sidebar, or press `⌘N` to start one.
   New Task explicitly chooses both an installed CLI agent and a scope: the
   MainFrame root or a project discovered under `30_projects/`.
3. Use the **All MainFrame** scope control when you want to filter task history
   by project. Project browsing is navigation over MainFrame files, not a
   second project registry.
4. The task opens in Conversation while its real PTY starts independently in
   the background. Press `⌘F` to search task history.
5. Compose multiline prompts, dictate them, paste screenshots, capture a screen
   region, or attach files and folders. Conduit records the exact native
   composer submission and whether it is **Queued**, **Sent to terminal**, or
   **Delivery failed**. Visible CLI output appears as a best-effort
   **Derived from Raw** block and the thread is retained locally.
6. Build a labeled context bundle from project coordination files.
7. Open **Raw** for the live SwiftTerm PTY/TUI surface, approvals, direct CLI
   input, and unsupported TUI behavior; return to Conversation with one click
   or `⌘1`. Raw remains authoritative; Conduit retains source-labelled
   conversation events, not an unprocessed Raw byte transcript.
8. Forward selected terminal output to another agent with an explicit
   verification boundary.
9. Close the work session and write an append-only receipt under
   `20_live/conduit/sessions/`.

## Current features

### Agent workspace

- Conversation-first sessions with a per-session **Conversation / Raw**
  switcher. Conversation shows exact native prompts plus bounded rendered
  output labelled **Derived from Raw**. Generic activity is never called
  private thinking, completion, or verification.
- Raw keeps the unchanged SwiftTerm PTY as the authoritative live execution
  surface and direct-control escape hatch.
- Task-history sidebar with Pinned, Active, Recent, optional Archived, and a
  secondary Discovered recovery section. Selecting history never reconnects a
  process; reconnect is always explicit.
- Reversible trailing Inspector with Session, Files, Review, Context, and Usage
  tabs. Its divider is draggable like the task rail, persists a 300–420-point
  preference, supports keyboard/VoiceOver adjustment, and resets to the
  responsive default without changing density or terminal identity.
- Optional account meters load only after an explicit Refresh from Inspector ›
  Usage or the usage sheet. Conduit never asks macOS to unlock Claude credentials
  automatically; unavailable account data does not affect agents, tasks, or Raw.
- **All MainFrame** is the default task scope. The project browser filters
  history from the live MainFrame scan, while New Task defaults to the scope
  most recently submitted through that sheet.
- Append-only task metadata under `~/.conduit/task-sessions/`: task identity,
  fallback scope, optional recorded agent name, title, pin/archive changes,
  and operational lifecycle only.
- Separate append-only conversation history under
  `~/.conduit/conversations/`: exact prompts, local attachment path
  references, delivery revisions, and source-labelled rendered output.
  Conduit does not copy a file merely because its path is attached, but any
  text the CLI renders—including file contents or secrets—can enter a retained
  **Derived from Raw** revision. Each rendered revision is capped at 16,000
  characters; append-only earlier revisions remain in the local source.
  Unprocessed Raw bytes and inferred completion are not stored there.
- MainFrame root autodetection plus a security-scoped folder picker. If macOS
  invalidates access after a rebuild, Conduit shows an explicit recovery step
  instead of freezing during project discovery.
- Searchable project discovery from `30_projects/*/README.md`, presented as a
  secondary scope browser without inventing a second inventory
- Real PTY terminals powered by SwiftTerm
- Configurable CLI agent profiles
- Multiple project-scoped task runtimes
- Per-session surface selection, with new and resumed sessions opening in
  Conversation
- When a runtime detaches or ends, Conversation replaces the active composer
  with applicable reconnect, restart, and New Task actions while Raw remains
  available for inspection
- Durable tmux sessions created detached and out-of-band, with deterministic project-and-agent names
- Reconnection to an existing tmux session by launching the same agent again; deterministic detach via `tmux detach-client`
- Paste-semantics prompt delivery (bracketed paste aware), queued until observed
  output is quiet for 0.6 seconds or an eight-second cap is reached after its
  first byte
- Contextual Codex and Claude companions in the selected task and Conversation
  header, with static pose changes driven only by observed terminal state.
  Exact art requires an explicit full-name + executable signature and one
  complete, provenance-noted, SHA-manifested six-pose set; partial sets fall
  back atomically.
- An explicitly labelled generic pixel companion for Shell, Antigravity, Grok,
  OpenCode, Gemini CLI, Ollama, Cursor Agent, Aider, custom profiles, and any
  registered identity whose dedicated set is unavailable

### Rich input

- Multiline composer with `⌘↩` send
- macOS speech-to-text with editable transcription
- Clipboard image paste and native region screenshot capture
- Drag-and-drop and file/folder attachments
- Copied terminal selection forwarding between agents
- Automatic warning that forwarded terminal prose is unverified
- Forwarded selections appear in Conversation with their unverified terminal
  origin preserved

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
- Task continuity stored as separate append-only metadata and conversation
  JSONL streams under `~/.conduit/task-sessions/` and
  `~/.conduit/conversations/`
- Project-scoped work-session logs and MainFrame receipts remain a separate
  evidence stream; Conduit does not import receipts into task history

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

Start with the [`quick-start guide`](docs/QUICK_START.md). For design and
implementation context, see [`DECISIONS.md`](DECISIONS.md) (public product
ADRs), [`docs/MASTER_PLAN.md`](docs/MASTER_PLAN.md), and
[`docs/DAILY_DRIVER_PASS.md`](docs/DAILY_DRIVER_PASS.md).

## Status

The repository contains the application source, core tests, macOS CI, and the
packaging path for an Apple-silicon application. Automated test results,
candidate packaging, installed-app smoke, and interactive daily-driver
acceptance are separate evidence. Hardware permissions, installed CLIs, tmux
reattachment, and private MainFrame paths still require a local smoke test.
