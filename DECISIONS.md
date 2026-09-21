# Conduit product decisions (public-facing)

These ADRs describe Conduit as a product. They are intended to travel with the app when the repository is published. Keep them free of private host paths, private project inventories, and personal career material.

Narrative companions: [`docs/MASTER_PLAN.md`](docs/MASTER_PLAN.md), [`docs/DAILY_DRIVER_PASS.md`](docs/DAILY_DRIVER_PASS.md).  
MainFrame-only coordination decisions live outside this tree.

---

## D-001: MainFrame-specific personal app

**Status:** Accepted  
**Context:** A generic multi-agent terminal would spend early effort on abstraction rather than the operator's actual workflow.

**Decision:** Conduit is opinionated around MainFrame's lifecycle tree (`00_inbox` … `90_archive`) and the `30_projects/*/README.md` coordination contract.

**Consequences:** Discovery and capture integrate with that layout. The app is less useful as a blank generic terminal without a MainFrame-shaped tree.

---

## D-002: Native macOS with SwiftUI

**Status:** Accepted  
**Context:** The primary operator is on macOS and needs clipboard, drag-and-drop, screenshot, microphone, and speech APIs with low friction.

**Decision:** Build a native macOS SwiftUI application rather than an Electron shell.

**Consequences:** macOS 13+ is required. Cross-platform ports are out of scope until proven necessary.

---

## D-003: SwiftTerm for real PTYs

**Status:** Accepted  
**Context:** Interactive agent CLIs require terminal semantics (ANSI, resize, cursor, TTY detection).

**Decision:** Use SwiftTerm's PTY-backed terminal view. Pin the dependency to a known revision; advance deliberately after build and smoke tests.

**Consequences:** A Process-plus-text-view imitation is forbidden. Terminal packaging and CI must run on macOS with AppKit.

---

## D-004: File tree over project database

**Status:** Accepted  
**Context:** MainFrame treats its directory layout as the source of truth. A second catalog would drift.

**Decision:** Discover projects by scanning `30_projects/*/README.md`. Do not maintain a competing project inventory inside Conduit.

**Consequences:** README frontmatter (`title`, `project_state`, `goal`, `next_action`, …) is navigation metadata, not verified truth.

---

## D-005: Speech enters an editable composer

**Status:** Accepted  
**Context:** Technical names and shell commands must be correctable before an agent receives them.

**Decision:** Dictation never auto-submits. Speech is absorbed into the multiline composer for edit-then-send.

**Consequences:** Microphone and speech-recognition permissions are required for dictation; failures degrade to typed input only.

---

## D-006: Attachments are local-path references

**Status:** Accepted  
**Context:** Agent CLIs already accept path references; hidden provider uploads create privacy and reproducibility problems.

**Decision:** Pasted images and captures are saved locally; attachment paths are assembled into the prompt. No automatic uploads.

**Consequences:** Temporary attachment storage lives under the operator's machine (e.g. `~/.conduit/attachments/`). Provider-specific upload features would need an explicit future consent boundary.

---

## D-007: No autonomous orchestration in v0.x

**Status:** Accepted  
**Context:** Daily use should generate evidence about which coordination features are valuable before any router or multi-agent loop is built.

**Decision:** Conduit launches, displays, and communicates with agents but does not route tasks autonomously, judge completion from terminal prose, or run agent-to-agent loops by default.

**Refined by D-039 (2026-08-13):** operator-visible external orchestrator clients (ChatGPT chat, later the phone bridge) may call a capability-scoped session API. Conduit itself still does not become a router.

**Consequences:** Features such as task DAGs and invisible shared memory stay deferred. Inter-agent handoff is operator-mediated (e.g. forwarded selection with an unverified-output boundary).

---

## D-008: Unsandboxed local app

**Status:** Accepted  
**Context:** Local shells and developer tools need access to the user-selected MainFrame tree and installed CLIs.

**Decision:** Ship unsandboxed. Compensate with strict product rules: no automatic uploads, no default telemetry, no secret indexing outside explicit future features, no shell interpolation of composer text (write bytes to the PTY).

**Consequences:** Distribution and notarization choices must respect the unsandboxed model. Security is operational, not sandbox-enforced.

---

## D-009: Durable sessions only via explicit tmux

**Status:** Accepted (daily-driver pass 0.2)  
**Context:** Operators need reconnectable work without pretending a plain PTY survived app quit.

**Decision:** Optional durable sessions use tmux with deterministic project-and-agent names. Closing a tab detaches when tmux-backed. Direct PTYs are labeled as non-durable and terminate on close.

**Consequences:** tmux is recommended but optional. The UI must not claim process continuity when tmux is unavailable.

---

## D-010: Terminal forwarding carries an evidence boundary

**Status:** Accepted (daily-driver pass 0.2)  
**Context:** Agents often claim success in prose. Forwarding raw terminal output without labeling it encourages false completion.

**Decision:** When forwarding copied terminal selection to another agent, wrap it as unverified terminal output and instruct re-inspection of files and deterministic checks.

**Consequences:** Forwarding is a convenience, not a proof channel. Unit tests lock the boundary wording in `ConduitCore`.

---

## D-011: Work-session receipts are evidence-aware, not success claims

**Status:** Accepted (daily-driver pass 0.2)  
**Context:** Operators need continuity notes under MainFrame's live lifecycle without inventing verification.

**Decision:** Closing a work session writes a new Markdown receipt under `20_live/conduit/sessions/` with timestamps, objective, observed exit codes, detached state, Git snapshot, and operator notes. Receipts do not assert task success.

**Consequences:** Requires a MainFrame root with `20_live/`. Collision-safe filenames; append-only (never overwrite).

---

## D-012: Context bundles are labeled nominations

**Status:** Accepted (daily-driver pass 0.2)  
**Context:** Dumping whole projects into a prompt loses provenance and can exceed limits silently.

**Decision:** Nominate coordination files (README, AGENTS, decisions, log, status, recent plans) with per-file trust labels. Operator selects and previews before attach. Bundles are size-capped and mark truncation.

**Consequences:** Bundles are context for inspection, not verification. Paths remain visible in the assembled markdown.

---

## D-013: Resource Deck is visibility-first

**Status:** Accepted (daily-driver pass 0.2)  
**Context:** Local model and memory pressure is common during agent work; general process killing is dangerous in-app.

**Decision:** Show memory, largest processes, and loaded Ollama models. The only destructive control in this pass is explicit Ollama model unload. General process killing stays outside Conduit.

**Consequences:** Resource Deck is operational hygiene, not a full process manager.

---

## D-014: Pixel operator strip is decorative telemetry

**Status:** Superseded by D-021

**Context:** A small status affordance helps scanning many sessions without implying a control-room truth model.

**Decision:** Drive a compact pixel operator strip only from observable runtime state (working, running, detached, exited, failed). It is not the source of truth for task or agent success.

**Consequences:** No coupling to external trackers is required for 0.2. Future projections of recorded MainFrame state remain optional and separate.

---

## D-015: tmux is the session spine, controlled out-of-band

**Status:** Accepted (rebuild pass 0.3)  
**Context:** The first durable-session design treated tmux as an overlay: sessions were created inside the attaching client and detach was emulated by typing the default prefix key (`C-b d`). That assumed the operator's prefix binding, could inject stray keystrokes, and left prompt delivery racing agent startup.

**Decision:** When durable sessions are enabled and tmux is installed, Conduit creates sessions **detached and out-of-band** (`tmux new-session -d`) before the SwiftTerm client attaches, and performs every control operation as a tmux command against the exact-matched session name: `detach-client -s` for detach, `load-buffer`/`paste-buffer -p` for prompt delivery, `send-keys Enter` for submit. No keystroke emulation, no prefix assumption. Direct PTYs remain the labeled fallback.

**Consequences:** Detach works with any operator tmux configuration. Prompt delivery inherits tmux's bracketed-paste awareness. The agent's true exit code is unobservable for tmux-backed sessions (the session outlives the client); receipts record detach honestly instead.

---

## D-016: Prompt delivery uses paste semantics, queued until first output

**Status:** Accepted (rebuild pass 0.3)  
**Context:** Raw bytes written to a PTY look like typing: embedded newlines act as Enter, so multiline composer prompts were mangled per-agent, and forwarding used a fixed 0.7 s sleep that raced slow-starting CLIs.

