# Conduit master plan

## Product statement

Conduit is MainFrame's native agent workspace. Task history is the primary
navigation; Conversation is the default work surface; a real PTY remains
available in Raw for approvals, debugging, direct CLI input, and TUI behavior
that Conduit cannot structure honestly.

The app supplies context, execution continuity, and evidence-aware closeout
around independent installed CLI agents. It does not replace MainFrame's file
tree, impersonate agent APIs, or infer completion from terminal prose.

## Current daily-driver condition

Cameron can stay in Conduit for the ordinary MainFrame loop when:

- task history appears across the selected MainFrame root, with optional
  project filtering from the live file scan
- New Task explicitly chooses an enabled local CLI profile and a scanned scope
- selecting history never launches or reconnects a process
- a matching durable runtime reconnects only after an explicit action
- new and resumed runtimes open in Conversation, with Raw one action away
- multiline prompts can be edited, dictated, and supplied with local-path
  attachments
- project context and work-session receipt controls remain available without
  displacing the central task surface
- relaunch restores task identity plus source-labelled local conversation
  history without retaining an unprocessed terminal-byte transcript
- an idea can still be captured into `00_inbox` without leaving the app

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
├── task-history rail
│   ├── All MainFrame or source-derived project scope
│   ├── Pinned / Active / Recent / opt-in Archived
│   └── secondary Discovered tmux recovery
├── central task workspace
│   ├── Conversation (local source-labelled event projection)
│   ├── Raw (SwiftTerm PTY/TUI over the same controller)
│   ├── read-only historical thread surface
│   └── rich composer in live Conversation
├── project context + work-session receipt controls
├── attachment and speech services
└── explicit task/runtime actions
    ├── New Task (enabled agent + scanned scope)
    ├── Reconnect / Resume
    └── Leave / End

App services (macOS-only)
├── AppModel (task selection, runtime ownership, project scan projection)
├── TerminalRuntime
│   ├── live SessionPresentationEvent projection
│   └── TerminalSessionController (lifecycle, readiness-gated delivery)
├── SwiftTerm LocalProcessTerminalView
│   └── local PTY  or  tmux attach-session
│       └── shell / installed CLI agent
├── SubprocessRunner (argv-direct, timeout, SIGPIPE-safe)
├── EnvironmentResolver (login PATH, resolve never spawns)
├── TmuxDriver (identity / create / detach / paste / discovery / rendered capture)
├── security-scoped MainFrame folder access with timeout recovery
└── BlockingWork (GCD offload with bounded startup scan)

ConduitCore (AppKit-free, with selftest/XCTest coverage)
├── frontmatter parser
├── MainFrame scanner
├── project navigation and exact agent-sprite mapping
├── TaskSessionID / RuntimeAttemptID
├── task-session event log + deterministic projection
├── conversation event log + rendered-output reducer
├── session catalog + operational availability resolver
├── conservative Conversation presentation events
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
| Task continuity | Append-only metadata logs under `~/.conduit/task-sessions/` |
| Conversation history | Append-only source-labelled events under `~/.conduit/conversations/` |
| Terminal execution and TUI | Live PTY process exposed through Raw |
| Work-session continuity | Append-only events under `~/.conduit/worklog/` |
| Work-session receipt | New Markdown file under MainFrame `20_live/conduit/sessions/` |
| Temporary pasted images | `~/.conduit/attachments/` |
| Captured ideas | New notes under MainFrame `00_inbox/` |

Task logs are not project authority. Current project scope labels and paths are
resolved from the MainFrame scan when available; the stored workspace title and
slug are historical fallbacks. A task's own display title remains its recorded
deterministic default or operator override; a later project rename does not
silently rewrite that task title.

### Navigation and runtime lifecycle

A task history can outlive several concrete runtime attempts. Selecting that
history updates the visible task and resolves its current MainFrame project when
possible. It may focus an already-open runtime, but it never starts or attaches
one.

With durable sessions enabled and tmux installed, Conduit creates a session
detached and records project, agent, and task identity as tmux options before
SwiftTerm attaches. Leaving detaches via an out-of-band tmux command. A
matching observed tmux session is labelled reconnectable, but attachment still
requires Reconnect or Resume. Legacy sessions without a task binding appear in
Discovered and require explicit adoption; malformed bindings remain unchanged
and cannot resume.

Direct PTYs launch in the selected scope and end when closed. Prompt delivery
uses paste semantics and queues until observed output is quiet for 0.6 seconds,
or until an eight-second cap is reached after the first byte. This timer gates
byte delivery only; it does not infer agent readiness, state, or completion. The
process starts without requiring the Raw view to mount.

### Conversation, Raw, and receipts

Conversation renders Conduit-recorded launch or reattach requests, native
composer submissions, local attachment paths, forwarded-output provenance, and
terminal delivery state. Entry requests do not prove that process attach
succeeded. Conversation also renders bounded visible output derived from SwiftTerm's
rendered buffer or `tmux capture-pane`. Those blocks are always labelled
**Derived from Raw** and may contain prompt echo, tool logs, status chrome, or
agent prose. Generic activity is not private chain-of-thought, an approval, or
a completion boundary.

