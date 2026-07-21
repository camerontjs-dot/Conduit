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

**Status:** Accepted (daily-driver pass 0.2)  
**Context:** A small status affordance helps scanning many sessions without implying a control-room truth model.

**Decision:** Drive a compact pixel operator strip only from observable runtime state (working, ready, detached, exited, failed). It is not the source of truth for task or agent success.

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