**Decision:** Composer and forwarded text goes through `PromptEncoder`/`TmuxDriver.paste`: bracketed-paste wrapping when the foreground application enabled mode 2004 (tmux tracks this itself via `paste-buffer -p`; direct PTYs consult SwiftTerm's `bracketedPasteMode`), with one explicit CR as the submit. Delivery to a session that has not yet produced output is queued in the controller and flushed on the first observed output — no timers.

**Consequences:** Multiline prompts arrive as one block in shells and TUI agents alike. Forwarding to a freshly launched agent cannot lose the prompt. Unit and selftest coverage lock the encoder's byte sequences.

---

## D-017: Work sessions are event-sourced; receipts render from the log

**Status:** Accepted (rebuild pass 0.3)  
**Context:** Receipts were assembled in memory at close, so an app crash lost the whole session record, and switching projects silently discarded the active work session.

**Decision:** Each project gets its own concurrent work session. Every observable fact (start, agent launch, terminal outcome, objective/notes commits, git snapshot, close) is appended as JSONL to `~/.conduit/worklog/<id>.jsonl` as it happens; the Markdown receipt under `20_live/conduit/sessions/` is rendered from that log at close. At launch, logs without a close event are rendered into receipts marked with a recovery note. Torn final lines are healed on the next append and skipped on read.

**Consequences:** Receipts survive crashes and force quits. Switching projects never discards a session. The volatile log lives outside the MainFrame tree; only rendered receipts land in `20_live`.

---

## D-018: Speech recognition is on-device only, enforced

**Status:** Accepted (rebuild pass 0.3)  
**Context:** The docs promised local transcription, but `SFSpeechRecognizer` may use server-based recognition unless told otherwise — a silent privacy-claim mismatch.

**Decision:** `requiresOnDeviceRecognition = true` on every recognition request. If the locale's on-device model is unavailable, dictation is disabled with an explanatory message rather than falling back to a server.

**Consequences:** The privacy promise is enforced by code, not prose. Some locales may need the on-device model downloaded in System Settings before dictation works.

---

## D-019: A dependency-free selftest is the local verification gate

**Status:** Accepted (rebuild pass 0.3)  
**Context:** `swift test` requires XCTest, which Command Line Tools do not ship; machines without full Xcode had no local verification at all.

**Decision:** `swift run conduit-selftest` runs a deterministic assertion suite over `ConduitCore` (encoder bytes, lifecycle transitions, event-log roundtrips and recovery, receipt rendering and collision safety, scanner/inbox/bundle behavior) with no test-framework dependency. CI keeps the full XCTest suite.

**Consequences:** Any machine that can build the app can verify the core. The selftest and XCTest suites must be kept in step when core behavior changes.

---

## D-020: Stored paths are not macOS folder permission

**Status:** Accepted (finish pass 0.4)

**Context:** A saved MainFrame URL can remain syntactically valid after a local
rebuild while macOS has revoked that binary's access to the Desktop folder. A
blocking `open` call then waits in the kernel and leaves project discovery
stuck.

**Decision:** Capture a security-scoped bookmark through `NSOpenPanel`, renew it
at startup, and keep filesystem scanning off the main actor behind a bounded
wait. If access cannot be renewed or the read does not return, keep the window
responsive and present an explicit Choose Root recovery action. Sign and verify
the complete local `.app` bundle so its Info.plist and resources share the
intended bundle identity.

**Rejected alternatives:** A raw stored path is not permission. A shell helper
would transfer trust to another process and hide the real access boundary.
Scanning synchronously before the first window would reproduce the freeze.

**Evidence:** A sampled installed build was blocked in `open` while reading the
saved root README. The recovery build accepted the same folder through the
system picker, saved the bookmark, loaded 32 project folders, and restored them
after relaunch.

**Consequences:** A development build may ask for one renewed folder selection
after its code identity changes. The installed app fails visibly instead of
silently hanging. The app remains unsandboxed under D-008.

---

## D-021: Agent sprites are compact identity, not progress evidence

**Status:** Accepted (finish pass 0.4)

**Context:** Generic status ornament duplicated session information and did not
help distinguish terminal identities. Existing MainFrame character art could
make the work surface more personable, but external tracker wiring or a
decorative completion pose would overstate what Conduit observes.

**Decision:** Copy the six Codex and Claude poses into Conduit's own resource
bundle with source notes and SHA-256 hashes. Resolve only exact known names or
executables. Every unmatched profile gets an in-code generic character with an
accessibility hint. Map poses only from terminal lifecycle facts: starting,
recent output, running quiet, detached, exited, and failed.

**Rejected alternatives:** Runtime reads from the workstation create an
undeclared product dependency. Fuzzy name matching can impersonate a known
identity. A large separate sprite strip takes terminal space while repeating
the session bar. Tracker state would introduce a second control plane.

**Evidence:** Core tests cover exact and fallback mapping. The packaged resource
manifest verifies all twelve copied PNGs, and the app bundle is checked after
resource installation. Live visual evidence remains part of the local macOS
smoke gate.

**Consequences:** Sprites stay inside compact session controls and are hidden as
redundant VoiceOver elements. Their textual state remains the accessible source
of meaning. Public redistribution of the copied art is not asserted by this
decision; the bundled provenance note records that boundary.

---

## D-022: Conversation is the default; Raw remains the terminal authority

**Status:** Accepted (conversation-first redesign)

**Context:** The terminal-first workspace preserved CLI compatibility but made
Conduit feel like a terminal application with agent features. Independent CLI
agents do not provide one uniform structured message or approval stream, so a
native conversation view cannot honestly reconstruct every agent response from
arbitrary ANSI/TUI output.

**Decision:** Each open terminal runtime has two views over the same controller:
Conversation and Raw. Conversation is the default and initially records only
actions Conduit performed itself: launch/reattach requests, exact native
composer submissions, local attachment paths, forwarded terminal selections,
and queued/delivered/failed terminal handoff. An entry request does not prove
that process attach succeeded. Live lifecycle remains an
observed controller state rather than invented history. Raw hosts the unchanged
SwiftTerm PTY and remains one action away for the complete live terminal view,
approvals, debugging, and direct CLI access.

The process starts independently of whether Raw is mounted. Conversation events
are per runtime and separate from project-scoped work-session receipt events.
Forwarded selections retain their explicit unverified-terminal-output origin.
No assistant response, approval, waiting state, completion, or verification
result is inferred merely because prose appeared in the terminal.

**Rejected alternatives:** Parsing all terminal output into assistant messages
would turn cursor movement, redraws, commands, tool logs, and agent claims into
false structure. Mounting an invisible terminal to start the process could
steal focus and distort layout. Replacing SwiftTerm would violate the real-PTY
contract.

**Consequences:** Agent-specific adapters may later add capability-declared,
source-labelled events, but adapter failure must always degrade to Raw.
Conversation history is intentionally conservative and initially process-local;
future persistence requires a reviewed retention and provenance policy. The
native composer is shown in Conversation, while Raw prioritizes terminal space
and direct terminal input.

---

## D-023: Task-session continuity retains metadata, not transcripts

**Status:** Accepted (task-history persistence contract)

**Context:** Conversation-first navigation needs stable task identity across
runtime attempts, editable titles, pins, archives, workspace scoping, and an
honest distinction between running, reconnectable, and recently closed work.
Persisting the current in-memory presentation array would also retain prompt
and attachment content and would turn a mutable UI projection into history.
Using project metadata as the session catalog would instead create a second
project control plane beside MainFrame.

**Decision:** `TaskSessionID` identifies one user-facing continuity record;
`RuntimeAttemptID` identifies one concrete PTY/tmux attempt. Task-session
history is append-only local operational metadata under
`~/.conduit/task-sessions/`. It may retain a standardized MainFrame root or
project path, fallback title/slug, agent name, deterministic default title,
explicit title override/reset, pin/archive changes, and operational lifecycle
facts. It does not retain prompts, attachment references, raw terminal bytes,
agent prose, approvals, generated summaries, or inferred completion.
Agent identity is optional: a resumed session with no recorded identity retains
nil rather than writing a presentation placeholder such as `Unidentified`.

The session catalog is a pure, rebuildable index over those local events plus
current live-runtime observations, external reconnectability observations, and
the current MainFrame file scan. Cached or in-memory catalog rows are never
project authority and never form a shadow project database. MainFrame remains
authoritative for current project metadata; stored title/slug values are
historical fallbacks only.

Corrupt, partially understood, or unsupported-version task-session logs are
preserved for diagnosis rather than deleted during recovery. A failed or stale
external observation cannot turn absence into a closed or unavailable claim.
It also cannot authorize a duplicate direct-PTY fallback when Conduit cannot
determine whether the named tmux session exists.
No operational state means completed, successful, correct, or verified.

**Rejected alternatives:** SQLite or another Conduit-owned project registry
would create a competing project source of truth. Persisting the conversation
projection would silently introduce transcript retention. Importing
work-session receipts as task history would conflate a project-level evidence
record with one terminal task.

**Consequences:** The project-scoped `WorkSessionEvent` and append-only receipt
stream remain separate and unchanged. Explicit export or later transcript
retention requires another reviewed decision. A future on-disk derived index
must be safe to delete and rebuild from the append-only metadata logs.

---

## D-024: Task history is primary navigation; runtime actions remain explicit

**Status:** Accepted (conversation-first information architecture)

**Context:** D-022 defines Conversation and Raw as two views over one live
runtime. D-023 defines the metadata that can survive after that runtime is
gone. The application still needs one navigation contract that joins those
pieces without turning a project picker into the main workspace, treating a
history click as permission to launch a process, or presenting a receipt as a
conversation transcript.

**Decision:** The left rail is a task-history catalog. It groups non-archived
records as Pinned, Active, and Recent, exposes Archived only when the operator
asks for it, and keeps tmux recovery not represented by loaded task history in
a visually secondary Discovered section. The default filter is **All
MainFrame**. A project selected from the
scope browser narrows the catalog using the current MainFrame scan; it does not
create or update project records.

New Task requires an explicit enabled agent profile and an explicit scanned
MainFrame scope. It may default to the scope most recently submitted through
that sheet, but the operator reviews both values before launch. Selecting an
existing task changes navigation only. It may focus a runtime that is already
open, but it never starts, attaches, or resurrects one. Reconnect, Resume,
Leave, and End remain separate controls with labels that describe the runtime
effect.

For an open runtime, Conversation is the default central surface and Raw is a
first-class secondary surface available from the segmented control, the
Conversation header, or `⌘2`. Raw hosts the real SwiftTerm PTY/TUI and remains
the live execution authority. Neither Raw bytes nor the in-memory Conversation
projection are written into task history. After relaunch, a task can therefore
show identity, scope, agent, last activity, and operational availability, but
not prior prompts or agent replies.

Task history and work-session receipts remain separate. Task history is local
operational continuity under `~/.conduit/task-sessions/`; work-session events
remain project-scoped evidence inputs whose rendered receipts append under
MainFrame `20_live/conduit/sessions/`. Neither stream may infer completed,
successful, correct, or verified work from terminal prose or a runtime ending.

**Rejected alternatives:** A project-first rail would keep the old
terminal-application information architecture. Reconnecting on row selection
would turn navigation into an external side effect. Persisting Conversation or
Raw would add transcript retention without a reviewed policy. Treating receipts
as task messages would collapse operational continuity and evidence into one
misleading timeline.

**Consequences:** Historical task selection is safe to browse. Reconnection is
deliberate rather than a row-selection side effect. The normal workspace feels
like an agent application while the full terminal remains one action away. A
future adapter may add source-labelled events, but it must declare its
capability and fall back to Raw; it cannot weaken the no-inference or
no-transcript-retention boundaries without another decision.

---

## D-025: Prompt readiness waits for bounded output quiescence

**Status:** Accepted (conversation-first hardening)

**Context:** D-016 replaced a fixed pre-launch forwarding delay with
output-gated delivery, but its first-output/no-timers clause treated the first
byte as a usable prompt boundary. A tmux attachment can emit redraw bytes before
the attached CLI has reached a stable input surface.

**Decision:** Preserve D-016's paste semantics and serialized delivery, but
supersede its readiness clause. After the first observed output byte, Conduit
waits until output has been quiet for 0.6 seconds. If output continues, an
eight-second hard cap measured from that first byte bounds the wait. These
timers govern when queued prompt bytes are handed to the terminal only. They
must never be interpreted as evidence that an agent is ready, working,
finished, correct, or verified. Conversation labels the resulting native
composer handoff **Queued**, **Sent to terminal**, or **Delivery failed**.

**Rejected alternatives:** Flushing on the first byte can race tmux attach
redraw. Returning to a fixed delay ignores observed output. Treating output
quiescence as agent state or completion would invent structured facts from
terminal behavior.

**Consequences:** After output begins, a queued prompt waits for an observed
quiet boundary unless the hard cap expires first. The handoff remains bounded
when startup output continues, and its label remains deliberately narrower than
an agent-response or completion claim.

---

## D-026: Conversation history is local, append-only, and source-labelled

**Status:** Accepted (conversation-history retention)

**Context:** D-022 made Conversation the default but kept it process-local.
D-023 and D-024 deliberately retained task metadata without content until a
retention and provenance policy was reviewed. That made the first redesign
honest, but it also meant an agent response visible in Raw did not appear in
Conversation and selecting a sidebar task after relaunch showed no thread.
Independent agent CLIs still do not provide one common structured event stream.

**Decision:** Supersede only the no-conversation-retention clauses in D-022,
D-023, and D-024. New Conversation events are retained in a separate local
append-only stream at
`~/.conduit/conversations/<TaskSessionID>.jsonl`. Task metadata remains under
`~/.conduit/task-sessions/`; MainFrame project files and work-session receipts
remain separate authorities.

The retained stream may contain launch/reattach requests, exact native-composer
text, local attachment path references, terminal delivery state, and bounded
rendered output. Attaching a path does not itself copy that file into history,
but any text the CLI renders—including file contents or secrets—can enter a
retained **Derived from Raw** revision. Each rendered revision is capped at
16,000 characters; append-only earlier revisions remain in the local source.
The stream does not store an unprocessed PTY byte transcript. Files are
owner-readable and owner-writable only; the directory is owner-accessible only.
Event updates are immutable revisions in the JSONL source. A read projects the
latest valid revision without rewriting or deleting earlier bytes.

Generic terminal output is derived from SwiftTerm's rendered buffer or a
rendered tmux pane snapshot captured after prompt delivery. It is always labelled
**Derived from Raw** and may include prompt echo, tool logs, status chrome, or
agent prose. Output quietness may display as **Output quiet**, but never as
finished, accepted, successful, correct, or verified. Conduit shows generic
runtime progress as **Agent activity**. It does not reconstruct or claim access
to private chain-of-thought. A future capability-declared adapter may add
tool-reported assistant messages, visible reasoning summaries, approvals, and
turn boundaries, but adapter failure must degrade to Raw.

Raw remains the execution authority and one action away. Approval-looking
terminal prose is not a native approval. Agent claims about files, tests, or
completion are not evidence. Existing tmux scrollback is not silently imported
when local history is first enabled. A content-free task marker records that a
task entered the retention contract after its first successful conversation
append. If marked history is later absent, Conduit calls it unavailable; an
unmarked task remains a possible pre-retention or never-recorded gap. Neither
case is presented as a complete empty transcript.
Selecting retained history remains read-only and never starts or reconnects a
process.

**Rejected alternatives:** Regex-stripping PTY byte chunks cannot safely handle
split UTF-8, control sequences, cursor movement, or TUI repaint. Calling generic
terminal prose an assistant message or “thinking” would invent structure.
Putting content into the task-session metadata stream would weaken its
navigation-only boundary. Treating Raw as the only history would keep the app
terminal-first and would not survive relaunch in the native thread.

**Consequences:** New prompts and source-labelled rendered output survive
relaunch in the same sidebar task. The conversation directory can contain
sensitive prompt text, path references, file contents, secrets, tool output,
and terminal chrome that the CLI rendered. It must not be uploaded or indexed
silently. The 16,000-character bound applies to each projected revision, not
the append-only source as a whole. There is no automatic expiry, pruning,
transcript-body search, or destructive clear-history control in this slice.
Structured adapter work remains a separate, version-gated phase.

---

## D-027: Conversation readability, attachment feedback, and host envelope

**Status:** Accepted (daily-driver UX and harness affordances)

**Context:** Operator smoke of conversation history showed that long
Derived-from-Raw cards were hard to read (auto-scroll to end, sparse TUI
chrome, no inner scroll), attachment success was easy to miss, and agents
inside Conduit had to forensically discover host identity.

**Decision:**

1. Conversation output cards use denser monospaced display text, collapse
   blank runs for presentation only, clamp tall blocks with internal scroll
   plus Expand/Collapse, and stop force-scrolling the whole thread on every
   live character tick. Outer auto-follow is optional and can be paused.
2. Attachment actions report clear status, show chips with image thumbnails
   when possible, and surface an attached count on the paperclip control.
3. CLI (non-shell) prompt *delivery* may prepend a compact `<<CONDUIT_HOST…>>`
   envelope (task, project, agent, surface, tmux, attachment count). Conversation
   still stores the human composer text separately. The envelope is host
   context only, not completion or verification. Shell prompts stay unwrapped.

Capture-unavailable notices include the concrete reason string so operators can
distinguish empty baseline, surface change, and capture failure.

**Rejected alternatives:** Mutating retained JSONL to “clean” TUI text would
rewrite evidence. Injecting host envelopes into human-visible Conversation
prompt bubbles would blur what the operator typed. Auto-expanding every output
card would recreate the unreadable full-height problem.

**Consequences:** Reading long agent turns is practical in Conversation without
claiming structured assistant messages. Agents can see intentional host context
when Conduit delivers a CLI prompt. Attachment UX no longer depends on noticing
a silent chip.

---

## D-028: First-prompt capture may prompt-anchor; empty baselines stay open

**Status:** Accepted (Raw-derived cold-start recovery)

**Context:** Operator smoke showed first OpenCode prompts often failed with
“could not be separated safely” while a second prompt on the same session
succeeded. Empty or unusable pre-delivery baselines and full TUI repaints were
the main causes.

**Decision:**

1. Tmux baseline capture retries briefly; empty same-surface baselines remain
   *available* so Conversation can open a capture window instead of hard-failing.
2. When the baseline is empty, or screen-delta finds no stable LCS anchor,
   Conduit may project text **after** an exact whole-line prompt match in the
   current rendering (`promptAnchored`). Decorative TUI prefixes (box drawing,
   simple markers) before the prompt text are allowed; partial/prefixed prompt
   paraphrases are not guessed.
3. Oversized comparisons still decline without importing the whole screen.
4. Notices continue to name the concrete unavailable reason when projection fails.

**Rejected alternatives:** Importing the full current pane when baseline is empty
would mix pre-prompt history into Conversation. Lowering LCS thresholds alone
would still fail empty-baseline cold starts.

**Consequences:** First prompts on TUI agents are more likely to show a
Derived-from-Raw block when the delivered prompt text is visible as a line.
Projection remains best-effort and source-labelled; Raw stays authoritative.

---

## D-029: Settings surface, permission modes, Conversation menu controls

**Status:** Accepted (daily-driver settings and HITL continuity)

**Context:** Agent CLIs such as Antigravity stop for per-file and per-command
approvals. Operators had to open Raw to answer menus, which ended Conversation
capture. Settings existed only as a flat form.

**Decision:**

1. Expand Settings into a sidebared surface: General, Appearance, Agents,
   Conversation, Privacy, Utilities — not a Codex-scale product console.
2. Each agent profile stores an ``AgentPermissionMode`` (default / accept edits /
   full auto / plan). Conduit injects well-known launch flags per CLI on the
   **next** process start; it does not rewrite a live process mid-session.
3. Conversation shows a control strip: permission-mode menu, number keys 1–4
   (+ Enter), Esc, and arrows. These inject into the live PTY **without** firing
   the Raw direct-input boundary, so capture can continue.
4. Host-envelope injection, follow-latest default, and the control strip itself
   are Conduit settings toggles.

**Rejected alternatives:** Auto-pressing “Yes” for every agent approval would
bypass the agent’s policy model. Requiring Raw for every menu choice forces
capture interruption.

**Consequences:** Daily-driver permission posture is configurable per agent.
Approval menus can be answered from Conversation. Raw remains available for full
TUI interaction and still ends capture when used for direct typing.

---

## D-030: Stream Conversation, left app chrome, right inspector

**Status:** Accepted (workstation layout)

**Context:** Chat bubbles and flat task lists felt unlike peer agent apps.
Operators wanted continuous transcript, agent-grouped history, bottom-left app
chrome, and a right utility inspector (files, git review, session).

**Decision:**

1. Conversation is a **continuous stream** of presentation events with inline
   provenance (You / delivery / Derived from Raw footers), not chat bubbles.
2. Composer uses **Return to send** and **Shift-Return** for newlines (⌘Return
   remains send).
3. Left rail groups open history **by agent**, with a footer for Settings,
   Doctor, Resources, Root, Refresh.
4. Trailing **Inspector** tabs: Session, Files, Review (git status), Context.
   Focused density keeps the inspector as a dismissible overlay; Balanced /
   Operator pin it as the third column.

**Rejected alternatives:** Full IDE browser/side-chat; auto-approving agent tools
inside Conduit; replacing Raw with the stream.

**Consequences:** Conduit reads as a three-region workstation. Honesty labels
remain on every projected event. Git and path lists are observational only.

---

## D-031: Conversation is a turn document; structured adapters may feed it without replacing Raw

**Status:** Accepted (workstation Conversation continuity)

**Context:** Operators asked for streaming *conversation state* (growing turns
in a document surface), not a live window into the terminal. Derived-from-Raw
projections remain necessary for agents that only speak TUI. Peer apps feel
continuous because they receive structured assistant events; Conduit cannot
honestly invent those from ANSI alone. A wrapper harness around agent CLIs is
an attractive path to better Conversation data.

**Decision:**

1. **Conversation presents operator turns** — Conduit-recorded user prompts and
   growing assistant projections, document typography, quiet source disclosure.
   Presentation may scrub pure TUI chrome (spinners, box edges, esc footers)
   without mutating retained JSONL. This does not claim the projection is a
   complete assistant transcript.
2. **Raw remains the live terminal authority** for attach, TUI interaction,
   debugging, and any agent state still only visible in the PTY. Conversation
   never supersedes Raw.
3. **Structured adapters are additive, source-labelled.** When an agent (or a
   Conduit-attached harness) can emit capability-declared events — ACP streams,
   JSONL sidebands, or other explicit protocols — Conversation may show those as
   `toolReported` / `structuredAdapter` events. Adapter failure or absence must
   degrade to Derived-from-Raw and ultimately to Raw. Structured events do **not**
   erase Raw; they are a second labelled channel over the same work.
4. **A Conduit-attached harness is an adapter host, not a second brain.**
   Preferred shape: optional per-agent launch wrappers or side-channel listeners
   that (a) still start the real CLI in a real PTY/tmux session Conduit owns,
   (b) surface structured events when the agent supports them, (c) never
   re-interpret terminal prose as verified completion. A harness that *replaces*
   the PTY with a fake chat transport is rejected for daily-driver agents that
   still need native TUI approvals and tmux durability.
5. **Prompt→output linkage for turn grouping** records only that Conduit opened
   capture after delivering a specific prompt. It is not an ACP turn ID and must
   not be treated as proof of a structured response boundary.

**Rejected alternatives:** Treating Conversation as a second live terminal;
silently promoting screen paint into “assistant messages” without authority
labels; wrapping agents so operators lose Raw access; auto-approving tools
inside a harness as if that were Conversation UX.

**Consequences:** Chrome and scrubbing can ship immediately on Derived-from-Raw.
High-quality continuity still depends on agent-specific adapters or a thin
harness that speaks a real protocol. Epistemic contract holds: authority labels
stay first-class; Raw stays one click away.

---

## D-032: Model choice is provider-neutral, launch-bound, and source-labelled

**Status:** Accepted (model-selection and composer limits; catalog coverage expanded)

**Context:** Conduit needs one model chooser across independent agent CLIs,
including local Ollama and OpenCode models, without pretending that every CLI
shares the same provider API or exposes the same quota/context metadata.

**Decision:**

1. Store an optional model, launch style, and context-window value on the
   agent profile. Launch applies via `--model` / Ollama positional args. When a
   live PTY exists and the CLI has a known switch surface, Conduit may inject a
   best-effort slash sequence; the operator must confirm in Raw. Otherwise the
   choice is next-launch only with honest status copy.
2. Discover model IDs through the installed CLI when possible:
   - OpenCode `models`, Cursor `models`, Ollama `list`/`ls`, Grok `models`,
     Antigravity `models`, Codex `debug models` (JSON).
   - Claude Code and Gemini CLI lack a non-interactive list: surface their
     documented aliases / known IDs and label them as aliases, not as a
     vendor inventory dump.
   - Aider uses a practical shortlist plus local Ollama tags and sampled
     `--list-models` prefixes (full Aider catalog is intentionally not mirrored).
3. Show account usage only when a vendor/tool reports it. Show the composer
   context ring as a labelled visible-content estimate, never as provider token
   accounting. Unknown values stay unknown.
4. Keep free/cloud/local labels descriptive rather than promises of unlimited
   access. OpenCode free models and Ollama cloud tags are discoverable, while
   remaining pool/quota claims require a separate authoritative source.

**Rejected alternatives:** A Conduit-owned full provider registry as the source
of truth, silently rewriting a live session without operator confirmation,
deriving vendor quota from PTY output, or turning local token totals into
remaining cloud allowance.

**Consequences:** New Task and the active composer share one model-selection
surface. Provider adapters can be added later without changing the profile or
honesty boundary; interactive acceptance still needs real local launches.

---

## D-033: Free-tier CLI access is not provider accounting

**Status:** Accepted (free-tier CLI shortlist)

**Context:** MainFrame research separates subscription/free CLI access from
direct provider APIs and from the permanent coding harness. The live workstation
has OpenCode, Ollama, Cursor Agent, Gemini CLI, and Aider available, while the
research also names API-only pools and uninstalled candidates.

**Decision:**

1. Keep OpenCode, Ollama, Cursor Agent, and Gemini CLI as cloud-capable/local
   CLI profiles, with free access described as authentication-dependent rather
   than guaranteed. Keep Aider as a provider-neutral local/BYOK profile.
2. Do not add Gemini/DeepSeek HTTP APIs or a `cloud-llm-router` profile to the
   PTY launcher. They are a separate adapter boundary and are not verified
   Conduit agent executables.
3. Do not hardcode free model SKUs, quota values, or context limits. Discover
   what the CLI exposes; otherwise leave the model catalog or account allowance
   unknown and let the operator configure a model ID.
4. Park Docker Agent, Goose, OpenHands, Open Interpreter, and similar candidates
   until an installed executable and a bounded launch smoke justify a profile.

**Consequences:** Conduit adds useful access paths without turning a stale free
tier into a promise. The model menu remains CLI-owned, and the circular meters
remain honest about what Conduit can observe versus what the vendor controls.

---

## D-034: Task-first chronology and contextual companions define the default workspace

**Status:** Accepted (rail, state-language, and responsive inspector implemented)

**Context:** D-024 established Pinned / Active / Recent task history and
side-effect-free selection. D-030 later changed the default rail to agent groups
and described density-specific inspector composition. Daily-driver review found
that agent grouping obscures recency, the fixed inspector starves Conversation at
small widths, and a dormant horizontal operator strip would make decoration
compete with the selected task. Conduit still needs a restrained RPG identity
without turning sprites, quiet output, receipts, or diagnostic styling into state
authority.

**Decision:**

1. The default task rail is `Pinned` → `Active` → `Recent`, chronological within
   each section and with active/reconnectable pinned tasks first. Agent and
   project remain row metadata. Search, archive, and discovered-session recovery
   remain separate existing surfaces.
2. Selecting a task remains presentation-only. Reconnect, restart, launch, send,
   leave, end, archive, and receipt actions remain explicit controls.
3. A companion may appear only for the selected exact known profile in the rail
   and selected Conversation header. It is presentation-only, accessibility-
   redundant, and follows observed terminal state. The unmounted launchable
   `OPERATORS` strip is not part of Focused, Balanced, or the default workspace.
4. State copy composes observed lifecycle, activity, availability, and authority.
   Quiet running is `Attached · output quiet`; Raw distinguishes live PTY,
   detached buffer, exited buffer, and failed/blocked states. None is completion
   or verification evidence.
5. Focused keeps the inspector as a temporary trailing overlay at every width.
   All modes overlay below 1440 points; at 1440+ Balanced pins 320 points and
   Operator pins 336 points. Responsive rail ranges are 232–244, 244–260, and
   260–280 points. Width changes geometry, never the saved density preference or
   terminal/runtime identity. Fresh installs start with Inspector closed.
6. Conversation remains default and Raw remains the same mounted PTY. The design
   adds no second terminal, inferred completion state, provider behavior, asset
   pipeline, or dependency.

**Supersedes:** D-030 decision point 3 (agent-grouped default rail) and the part
of decision point 4 that treats inspector pinning as density-only. The remaining
D-030 stream, Conversation, and contextual-inspector boundaries still stand.
D-021’s sprite truth contract and D-024’s selection contract remain in force.

**Rejected alternatives:** Agent-first default grouping; a permanent horizontal
roster/operator launcher; sprites as launch/reconnect controls; automatic density
switching; `Ready`, XP, streaks, levels, progress bars, confetti, or receipt colour
as completion/health semantics.

**Consequences:** The workspace protects Conversation at the 1080-point minimum
without requiring a manual panel collapse. Inspector focus enters its section
control, returns to the prior responder when possible, and falls back to the
workspace toggle; Escape and Reduce Motion are explicit. Future Cameron-supplied sprite art remains a
separate provenance-gated insertion; optional built-in profiles remain generic
or absent until explicitly configured and supplied with accepted assets.

---

## D-035: Dedicated companion art is catalogued and admitted atomically

**Status:** Accepted (sprite insertion seam implemented)

**Context:** D-021 made sprites presentation-only and D-034 placed the selected
companion contextually. The original implementation kept pose filenames and
bundle loading private to the view, matched either a normalized name or command,
and loaded one image at a time. A similar or conflicting profile could receive
the wrong identity, while a partial bundle could alternate dedicated and generic
art across lifecycle states.

**Decision:**

1. `AgentSpriteCatalog` is the single identity/resource contract. It owns the
   fixed six filenames and explicit full-profile-name + executable-basename
   signatures. Both fields must match the same registration after only trimming
   and case folding. Punctuation, substrings, wrappers, one-field matches, and
   conflicting fields fail closed to the generic placeholder.
2. Identity eligibility and artwork readiness remain separate. Dedicated art is
   admitted only when all six images decode, all six paths appear in
   `SHA256SUMS`, and the provenance ledger names the skin. Any missing,
   unreadable, unmanifested, partial, or unrecorded set uses the generic
   placeholder for every state.
3. Available has no launched lifecycle pose and uses a neutral generic
   presentation. Launched poses map only observed starting, output-active,
   running-quiet, detached, exited, and failed state. Exited explicitly does not
   imply success.
4. Sprite views remain hidden from VoiceOver. Their containing task/session
   labels disclose dedicated or generic-placeholder art while preserving agent,
   lifecycle, activity, availability, backend, and Raw authority as text.
5. P0 pose changes are static and immediate, including under Reduce Motion. The
   periodic observation of terminal state is not decorative animation.
6. A future approved skin requires one central catalog id/signature, the six
   canonical files, a provenance-ledger entry, and six unique lowercase hashes. It requires no
   provider, PTY, package dependency, SwiftUI layout, or external runtime asset
   fetch. The external sprite repository remains design/approval reference only.

**Rejected alternatives:** Fuzzy name matching; command-only identity; partial
pose fallback; remote runtime fetching; a generated-asset pipeline inside
Conduit; available reusing exited art; animated status theatre; treating a
placeholder or dedicated character as availability, quality, completion, or
verification evidence.

**Consequences:** The existing Claude and Codex files remain byte-for-byte
unchanged and grandfather their varied canvas sizes. The other eight built-ins
remain honestly generic. Focused tests bind exact signatures, cue mapping,
complete/partial admission, source hashes, placeholder labels, and immediate
motion policy before a builder can add another dedicated identity.

---

## D-036: Inspector width is operator-controlled and account usage is explicit

**Status:** Accepted (resizer and manual-only account refresh implemented)

**Context:** D-034 established responsive Inspector overlay/pinning and fixed
300/312/320/336-point widths. The task rail already had a native draggable
splitter, while the trailing Inspector could not be adjusted. Separately,
presentation-only account meters refreshed on view appearance: opening a
non-Shell Conversation, the default Session Inspector, or the usage sheet could
request access to Claude Code's Keychain credential even though account usage is
not required for any task/session operation.

**Decision:**

1. Keep the Inspector outside `NavigationSplitView` and retain one stable
   workspace/terminal topology. Overlay/pinned mode remains a pure function of
   window width and density; user sizing never remounts, launches, reconnects,
   selects, or changes PTY/tmux authority.
2. The existing responsive values remain defaults. A leading splitter accepts
   pointer drag, focused left/right arrows, and VoiceOver adjustable actions;
   double-click or a named reset action returns to the responsive default. The
   committed preference persists independently of density. The visual handle
   stays a custom SwiftUI target; its accessibility representation is an AppKit
   `NSSlider` so AX clients receive a stable title, value, help, and reset
   action (SwiftUI `Slider` left `AXTitle` empty in live enumeration).
3. Clamp the panel to 300–420 points and dynamically preserve at least 520 points
   of Conversation. A temporary narrow-window clamp does not overwrite a wider
   stored preference. Width changes are immediate and add no motion path.
4. Account usage loads only after an explicit Refresh from Inspector › Usage
   or the full usage sheet. Session context no longer embeds the account meter,
   and Conversation/Inspector/sheet appearance performs no credential or
   provider-account work.
5. Claude's optional Keychain read is noninteractive. If its access control
   requires UI, the meter fails closed instead of summoning SecurityAgent. A
   missing account snapshot remains presentation absence, never agent
   unavailability, launch failure, quota evidence, or task state.

**Refines:** D-034 decision point 5: 320/336 are responsive defaults rather than
immutable large-window widths. D-032's source-labelled account data boundary
still applies.

**Rejected alternatives:** A three-column split view that reparents the terminal;
allowing the Inspector to consume the Conversation minimum; changing density on
drag; animated width changes; automatic credential reads; modifying Keychain
ACLs; treating missing account meters as provider health.

**Consequences:** The right panel now has the same direct resize affordance as
the left rail without becoming a second terminal/container authority. Normal app
use does not request Claude Keychain access. Operators who choose Refresh receive
only available, source-labelled account reports; all core agent/session behavior
remains independent.

---

## D-037: Attention board is a read-only MainFrame projection

**Status:** Accepted (Inspector card + sheet implemented)

**Context:** The workstation Focus Board already ranks operator attention from
recorded truth feeds. Conduit needed the same daily-drive surface without
becoming a second writer of focus authority or blending into the left-rail
agent inbox.

**Decision:**

1. Port the workstation ranker into `ConduitCore` as a pure projector. App
   loaders read MainFrame-relative files and may run existing `bin/ingest-status
   --json` with a short timeout. Conduit does not call the workstation HTTP API.
2. The operator-facing name is **Attention**. Types may keep `FocusBoard`.
   Placement is Inspector card + full sheet (Usage-style). Refresh is manual.
3. Weekly proposal and approved `current.yaml` are display overlays only. There
   is no approve, promote, or write path to focus authority, STATE.md, eval
   registries, or session-close apply.
4. Missing or unreadable feeds produce an explicit insufficient / unavailable
   state. That is not an all-clear. Green weekly means a recorded
   `all_passed=true` within the ADR-036 window.
5. This board is distinct from `AgentInboxAttention` reconnect counts and from
   Doctor “Attention” health copy.

**Rejected alternatives:** Embedding the pixel office; merging into the task
rail; a 25s background poller; shelling `git status` or `eval-schedule check`;
an in-app approve button.

**Consequences:** Operators can daily-drive the same ranked feeds inside
Conduit. Ranking rules stay faithful to the workstation contract until a later
session reshapes UX after real use.

---

## D-038: Codex app-server is the preferred Codex transport

**Status:** Accepted (2026-08-13)

**Context:** Daily Codex work is still the interactive `codex` TUI in a
Conduit-owned PTY/tmux session (D-003, D-015). Conversation then projects
screen paint (`derivedFromRaw`). OpenAI documents `codex app-server` as the
JSON-RPC control plane used by the Codex VS Code extension and other rich
clients of the same harness: threads, turns, items, approvals, streaming,
skills, plugins, MCP, model list, and ChatGPT login. Conduit already spawns a
short-lived app-server process for account rate limits (D-036) and then kills
it. D-031 allows structured adapters as an additive labelled channel but still
requires the real CLI to start in a PTY. For Codex, that PTY-first rule is the
wrong owner: app-server *is* the official session host, and the TUI can attach
with `codex --remote`.

**Decision:**

1. For the Codex profile only, a long-lived `codex app-server` process is the
   preferred session host. Conversation is fed by app-server events labelled
   `structuredAdapter` / `toolReported`.
2. Raw remains available as an optional attach to that same server
   (`codex --remote` or an equivalent documented listener), or as an explicit
   PTY fallback profile. Conversation does not replace Raw.
3. This is not a fake-chat transport and does not relax D-031 for other
   agents. Claude, Grok, Gemini, OpenCode, and Shell stay PTY-primary until
   they expose an equally explicit protocol.
4. Composer send uses one path: app-server `turn/start` / `turn/steer`. Do not
   dual-submit the same prompt into a TUI PTY.
5. Permission requests arrive as app-server server-requests and render as
   Conduit SwiftUI approvals. Do not auto-approve for UX (D-029).
6. App-server turn completion is not verified success (D-011 / D-022).

**Rejected alternatives:** Treating app-server as another usage-only probe;
replacing every agent TUI with a chat client; scraping the Codex desktop app;
billing Codex through the OpenAI API just to get structured events.

**Consequences:** Codex becomes the first first-class structured worker.
`AccountUsageService` should prefer a live app-server when one exists.
Project and workbench `AGENTS.md` now allow Codex to use app-server as the
session host. Other agents remain PTY-primary.

---

## D-039: External orchestrator clients, not a Conduit router

**Status:** Accepted (2026-08-13)

**Context:** D-007 forbids autonomous orchestration in v0.x: Conduit launches,
displays, and communicates with agents but does not route tasks, judge
completion from prose, or run agent-to-agent loops by default. That remains
correct for *Conduit*. The operator also wants ChatGPT **chat** (separate from
the Codex/agentic pool) to plan and delegate by calling Conduit tools. There
is no supported API to embed ChatGPT chat inside Conduit on subscription chat
quota. The supported invert is ChatGPT Developer Mode → Secure MCP Tunnel →
a loopback Conduit MCP server. The phone-bridge plan already specified a
second client of AppModel with the same session verbs.

**Decision:**

1. Conduit itself stays deterministic. It does not gain a hidden LLM router or
   `@team` auto-dispatch.
2. Capability-scoped **external orchestrator clients** may call a single
   Conduit session API (list / status / create / send / interrupt / close).
   First client: ChatGPT chat via Developer Mode + loopback MCP + official
   Secure MCP Tunnel. Later client: the phone bridge, same verbs.
3. Every spawn or send is one explicit tool call the operator can see in
   Conduit, with origin `chatgpt` | `composer` | `phone`. Multi-hop and
   agent-to-agent loops stay forbidden until a later ADR.
4. ChatGPT-originated `send_prompt` is not permission to run destructive
   tools. Approvals stay Mac-side.
5. Write tools stay off the MindGraph daemon. Conduit MCP binds loopback only
   on a dedicated port, off by default, with a local token even on localhost.
6. ChatGPT receives summaries, paths, and authority labels — not raw PTY
   transcripts or vault dumps. ChatGPT **Work** is not an orchestrator
   (it shares the Codex/agentic pool).
7. This does not change I15 (read-only Ask MainFrame). Spawn/steer is a
   different trust class.

**Rejected alternatives:** Embedding or scraping ChatGPT; putting write tools
on `:8000`; Funnel or a public plugin listing; treating ChatGPT as a Conduit
seat that impersonates subscription chat via the API.

**Consequences:** Softens D-007 only for operator-visible external tool calls.
Phone-bridge Unit 2 and the ChatGPT connector share one session API.
Implementation waits for D-038’s Codex adapter (Phase 1) before enabling
write tools (Phase 3).

**Refined 2026-08-17:** `conduit_session_events` is the incremental,
cursor-bounded read surface for Conversation events and observed turn state.
It remains observation, not verification. PTY-derived output stays
`derivedFromRaw` and cannot claim turn completion. Structured adapter events
stay `toolReported`. The tool does not export raw transcripts, credentials,
or chain-of-thought, and does not read artifact file contents.

**Refined 2026-08-18:** The same tool now also exports an additive
supervisory observation snapshot: `turn.thread_id_source` (`live` |
`persisted` | `unavailable`), optional `runtime_attempt_id`, `observed_at`,
last-output/checkpoint state, `provider_progress` (`structured` when a live
adapter is present, otherwise `unavailable`), and `input_state`
(`approval` | `unknown` | `none`). PTY checkpoints (`output_live`,
`output_quiet`, `output_unobserved`, `capture_closed`) remain observational
and never mean turn completion. Event identity, cursor advancement,
truncation, interrupt acknowledgement, and create-task readiness stay
unchanged. No new MCP tool is added.

---

## D-040: Per-agent first-party structured hosts

**Status:** Accepted (2026-08-19)

**Context:** D-038 made `codex app-server` the Codex session host and left
every other agent PTY-primary until it exposed an equally explicit protocol.
Probes on this machine found those protocols: Grok ACP stdio, OpenCode HTTP +
SSE, Claude and Antigravity `stream-json`. Gemini CLI `--acp` with
oauth-personal Code Assist is ineligible; with `GEMINI_API_KEY` it completes
`session/prompt`. Gemini models also remain an OpenCode backend.

**Decision:**

1. Prefer the richest first-party surface per profile, with explicit PTY
   fallback if that host fails to start:
   - Codex → `app-server` (unchanged, D-038)
   - Grok → ACP `grok agent --no-leader stdio`
   - OpenCode → one Conduit-leased `opencode serve` (HTTP + SSE)
   - Claude → `claude -p --output-format stream-json --verbose`
   - Antigravity → `agy -p --output-format stream-json`
   - Gemini CLI → ACP `gemini --acp` (API key; not Code Assist oauth)
   - Shell and other profiles stay PTY
2. Do not flatten those protocols into one RPC. Conduit owns task identity,
   approvals, receipts, and process leases; each adapter keeps its native
   session/turn/completion events.
3. Do not auto-approve. Do not pass Grok `--always-approve`. Do not extract
   subscription tokens or impersonate vendor APIs.
4. OpenCode's leased server is not a session. Many Conduit tasks may share
   one serve. Gemini and local Ollama models are OpenCode *backends*, not
   Conduit agent profiles.
5. MCP `conduit_list_adapters` reports declared launch surfaces. Create/send
   already use the preferred host once the profile is selected.
6. Adapter turn completion is still not verified success (D-011 / D-022).

**Rejected alternatives:** One ACP shim for every vendor; keeping PTY as the
only host after the probes passed; treating Code Assist oauth as Gemini ACP
eligibility; multiple uncoordinated `opencode serve` processes.

**Consequences:** D-038 item 3 (other agents stay PTY-primary) is superseded
for Grok, OpenCode, Claude, Antigravity, and Gemini CLI. Do not run Gemini
CLI ACP and Antigravity as two Google workers on the same task. Raw remains
for TUI debugging and for profiles that have no structured host.

**Refined 2026-08-19:** Gemini CLI ACP is preferred only with an API key.
oauth-personal still returns Code Assist `IneligibleTierError`. OpenCode
`google/*` stays a valid model backend on the OpenCode host.

---

## Deferred deliberately (not rejected forever)

- Autonomous routing and agent-to-agent loops  
- Automatic task-completion judgments  
- Hidden transcript indexing  
- Silent process resurrection  
- General-purpose process termination  
- MindGraph retrieval blending into the default loop  
- Private project wiring inside the repository  
- Embedding ChatGPT chat inside Conduit  
- Conduit-owned LLM router / `@team` auto-dispatch  

---

## Change control

Add a new `D-0xx` entry when architecture, safety boundaries, session durability, evidence rules, or packaging posture change. Prefer small accepted ADRs over silent README drift.

---

## D-041: MCP writes pass a bounded admission boundary

**Status:** Accepted (2026-08-20)

**Context:** D-039 put five write tools behind one setting, `enableSessionAPIWrites`.
That boolean is binary: once it is on, an external orchestrator can call
`conduit_create_task` as fast as it can emit tool calls, and nothing in Conduit
refuses the second, tenth, or fiftieth spawn. `MCPAdmissionController` in
`ConduitCore/ConduitSafety.swift` was written for exactly this job and then left
unreferenced. On 2026-08-20 it had zero call sites in `Sources/`, zero cases in
the selftest, and zero XCTest coverage. The 2026-08-18 host overload is the
failure it was designed to stop, and it was not in the path when that happened.

**Decision:**

1. Every Session API write passes the admission boundary before it reaches a
   runtime. Creates take a capacity reservation, prompts take a bounded queue
   slot, and reconcile, interrupt, and close consume the caller's write budget.
2. Validation runs before admission. A request naming an agent or project that
   does not exist is refused on its own terms and never spends create budget or
   holds a reservation.
3. A create that does not reach a started runtime returns its reserved slot.
   Capacity is committed only once a runtime exists for that task id.
4. Live-task capacity is released by an explicit lifecycle verb, `leaveTask` or
   `endTask`. A runtime that detaches or dies on its own does not free a slot,
   because Conduit has not been told the task is over.
5. The resource circuit breaker evaluates only the metrics this host actually
   samples: available physical memory, Conduit's own process-tree resident size,
   and prompt queue depth. Persistence queue depth has no sensor yet, so it is
   declared unmeasured rather than reported as a fabricated zero. A required
   metric that comes back unknown, stale, or over its limit refuses the write.
6. Caller identity is the `clientInfo` from the most recent `initialize` on the
   listener. A listener that has never seen an `initialize` refuses writes with
   `caller_identity_required`.
7. Idempotency is opt-in. `conduit_create_task` accepts an optional
   `idempotency_key`; an identical repeat returns the original task instead of
   starting a second one, and the same key against a different request is
   refused rather than silently reused.
8. A refusal is a structured payload carrying `code`, `detail`, and where
   relevant `retry_after_seconds` and the resource violations, so the caller can
   tell a rate limit from a capacity wall from an open circuit.
9. The shipped numbers live in `MCPAdmissionPolicy.conduitSessionAPI`, not as a
   literal buried in `AppModel`, and both test suites pin them. Loosening a
   limit should be a deliberate edit with a failing test behind it.

**Rejected alternatives:** Leaving the boolean as the only gate and relying on
the orchestrator to behave. Reporting unmeasured metrics as zero so the circuit
would close. Requiring an idempotency key on every create, which would refuse
every ChatGPT call, since ChatGPT does not send one. Freeing capacity on runtime
exit, which would let a crash loop reopen slots faster than an operator can see
what is happening.

**Limits chosen:** four live tasks per caller, six creates per caller per
minute, thirty writes per caller per minute, prompt queue four per task and
sixteen overall. The live ceiling is the protection; the create rate sits above
it deliberately, so a legitimate orchestrator can start its whole planned fleet
in one burst and meet the capacity wall rather than a rate wall. The create rate
then only binds on churn, which is its actual job: a create that fails to
provision hands its slot back, so without a rate limit a broken retry loop could
spin forever without ever occupying capacity.

**Evidence:** `conduit-selftest` 396 passed, up from 353. The XCTest suite runs
235 tests with `DEVELOPER_DIR` pointed at Xcode. Two live rehearsals through
`tunnel-client dev proxy`, the same dispatcher hop ChatGPT uses. The second, run
against the shipped limits, passed 14 of 14: create refused before any
`initialize`, unknown agent refused without spending budget, four tasks started
in one 2.5 second burst, fifth refused on capacity rather than rate, duplicate
create deduplicated to the original task while the fleet was full, same key
against a different request refused, and an explicit close returning a slot the
next create used. Receipt: `outputs/2026-08-20-mcp-admission-rehearsal.md`.

**Consequences:** Per-caller isolation is nominal rather than real: MCP `2024-11-05`
over HTTP has no per-request session id, this listener holds one bearer token
and closes every connection, so two clients sharing the token share a rate
bucket. Persistence queue depth stays unmeasured until there is a queue to
measure, and the owned-process-tree reading covers Conduit and its own
descendants, not agents that tmux has reparented. Fleet size is bounded by the
live-task ceiling instead.

## D-042: A structured adapter reports the agent's answer, not everything it saw

**Status:** Accepted (2026-08-20)

**Context:** D-040 put each agent on its first-party structured host. Every one
of those hosts multiplexes several streams down one channel: the model's answer,
the model's private reasoning, the operator's own prompt echoed back, tool
traffic, and lifecycle bookkeeping. Conduit's mappers picked text out of those
streams by pattern — `kind.contains("agent")` for ACP, "any part that has a
`text` field" for OpenCode — and appended whatever matched to one buffer.

Driven from the ChatGPT seat on 2026-08-20, a one-word turn came back as
`"Say PONG only.PONGPONG"`, recorded three times. Four separate faults stacked
into that one string: the operator's prompt was accumulated as agent output; the
snapshot channel (`message.part.updated`, which carries the whole part) and the
delta channel (`message.part.delta`, which carries an increment) were both
appended, doubling every token; completion is announced three times per turn and
each announcement appended another finished copy; and `message.updated` — the
only event carrying a role — was being discarded as belonging to a foreign
session, because the resolver read `info.id`, a *message* id, as a session id.

Gemini over ACP failed the same way for a different reason: `agent_thought_chunk`
contains the substring `agent`, so its private reasoning was concatenated into
the answer. `Reply with exactly READY.` returned
`"**Initiating System Integration**\nREADY. I've begun integrating..."`.

An orchestrator cannot act on that. It cannot tell reasoning from answer, cannot
tell its own prompt from the reply, and cannot tell one turn from three.

**Decision:**

1. Answer-bearing streams are named in an allowlist. A chunk kind or part kind
   that is not on the list contributes nothing to agent output. A new kind is
   silent until it is understood, rather than being merged in by a name match.
2. A stream is attributed before it is accumulated. ACP attributes by
   `sessionUpdate` kind; OpenCode attributes by the role of the part's message,
   learned from `message.updated`, and by the part's declared kind.
3. Snapshots replace, deltas extend. Text is held per part id, because OpenCode
   reports the same part on both channels and only the part id ties them
   together.
4. A part's kind is stated once, on its snapshot, and never repeated on its
   deltas. The id of a non-answer part is therefore remembered for the turn, or
   its deltas are indistinguishable from the reply.
5. Session identity is resolved only from a field that holds a session id.
   `info.id` on a message event is a message id, and may be read as a session
   only for `session.*` events.
6. A turn closes once. Repeated completion signals after the first are ignored
   until the next turn opens.
7. Where the two conflict, dropping suspected output is worse than including
   it: an unknown message id or an undeclared part kind is still accepted, so
   the rule cannot silently lose real agent output.

**Consequences:** The operator's reasoning stream is no longer visible through
the Session API at all. That is a deliberate narrowing — it was never legible
where it was, having been concatenated into the answer without a separator. If
reasoning is wanted later it needs its own event kind and its own authority
label, not a shared buffer.

**Rejected alternatives:** Matching on substrings, which is what produced both
bugs. A denylist of known-bad kinds, which fails open the next time a host adds
a stream. Emitting reasoning into agent output behind a marker string, which
would leave callers parsing prose to find the answer. Deferring the fix to the
caller, which would require every orchestrator to know each host's stream
taxonomy.

## D-043: Trust is a partition, not a warning string

**Status:** Accepted (2026-08-20)

**Context:** After the 2026-08-09 fabricated-citations incident — 103 captures
with invented sources in the knowledge base — MindGraph learned to attach a
`provenance_warning` to every chunk of a quarantined document. Travelling on
every chunk was the right lesson: a body banner only appears in chunk 0 and a
frontmatter tag never appears in chunk text at all.

But the warning was prose, and prose is advisory. Retrieval ranking is
trust-blind, and a fabricated document is written to be on topic, so it scores
like a real one. Driven from the ChatGPT seat on 2026-08-20, two live queries
returned quarantined documents at **rank 1**, with `rrf_score` in the same class
as the citable results beneath them. Six of eight results on one query were
quarantined. The entire control was that the caller would read an English
sentence and choose to obey it.

**Decision:**

1. Citability is a machine-readable class on every result, not an inference from
   the presence of a warning string. `citable`, `unverified`, `not_citable`.
2. `not_citable` results are returned in their own array and never mixed into
   the ranked result set a caller reads first. `conduit_query_mindgraph` returns
   `results`, `not_citable`, and `citation_counts`.
3. `unverified` stays with the usable results. A needs-audit capture is a
   nomination, not a barred source; collapsing the two would either hide real
   candidates or launder fabricated ones into the same bucket.
4. The partition separates, it does not drop and it does not re-rank. Order is
   preserved inside each bucket and the counts reconcile, so a caller that
   genuinely wants everything can still see everything.
5. A row that declares no class is treated as citable. The class is a signal
   added by the index; its absence is not evidence of a problem.

**Consequences:** A caller doing the obvious thing — reading `results` in order
— can no longer cite a quarantined source by accident. That is the point. The
top-scoring hit for a research question may now sit in `not_citable`, which will
look like worse retrieval and is in fact the same retrieval, told honestly.

**Rejected alternatives:** Ranking non-citable results lower, which still puts
them in the same list and makes the boundary a matter of degree. Dropping them
entirely, which hides that the index holds contradicting material and would make
the counts unreconcilable. Leaving it to the caller, which is the arrangement
that just failed. Deriving citability from `provenance_warning != null`, which
would wrongly bar `unverified` captures.

## D-044: Separate interrupt requests from observed interruption

**Status:** Accepted (2026-08-21)

**Context:** `conduit_interrupt` previously returned `interrupted: true` after
asking the backend to cancel. That was only local acknowledgement. The durable
Conversation timeline had no marker, and a closed output looked the same whether
it completed naturally or followed an interrupt request. Reusing `truncated`
would be false: that field means Conduit's export text cap, not a provider turn
being cut short. The MCP catalog that described this behavior was also private
to the AppKit target, so the caller-facing contract could not receive Core test
coverage.

**Decision:**

1. An admitted interrupt appends a durable, Conduit-recorded
   `interrupt_request` event before the backend request is sent. It is exported
   with `state: requested`, `source: conduit`, and `truncated: false`.
2. `conduit_interrupt` returns the event id and `interrupt: requested`. The
   compatibility `interrupted: true` remains acknowledgement only; its authority
   text explicitly directs the caller to later session events.
3. A provider cancellation or a completed/failed turn remains a separate
   observation. No interrupt request changes `turn.state`, fabricates a result,
   or makes output truncation true.
4. The active `tools/list` catalog moves to ConduitCore. Dispatch, authentication,
   and admission remain in the app target; catalog shape and wording are tested
   by ConduitCore tests and self-test assertions.

**Consequences:** An orchestrator can now see that Conduit sent a request and
can continue polling without treating it as proof that the provider stopped.
Provider-specific observed-interruption support remains future adapter work.
The `create_task` model parameter remains deliberately absent: a request-scoped
model override needs an explicit policy for allowed models, persistence, launch
precedence, and receipt/status projection.

**Rejected alternatives:** Calling the request itself an interruption result;
overloading `truncated`; inferring interruption from quiet PTY output; and
keeping the active catalog private to the app target.

## D-045: Publish a stable Session API catalog; authorize writes at call time

**Status:** Accepted (2026-08-23)

**Context:** The Session API originally omitted lifecycle tools from
`tools/list` while its local write setting was off. That makes an ordinary
loopback client look safely read-only, but clients that snapshot an MCP app's
actions cannot discover `conduit_create_task` later when an operator enables
writes. A hosted canary reached a write-enabled server but retained the
earlier read-only action snapshot.

**Decision:** `tools/list` always publishes the eleven-action catalog from
ConduitCore. Each lifecycle description says that its publication is not local
authorization. The loopback server continues to reject lifecycle commands
before dispatch when `allowWrites` is false, and AppModel retains its handler
guards. The static catalog is covered by Core tests; runtime authorization is
not represented by the listing.

**Consequences:** A caller can understand the complete surface without a
configuration-dependent discovery race. Seeing a lifecycle action grants no
capability: the caller still receives the explicit disabled-write error until
the operator changes the local setting. Hosted app refresh, app recreation,
and workspace entitlement are deployment conditions outside this product
decision.

**Rejected alternatives:** Asking callers to reconnect after every write-gate
change; exposing a write action only after a previous read call; treating a
static catalog as authorization; or removing the server and handler write
guards.

---

## D-046: Local planner proposals are not execution authority

**Status:** Proposed (2026-08-23)

**Context:** ChatGPT's available connector surface remains read-only, while a
local model could make the Conduit cockpit less dependent on cloud agent use.
That convenience cannot turn a planner response into authority to mutate a
project or start a worker. Existing OpenCode service instances may also carry
broader permissions than a planning assistant needs.

**Proposed decision:** Add a top-level Orchestrate workspace, separate from a
worker session's Conversation and Raw views. A local planner receives only a
bounded, scope-labelled context packet and returns a typed proposal. It has no
direct Conduit lifecycle capability. A proposal is validated deterministically;
only a current, explicit operator approval can later invoke the existing task
creation path. Planning response, task delivery, observed output, lifecycle,
and independent verification remain distinct state axes.

**Initial boundary:** The first usable planner transport is a fixed loopback
Ollama request to the locally installed `qwen3.5:9b` model with reasoning
disabled and a bounded response budget. It exposes no filesystem, shell, MCP,
task, or approval interface. The initial OpenCode CLI probe is retained as a
separate adapter lane: it could emit a marker but did not finish the structured
proposal request within the 150-second bound, so the app does not attach to an
existing OpenCode service or reuse it for planning. The Start action remains
disabled; a local proposal response is not task creation.

**Resource boundary:** A planner request sends `keep_alive: 0` to release only
Conduit's requested model after it responds. Ollama is a shared external
loopback service: Conduit neither starts nor stops the daemon, and it does not
unload models loaded by another client. The configured MainFrame root may be a
proposal target, but root selection does not grant the planner filesystem
access or relax the bounded project-relative path policy.

**Rejected alternatives:** Adding a third worker-session surface; reusing a
normal OpenCode worker service for planning; parsing arbitrary model prose into
a task; using a hidden task queue; treating a plan as verification; or falling
back to a cloud model when a local planner is unavailable.

## D-047: A replaced session is reported as replaced, and never overwrites the way back

**Context.** Every structured client accepts a resume id and every one of them
substitutes a new session when that id does not take. `CodexAppServerClient` and
`GrokACPClient` catch the failed `thread/resume` / `session/load` and start a
fresh one; `OpenCodeHTTPClient` creates a session when its existence check
misses; `StreamJSONClient` contacts no provider at start at all — it asserts the
id, emits `sessionStarted`, and reports ready, so it cannot fail loudly. In each
case the adapter then reports a healthy, ready session and nothing downstream can
tell that the history the caller asked for is absent.

That is the D-042 / OBS-2 shape — a clean green result over an empty one — with a
second failure on top of it. `AdapterThreadStore` is keyed by task, so the
replacement's id was written over the only pointer to the real thread. The failed
recovery destroyed the route back, and a second attempt could not even try the
right thread.

**Decision.** Substituting a session stays: it is the right recovery when a
provider refuses a resume. Reporting it as the resume the caller asked for does
not.

- `SessionResumeSemantics` names the four outcomes a client can produce —
  `fresh`, `resumed`, `restarted`, `unverified` — and each client states which
  one it produced. Only `resumed` claims the caller's history carried over.
  `unverified` exists so a client that never checked says so instead of guessing
  in either direction; `historyIsContinuous` is three-valued for the same reason.
- `conduit_session_status` carries `thread_provenance`, its authority line, and
  `superseded_thread_id`. This is the same promise `close_outcome` makes in the
  other direction: the caller learns what a session actually is while it can
  still act on it, rather than after trusting it.
- `AdapterThreadStore.save` carries a displaced thread id into
  `supersededThreadIDs` instead of overwriting it. The carry-forward is
  unconditional rather than opt-in, because the write sites cannot all tell a
  resume from a replacement and the cost of guessing wrong in the losing
  direction is an unrecoverable task.

**Boundary.** Provenance is observation, not verification, and it does not make a
closed task resumable: `reconcileTask` still refuses a task that is not in a
retryable provisioning state. Whether a provider honours a resume after its
adapter was stopped remains untested and unclaimed. `supersededThreadIDs` stays
content-free — thread ids only, bounded — and is a recovery hint, not an audit
trail.

**Rejected alternatives:** Failing the handshake when a resume is refused, which
would turn a recoverable task into a dead one; inferring provenance by comparing
ids after the fact, which cannot distinguish a provider that reissues the same id
from one that never checked; recording provenance only in the log, which leaves
the orchestrator that must decide with nothing to branch on; and refusing the
store write outright, which would leave the pointer naming a thread the runtime
is not driving.

## D-048: Structured conversation revisions do not invalidate the task catalog

**Status:** Accepted (2026-09-17)

**Context:** A structured OpenCode output fragment takes two publication paths.
`TerminalRuntime.presentationEvents` is the intended high-frequency path and is
observed by the selected conversation surface. The same fragment was also sent
through `AppModel.recordConversationRevision`, which published
`conversationRetentionStateByTask` as `.pending` and then `.persisted` for every
append completion. Because SwiftUI environment-object invalidation is broad,
those retention publications caused the root and task sidebar to rebuild their
catalog over the full task-session set. A successful append can be durable
without making the rest of the application observe a new retention state.

**Decision:**

1. Every presentation revision continues to append to the separate,
   append-only conversation log through `ConversationPersistenceCoordinator`.
   Persistence ordering, source labels, and failure reporting are unchanged.
2. A successful live agent-output append leaves retention in `.pending`; it does
   not publish `.persisted` for that fragment. `.pending` is published only when
   the task first enters that state. `.persisted` is published at a non-live
   boundary such as a prompt, settled output, or closed output. Failures still
   publish `.failed` and remain visible to the operator.
3. The pure task catalog retains a value cache keyed by its actual inputs:
   task snapshots, operational availability observations, and catalog query.
   Revisions in the conversation log are not catalog inputs. Task topology,
   availability, scope, search, archive, and sort changes still invalidate and
   rebuild the catalog.
4. `TaskSidebarView` observes a narrow `TaskSidebarModel` projection refreshed
   only by real sidebar inputs (task/session topology, metadata, availability,
   scope/search/archive, diagnostics, and sidebar presentation preferences).
   It retains AppModel only as an unobserved action authority for the existing
   lifecycle operations. This change does not redesign Conversation, move
   provider/runtime authority, or reinterpret a provider turn as completion.

**Consequences:** Ordinary structured streaming keeps its high-frequency view
   updates local to the conversation surface. The application-wide retention
   publisher and repeated catalog work are reduced to semantic transitions and
   genuine catalog-input changes. The sidebar itself is not invalidated by a
   live conversation revision. The intentional, low-frequency task-event
   reloads used to record content-free activity and the retention marker remain
   in place, so Recent ordering and task-history continuity do not regress.

The intermittent post-completion pin remains a separate observation. This
decision makes no claim about its publisher or resolution.

**Rejected alternatives:** Dropping conversation revisions, batching or
   rewriting the append-only log, hiding persistence failures, moving provider
   completion authority into the catalog, or optimizing the sidebar while
   retaining a per-fragment AppModel publication.


## D-050: Provider supervision uses explicit lineage, authority, and preflight state

**Status:** Accepted (2026-09-21; state-model foundation landed in #59)

**Context:** The durable-session pressure test in #52 showed that the current
task/session vocabulary cannot represent several states without overloading
them: an externally created provider session may have no Conduit task binding;
one provider session may use different models on different turns; a provider
turn may complete while objective acceptance remains pending; PTY input is not
the same thing as an agent prompt; provider persistence and live process state
may disagree; and a lifecycle verb such as close can mean detach on one backend
and stop on another.

**Decision:**

1. WorkerLineage is the provider-neutral supervision read model. Conduit task
   identity, runtime attempt, provider host, provider session/thread, provider
   turns, process lineage, workspace identity, writer/controller identity, and
   terminal/verification/acceptance state are distinct fields.
2. Missing facts use OrchestrationValue.unknown. A caller may not obtain a
   convenient default by borrowing authority from another layer.
3. Model/provider identity is turn-scoped. A durable provider session is not
   assigned one timeless model merely because a previous turn used it.
4. Delivery records distinguish shell_stdin, agent_prompt, and
   structured_message, with queued/accepted/active/completed/cancelled/failed
   and ambiguous turn state kept separate from objective acceptance.
5. LifecyclePreflight describes the operation target, support level,
   provider-stop and slot-release consequences, recoverability, resume handle,
   process scope, known descendants, side effects, and unsupported or unknown
   consequences before mutation.
6. Provider-specific state remains namespaced and JSON-typed rather than being
   flattened into shared string fields.
7. Observation authority and freshness are first-class data. These types are
   descriptive only in this slice; provider discovery, writer leasing, lifecycle
   mutation, and process reconciliation are later #53 slices.

**Consequences:** Conduit gains a common state vocabulary capable of expressing
the #52 pressure-test cases without inventing ownership or success. Later
provider adapters can project into the shared model while preserving their own
semantics. This slice changes no CAL/Apparatus contract semantics and does not
itself discover, adopt, interrupt, stop, or resume provider sessions.

**Rejected alternatives:** Reusing Conduit task identity as provider-session
identity; storing one session-level model; representing unknown as nil plus
caller convention; flattening provider-specific state to strings; calling PTY
writes agent prompts; or mapping an unsupported lifecycle operation to the
nearest available destructive action.


---

## D-051: OpenCode discovery reads persistence without entering the execution path

**Status:** Proposed (2026-09-21)

**Context:** #52 demonstrated provider sessions created outside Conduit that remained
visible to OpenCode but absent from Conduit inventory. The existing structured
OpenCode client is not an observation seam: starting it acquires
`OpenCodeServeLease`, may start `opencode serve`, binds task/runtime lifecycle,
and can later send or abort turns. Using that path merely to inspect a provider
session would manufacture supervision and consume execution resources. Source
review also found that current OpenCode database initialization applies
migrations, so invoking nominally read-only OpenCode CLI commands is not a
strictly non-mutating observation boundary.

**Decision:**

1. Provider discovery is a separate read-only interface that returns the shared
   `WorkerLineage` model and exposes no prompt, resume, abort, adoption, lease,
   or lifecycle-mutation verb.
2. OpenCode observation does not invoke the provider CLI or start/acquire an
   OpenCode server host. It copies the provider SQLite database and WAL into a
   disposable snapshot, verifies the source fingerprints remained stable across
   the copy, and queries only the disposable copy with `PRAGMA query_only=ON`.
3. The persistence projection is intentionally narrow: session identity and
   metadata plus message identity, role, provider/model identity, completion,
   and error state needed for turn lineage. Transcript content is not required
   for this discovery slice.
4. Exact provider-session identity may correlate an existing Conduit task/runtime
   binding when the match is unique. That correlation does not grant writer or
   controller authority.
5. Persistence is marked `provider_observed` with freshness `UNKNOWN`.
   A fresh snapshot read does not establish that persisted provider state matches
   live OS or process state.
6. Persisted assistant messages without a non-null provider completion or error
   are `AMBIGUOUS`, not inferred `ACTIVE`. Provider turn completion remains
   separate from terminal receipt, verification, and objective acceptance.
7. Provider-specific metadata remains typed and namespaced under
   `opencode.persistence`; unsupported shared fields remain explicit UNKNOWN.
8. If persistence is unavailable, ambiguous, changes during snapshot capture, or
   does not match the expected schema, discovery fails closed rather than
   migrating provider state or manufacturing replacement state.

**Consequences:** A supervisor can inventory and inspect external OpenCode session
identity without creating a Conduit task or consuming a live-task slot merely to
observe it. This slice deliberately does not establish live process state,
writer ownership, adoption, lifecycle control, or CAL integration.

**Rejected alternative:** The first implementation used `opencode session list`
plus sanitized export. That interface appeared read-only at the command level,
but current OpenCode startup initializes the database and applies migrations.
It is therefore not accepted as the non-mutating observation seam.

**Reconsideration trigger:** Revisit the transport if OpenCode provides a stable
read endpoint that can observe the same durable session inventory without
starting or acquiring a provider host and with stronger authority for freshness
or live activity.


---

## D-052: Provider-session writer authority is explicit and separate from workspace ownership

**Status:** Proposed (2026-09-21)

**Context:** Read-only provider discovery from D-051 can prove that an exact
OpenCode session exists without granting Conduit control over it. #52 and the
superseded #48 also exposed the dangerous inverse mistake: a provider session
that already has a writer can be misread as missing, after which recovery code
may start a replacement thread or fall back to another execution surface. That
forks history precisely when continuity still exists. The later #57 workspace
lane introduces a different one-writer concern for Git checkouts/worktrees; the
two authorities must not collapse into one lock.

**Decision:**

1. Provider observation and provider-session writer authority are separate.
   Repeated observation never grants control.
2. Conduit provider-session control is an explicit adoption/claim transition.
   The transition first re-observes the requested exact provider session and
   only then records Conduit's authority claim.
3. One provider session has at most one recognized Conduit writer/controller by
   default. Repeating the same controller claim is idempotent; a different
   controller receives the typed `writer_collision` disposition.
4. A writer collision means the requested provider session is still the
   authority object. Collision handling must not manufacture session absence,
   create a replacement provider session, start a provider turn, send a prompt,
   resume another session, or fall back to PTY.
5. Provider-native collision language is translated at the adapter
   boundary into the canonical `writer_collision` failure. The structured
   startup path treats that failure as fail-closed: no replacement provider
   session and no PTY fallback. Codex's current "active writer"/"open in another
   app" responses are the first mapped production case retained from #48.
6. OpenCode persistence remains read-only provider observation. It does not
   reveal another application's live writer ownership. External/unrecognized
   writer state therefore remains UNKNOWN in this slice.
7. Provider-session writer authority is distinct from #57 workspace/worktree
   writer authority. A later writable worker may require both, but neither
   lease grants or implies the other.
8. Explicit transfer/release is deferred to the lifecycle slice that can define
   its preconditions and consequences. This slice intentionally exposes no
   authority-transfer escape hatch.
9. The first registry is process-local governance state. It establishes the
   single-writer invariant for the running Conduit control plane; it does not
   claim durable cross-restart ownership or provider-native exclusion.

**Consequences:** A supervisor can explicitly distinguish a discovered external
provider session from one Conduit currently controls. The Core authority model
is provider-neutral while OpenCode remains the first production-shaped
observation adapter. The control claim itself consumes no execution slot and
does not mutate provider history. A restart loses the process-local Conduit
claim, so fresh authority after restart remains a later lifecycle/reconciliation
question rather than an invented durable fact.

**Rejected alternatives:** Treating an exact task binding as ownership; placing
writer state inside the OpenCode adapter; using listener client identity as the
writer lease despite the Session API lacking per-request client isolation;
treating a collision as a missing provider session; and sharing a single
provider/workspace mega-lock.

**Reconsideration trigger:** Revisit registry persistence and explicit transfer
when the lifecycle/reconciliation slice can prove provider-native ownership,
release semantics, or cross-restart authority without inventing state.
