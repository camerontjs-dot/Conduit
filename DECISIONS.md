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

## Deferred deliberately (not rejected forever)

- Autonomous routing and agent-to-agent loops  
- Automatic task-completion judgments  
- Hidden transcript indexing  
- Silent process resurrection  
- General-purpose process termination  
- MindGraph retrieval blending into the default loop  
- Private project wiring inside the repository  

---

## Change control

Add a new `D-0xx` entry when architecture, safety boundaries, session durability, evidence rules, or packaging posture change. Prefer small accepted ADRs over silent README drift.