Raw is the live execution authority over the same controller. It is not stored
as an unprocessed PTY-byte transcript. Conversation events survive runtime and
app relaunch in a separate append-only local stream. A content-free task marker
records that history is expected after the first successful conversation
append. Missing marked history is called unavailable; an unmarked task remains
a possible pre-retention or never-recorded gap. Neither is shown as a complete
empty thread.

When a runtime detaches or ends, Conversation removes the active composer.
Raw remains available for inspection, and Conversation presents the applicable
Reconnect or Restart Runtime action alongside New Task.

Task-session logs retain identity and operational metadata. Work-session logs
and rendered receipts are separate project-scoped evidence records. A receipt
write can support the `RECORDED` affordance, but neither a receipt nor a task
availability label asserts successful work.

### Security and privacy

The app is intentionally unsandboxed because local shells need access to developer tools and the user-selected MainFrame tree. Therefore:

- no automatic uploads
- no telemetry by default
- no secret indexing outside explicit future features
- local conversation history contains sensitive prompt text and path references;
  rendered CLI text can also include file contents, secrets, tool output, and
  terminal chrome, and is never uploaded or indexed silently
- the 16,000-character bound applies to each rendered projection revision;
  append-only earlier revisions remain in the local source
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

### D-022: Conversation default, Raw terminal authority

One live runtime has two views. Conversation is conservative and native; Raw
keeps the real PTY/TUI available. Adapter failure must degrade to Raw.

### D-023: Metadata-only task continuity

Append-only task events retain identity, scope fallback, agent identity when
known, title/pin/archive changes, and operational lifecycle. They do not retain
prompts or terminal content.

### D-024: Task history primary, runtime actions explicit

All MainFrame task history is the default rail. Project filtering is
source-derived, New Task reviews agent and scope, task selection is
side-effect-free, and reconnect/leave/end remain explicit. Work-session
receipts stay separate.

### D-025: Prompt readiness waits for bounded output quiescence

D-016's first-output/no-timers readiness clause is superseded. A first byte can
be tmux attach redraw rather than a usable prompt boundary, so queued prompt
delivery waits for 0.6 seconds of output quiescence, with an eight-second hard
cap measured from the first byte. These timers govern byte delivery only and
never infer agent state or completion.

### D-026: Local append-only, source-labelled conversation history

Conversation events survive relaunch in a private per-task JSONL stream.
Generic terminal output is retained only as bounded rendered projections
labelled Derived from Raw; it is not attributed to an assistant turn.
Structured messages require a capability-declared adapter. Raw remains the
terminal authority, and neither output quietness nor agent prose is completion
or verification evidence. Attaching a path does not copy that file into
history, but text the CLI renders—including file contents or secrets—may enter
a retained revision. The 16,000-character bound is per revision, not a bound
on the append-only source.

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
- paste-semantics prompt delivery, held for bounded observed-output quiescence,
  serialized FIFO, delivery failure surfaced
- explicit `SessionLifecycle` state machine; honest exit-code handling (out-of-band for tmux, decoded for PTY)
- event-sourced work sessions with crash recovery
- subprocess layer that cannot deadlock, hang the main actor, or crash on SIGPIPE
- single-window scene; on-device speech enforced
- responsive 1080×720 daily workspace with adaptive context presentation
- security-scoped MainFrame access recovery and complete local app signing
- compact Codex and Claude sprites in session controls, with a generic fallback
  for every unmatched profile

### Phase 2: Session continuity — **partial**

- event-sourced project work sessions and receipts — **done**
- durable tmux discovery and explicit resume — **done**
- task identity across runtime attempts — **implemented in source**
- append-only metadata history with titles, pins, archives, and diagnostics —
  **implemented in source**
- All MainFrame task rail with project filter and Discovered recovery —
  **implemented in source**
- explicit New Task agent/scope selection — **implemented in source**
- Conversation default, Raw secondary over the same real PTY —
  **implemented in source**
- append-only retained prompts and source-labelled rendered output —
  **implemented in source**
- installed-app and interactive daily-driver acceptance for the redesign —
  **pending**
- selected task/window navigation persistence — **planned**
- destructive clear-history and transcript-body search — **deferred**

### Phase 3: Capability-declared agent events

- declare adapter capabilities per agent rather than assume one common stream
- accept agent-native structured output where the CLI supports it
- add source-labelled approval, tool, change, test, and artifact events
- degrade to the current Conversation subset plus Raw when an adapter is absent
  or fails
- never infer structured facts merely because a CLI printed matching prose

### Phase 4: Assurance and retrieval

- add review surfaces for changes, tests, files, and artifacts backed by
  deterministic inspection
- separate MindGraph durable-knowledge and project-context result groups
- `@file` and `@context` picker
- retain operator-reviewed terminal-output forwarding
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
- unprocessed or silently indexed terminal-byte transcripts
- full agent-response reconstruction without declared adapter support
- treating terminal output as completion evidence

## Evaluation loop

Keep candidate, installed-app, and interactive acceptance separate. Automated
core tests can prove deterministic projections and event-log mechanics; they
cannot prove local CLI authentication, macOS permissions, terminal focus, tmux
reattachment, or whether the conversation-first layout works as a daily driver.

Use Conduit for real work. Capture friction in `00_inbox`, then promote
confirmed patterns into issues and phase plans. Features graduate only when
they remove repeated friction or improve evidence, safety, or continuity.
