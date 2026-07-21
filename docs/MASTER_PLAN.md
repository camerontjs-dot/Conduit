# Conduit master plan

## Product statement

Conduit is MainFrame's native personal work surface: one place to enter a project, launch any installed CLI agent, communicate using text, voice, screenshots, and files, inspect project state, and preserve unfinished work.

It is intentionally a daily-driver application before it becomes an orchestration layer.

## Success condition for 0.1

Cameron can use Conduit instead of opening several terminal and AI applications while working inside MainFrame:

- projects appear automatically from `30_projects`
- Claude, Codex, Gemini, OpenCode, and shell sessions launch in the correct folder
- prompts can be edited, dictated, and supplied with local attachments
- context remains visible without repeated file hunting
- an idea can be captured into `00_inbox` without leaving the app

## MainFrame compatibility contract

Conduit is designed against the public MainFrame architecture rather than any private workstation inventory.

```text
00_inbox/      fast unsorted capture
01_ingest/     normalization and routing
10_knowledge/  durable knowledge and evidence references
20_live/       volatile operational state
30_projects/   active outcome-oriented work
90_archive/    preserved inactive material
```

Project folders are discovered under `30_projects/`. When present, `README.md` frontmatter may provide:

```yaml
title: "Project name"
project_state: "active"
goal: "Outcome"
next_action: "Single next step"
updated: "YYYY-MM-DD"
```

Conduit must:

- read the tree rather than maintain a competing project inventory
- treat README metadata as navigation and coordination information
- show project context without presenting it as verified truth
- create new inbox notes with timestamp, project provenance, and attachment references
- refuse to silently replace existing captures
- keep private project contents outside this repository
- defer ingest, promotion, retrieval, and knowledge extraction to MainFrame's deterministic tools

## Architecture

```text
SwiftUI application shell
├── MainFrame navigator
├── project context panel
├── rich composer
├── attachment and speech services
└── terminal workspaces
    ├── TerminalSessionController (lifecycle, readiness-gated delivery)
    └── SwiftTerm LocalProcessTerminalView
        └── local PTY  ── or ──  tmux attach-session
            └── zsh / Claude / Codex / other CLI

App services (macOS-only)
├── SubprocessRunner (argv-direct, timeout, SIGPIPE-safe)
├── EnvironmentResolver (login PATH, resolve never spawns)
├── TmuxDriver (new-session -d / detach-client / paste-buffer / has-session)
└── BlockingWork (GCD offload)

ConduitCore (AppKit-free, tested)
├── frontmatter parser
├── MainFrame scanner
├── prompt assembler + PromptEncoder (paste bytes)
├── inbox writer
├── SessionLifecycle + naming + quoting + exit-status decode
├── work-session events (JSONL) + receipt renderer
└── settings models/store
```

### Sources of truth

| Concern | Source of truth |
| --- | --- |
| Project inventory | MainFrame `30_projects/` directory |
| Project coordination | Project `README.md`, logs, decisions, plans |
| Agent configuration | `~/.conduit/config.json` |
| Terminal runtime | Live PTY process |
| Temporary pasted images | `~/.conduit/attachments/` |
| Captured ideas | New notes under MainFrame `00_inbox/` |

### Terminal lifecycle

A terminal session belongs to one project and one agent profile. With durable sessions enabled and tmux installed, the session is created detached out-of-band and SwiftTerm attaches a client to it; closing the tab detaches via `tmux detach-client`. Direct PTYs launch the process in a pseudo-terminal with the project's directory as the working directory, and closing the tab terminates that process explicitly. Prompt delivery uses paste semantics (bracketed-paste aware) and is queued until the session's first output.

Session definitions can be persisted later, but Conduit must never silently resurrect commands that could mutate files.

### Security and privacy

The app is intentionally unsandboxed because local shells need access to developer tools and the user-selected MainFrame tree. Therefore:

- no automatic uploads
- no telemetry by default
- no secret indexing outside explicit future features
- no shell interpolation of composer text; prompts are written directly to the PTY
- CLI launch profiles are stored locally
- project discovery remains local

