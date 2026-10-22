# Conduit master plan

## Product statement

Conduit is MainFrame's native agent workspace. Task history is the primary
navigation; Conversation is the default work surface; a real PTY remains
available in Raw for approvals, debugging, direct CLI input, and TUI behavior
that Conduit cannot structure honestly.

The app supplies context, execution continuity, and evidence-aware closeout
around independent installed CLI agents. It does not replace MainFrame's file
tree, impersonate agent APIs, or infer completion from terminal prose.

The current dependency-ordered programme is tracked in
[#60](https://github.com/camerontjs-dot/Conduit/issues/60), under
[#4](https://github.com/camerontjs-dot/Conduit/issues/4) and its owner lanes.
This file records the original workspace foundation and component status.
Source implementation, independent qualification, mounted acceptance and
release remain separate.

The [T3 Code adoption plan](plans/t3code-adoption.md) records a bounded
source comparison and proposed additions within these owner lanes. Its
[local-agent handoff](plans/t3code-local-agent.md) covers review, finalization
and implementation; the plan does not establish qualification or release readiness.

## Active completion train — 2026-10-18

The current direction is **ChatGPT-first local operation**, with agent
delegation used when it adds value. The sequencing authority is the
[#60 update](https://github.com/camerontjs-dot/Conduit/issues/60#issuecomment-6158666100)
and [#51 update](https://github.com/camerontjs-dot/Conduit/issues/51#issuecomment-6158659475):
ordinary Shell use, direct filesystem observation, typed direct commands,
bounded file/search/process/artifact actions, then installed end-to-end parity
and a versioned release before retiring the external fallback.

The direct-operation completion candidate combines the exact source inputs
from [#172](https://github.com/camerontjs-dot/Conduit/pull/172) and
[#173](https://github.com/camerontjs-dot/Conduit/pull/173), then adds project
search, bounded create/replace, durable command receipts and action-scoped
client presentation. Their original qualification evidence remains tied to
their original identities. [#111](https://github.com/camerontjs-dot/Conduit/pull/111)
was closed as a superseded route with its branch and inconclusive evidence
retained; that administrative closure was not a qualification pass.

| Owner or lane | Source disposition | Remaining gate |
| --- | --- | --- |
| Local Operator [#51](https://github.com/camerontjs-dot/Conduit/issues/51), Explorer [#54](https://github.com/camerontjs-dot/Conduit/issues/54) | Direct reads, literal project search and bounded UTF-8 create/replace are in the completion candidate. | Exact-source checks, independent review and installed authenticated-client acceptance. Broader move/delete/process/artifact surfaces remain separate scope. |
| Typed commands [#170](https://github.com/camerontjs-dot/Conduit/issues/170) | Native runner, durable ID/status/cancel contract and disposable process fixtures are implemented. Production execution explicitly refuses. | Choose and enforce operator-granted execution authority, then independent and installed two-round command/artifact acceptance. |
| Client control [#174](https://github.com/camerontjs-dot/Conduit/issues/174) | Explicit action origin propagates through shared helpers, slash delivery and delayed feedback. | Required independent Codex qualification and a mounted interleaved-client UI journey. Entitlement must be observed for the required model; a catalog listing is insufficient. |
| Frozen qualification train | [#168](https://github.com/camerontjs-dot/Conduit/pull/168) → [#123](https://github.com/camerontjs-dot/Conduit/pull/123) → [#128](https://github.com/camerontjs-dot/Conduit/pull/128); [#169](https://github.com/camerontjs-dot/Conduit/pull/169) retains the packet. | Preserve exact source/apparatus identities and exposure stops. New source work does not advance this train. |
| Runtime/execution truth | [#82](https://github.com/camerontjs-dot/Conduit/pull/82), [#126](https://github.com/camerontjs-dot/Conduit/pull/126), [#137](https://github.com/camerontjs-dot/Conduit/pull/137) contain separate queue, cleanup and metadata work. | Required isolation, provider/process observations and mounted qualification; source tests alone do not establish execution custody. |
| Distinct control boundaries | [#130](https://github.com/camerontjs-dot/Conduit/pull/130), [#135](https://github.com/camerontjs-dot/Conduit/pull/135), [#146](https://github.com/camerontjs-dot/Conduit/pull/146), [#147](https://github.com/camerontjs-dot/Conduit/pull/147) remain separate stale-target, receipt, shared-bearer and diagnostics candidates. | Preserve their authority and acceptance boundaries; #174 does not implicitly complete them. |
| Explorer journeys | [#119](https://github.com/camerontjs-dot/Conduit/pull/119) → [#124](https://github.com/camerontjs-dot/Conduit/pull/124) → [#125](https://github.com/camerontjs-dot/Conduit/pull/125), [#129](https://github.com/camerontjs-dot/Conduit/pull/129) → [#131](https://github.com/camerontjs-dot/Conduit/pull/131), and [#144](https://github.com/camerontjs-dot/Conduit/pull/144) retain source implementations. | Mounted editing/conflict/navigation/query-isolation journeys on their exact candidate sources. |
| Workspace custody [#120](https://github.com/camerontjs-dot/Conduit/pull/120) | Source contract is implemented. | Actual runtime cwd, writer lease and reuse observations. |
| Context delivery | [#132](https://github.com/camerontjs-dot/Conduit/pull/132) and [#140](https://github.com/camerontjs-dot/Conduit/pull/140) → [#148](https://github.com/camerontjs-dot/Conduit/pull/148) → [#150](https://github.com/camerontjs-dot/Conduit/pull/150) preserve their stack. | Destination/delivery acceptance remains distinct from source gates. #132's later gate receipt supersedes its stale pending body. |
| Proposal and orchestration contracts | [#122](https://github.com/camerontjs-dot/Conduit/pull/122), [#127](https://github.com/camerontjs-dot/Conduit/pull/127), [#134](https://github.com/camerontjs-dot/Conduit/pull/134), [#138](https://github.com/camerontjs-dot/Conduit/pull/138) contain source contracts. | Live inputs, explicit approval and mounted integration; a proposal or selection grants no execution authority. |
| MindGraph and hosted research | The guarded [#90](https://github.com/camerontjs-dot/Conduit/pull/90)/[#95](https://github.com/camerontjs-dot/Conduit/pull/95) consumer assembly is complete at child `cb7afad034a5d0903438aa9d998bc93c266b305f`, on its historical source line. The [#89](https://github.com/camerontjs-dot/Conduit/pull/89) → [#93](https://github.com/camerontjs-dot/Conduit/pull/93) → [#94](https://github.com/camerontjs-dot/Conduit/pull/94) chain retains distinct inputs, including #91/#92. | Consumer source gates and exact-pair qualification remain separate. Materialize the existing MindGraph #31 producer object `0d60e88f6ac2a5ca26fa870774181c21a7afd65a`; do not recreate the closed #29 kit or treat these lanes as duplicates of #123. |
| Integration [#142](https://github.com/camerontjs-dot/Conduit/pull/142) | Explicit operator HOLD remains in effect. | Replan from live Conduit and MindGraph authority before integration. |
| Field and operational evidence | Entitlement [#113](https://github.com/camerontjs-dot/Conduit/issues/113), research [#76](https://github.com/camerontjs-dot/Conduit/issues/76), transport [#66](https://github.com/camerontjs-dot/Conduit/issues/66), and incident [#44](https://github.com/camerontjs-dot/Conduit/issues/44) remain evidence-driven work. | Actual model eligibility, preserved failure cases, ordinary supervisor transport and incident reproduction; no inferred automatic wake or higher-concurrency acceptance. |

The [#50 umbrella](https://github.com/camerontjs-dot/Conduit/issues/50) and
[#52 field notes](https://github.com/camerontjs-dot/Conduit/issues/52) are ongoing
owner records. An open item is not necessarily unfinished code, and an
administrative closure is not product acceptance. Current owning issue/PR
receipts override this dated planning snapshot when newer evidence arrives.

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

The diagram records the PTY workspace foundation. Current source also contains
the first-party structured hosts in [D-040](../DECISIONS.md#d-040-per-agent-first-party-structured-hosts)
and an app-hosted Session API/MCP. AppModel still owns runtime coordination;
#4's UI-independent ownership and GUI-restart acceptance remain separate gates.

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
| Provider-native session/turn observations | Declared structured adapter events, with their own source labels |
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

For PTY/TUI work, Raw is the live terminal authority over the same controller.
It is not stored as an unprocessed PTY-byte transcript. Conversation events survive runtime and
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

Legend: **done** · **partial** · **planned**. The early **done** entries record
foundation history. **Implemented in source** identifies landed components;
their provider, installed-app and system qualification remains separately
recorded by the current owner lanes.

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
- Conversation default, Raw available for PTY/TUI work —
  **implemented in source**
- append-only retained prompts and source-labelled rendered output —
  **implemented in source**
- installed-app and interactive daily-driver acceptance for the redesign —
  **pending**
- selected task/window navigation persistence — **planned**
- destructive clear-history and transcript-body search — **deferred**

### Phase 3: Capability-declared agent events — **partial**

- per-profile first-party launch surfaces and native protocol envelopes —
  **implemented in source** ([D-040](../DECISIONS.md#d-040-per-agent-first-party-structured-hosts))
- source-labelled output, approval, completion and failure events —
  **implemented in source** for declared adapters; completion is not verification
- broader tool, change, test and artifact coverage and version-specific
  conformance — remaining implementation/qualification under
  [#53](https://github.com/camerontjs-dot/Conduit/issues/53)
- explicit PTY fallback and Raw remain the terminal path when a structured
  surface is unavailable
- never infer structured facts merely because a CLI printed matching prose

### Phase 4: Assurance and retrieval — **partial**

- deterministic file/Git inspection and review surfaces — **implemented in
  source**; broader changes/tests/artifacts acceptance remains with
  [#50](https://github.com/camerontjs-dot/Conduit/issues/50) /
  [#54](https://github.com/camerontjs-dot/Conduit/issues/54)
- separate MindGraph Knowledge/Projects scopes and citation classes —
  **implemented in source**; retrieval remains nomination/context
- Context Compiler core — merged after bounded component qualification in
  [#108](https://github.com/camerontjs-dot/Conduit/pull/108); source adapters,
  UI/destination wiring and delivery qualification remain with
  [#58](https://github.com/camerontjs-dot/Conduit/issues/58)
- `@file` and `@context` picker — retained roadmap scope
- retain operator-reviewed terminal-output forwarding
- evidence-bearing handoff notes — delivery and acceptance qualification remain
  with #58 and #53
- no unlabelled blending of retrieval classes

### Phase 5: Resource-aware workstation — **partial**

- process and memory dashboard — **implemented in source**
- explicit Ollama model unload controls — **implemented in source**; an unload
  request and an observed model release remain separate evidence
- resource admission/circuit foundations — **implemented in source**; launch
  warnings and capacity qualification remain with #53
- service profiles for image-generation workloads — retained roadmap scope
- optional Pixel Agent Tracker projection of recorded state — conditional
  roadmap scope

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