SwiftTerm is pinned to a known revision because Conduit relies on its PTY-backed `LocalProcessTerminalView`. Advance it deliberately after a macOS build and terminal smoke test.

## Decisions

### D-001: MainFrame-specific personal app

A generic agent terminal would spend early effort on abstraction rather than the actual workflow. Conduit is opinionated around MainFrame's lifecycle tree and project README contract.

### D-002: Native macOS with SwiftUI

The immediate user is on macOS. Native clipboard, drag-and-drop, screenshot, microphone, and speech APIs keep runtime overhead lower than an Electron shell.

### D-003: SwiftTerm for real PTYs

Interactive agent CLIs require terminal semantics. A `Process` plus text view would fail on ANSI rendering, resizing, cursor movement, and TTY detection.

### D-004: File tree over project database

MainFrame explicitly treats its directory layout as the source of truth. A second project catalog would drift.

### D-005: Speech enters an editable composer

Dictation never auto-submits. Technical names and commands must be correctable before an agent receives them.

### D-006: Attachments are local-path references

Pasted images are saved locally and attachment paths are appended to prompts. This supports current CLI agents without hidden provider-specific uploads.

### D-007: No autonomous orchestration in 0.1

Conduit launches, displays, and communicates with agents but does not route tasks autonomously. Daily use should generate evidence about which coordination features are genuinely valuable.

## Phase map

Legend: **done** · **partial** · **planned**.

### Phase 1: Daily-driver foundation — **done**

Implemented, then hardened in the 0.3 rework.

- native application shell
- MainFrame project discovery
- PTY terminal tabs
- configurable agent launchers
- rich composer
- speech-to-text (on-device only)
- attachments and screenshots
- context panel
- inbox capture
- core tests (`conduit-selftest`) and macOS CI

### Phase 1.5: Reliability rework (0.3) — **done**

The foundation's terminal layer, rebuilt for correctness (see ADRs D-015…D-019).

- tmux as the session spine: created detached out-of-band, deterministic detach via `tmux detach-client`, paste-buffer delivery
- paste-semantics prompt delivery, held until the agent is ready, serialized FIFO, delivery failure surfaced
- explicit `SessionLifecycle` state machine; honest exit-code handling (out-of-band for tmux, decoded for PTY)
- event-sourced work sessions with crash recovery
- subprocess layer that cannot deadlock, hang the main actor, or crash on SIGPIPE
- single-window scene; on-device speech enforced

### Phase 2: Session continuity — **partial**

- session-close handoff generator — **done** (event-sourced receipts + operator-mediated forwarding)
- durable sessions survive app restart via tmux; relaunching the same agent reconnects — **partial** (no explicit restore screen yet)
- persist tab definitions and selected project — **planned**
- optional terminal transcript recording — **planned**
- explicit restore screen, never automatic process resurrection — **planned**
- recent sessions and named workspaces — **planned**

### Phase 3: MainFrame command adapters

- run `session-open` and `session-close` when installed
- expose project index refresh and doctor checks
- capture workflow events through MainFrame's deterministic CLI
- display command output and receipts rather than infer success

### Phase 4: Retrieval and handoffs

- separate MindGraph durable-knowledge and project-context result groups
- `@file` and `@context` picker
- send selected terminal output to another agent
- evidence-bearing handoff notes
- no unlabelled blending of retrieval classes

### Phase 5: Resource-aware workstation

- process and memory dashboard
- explicit Ollama model unload controls
- service profiles for image-generation workloads
- resource policies and launch warnings
- optional Pixel Agent Tracker projection of recorded state

## Out of scope until proven useful

- autonomous task routing
- invisible shared memory
- cloud synchronization
- provider account management
- automatic file uploads
- full task DAGs
- treating terminal output as completion evidence

## Evaluation loop

Use Conduit for real work. Capture friction in `00_inbox`, then promote confirmed patterns into issues and phase plans. Features graduate only when they remove repeated friction or improve evidence, safety, or continuity.
