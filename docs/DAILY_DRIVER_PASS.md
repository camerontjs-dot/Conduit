# Conduit daily-driver pass

## Goal

Make Conduit useful as Cameron's default MainFrame agent workspace without
introducing autonomous orchestration, unprocessed terminal-byte retention, or
a second project source of truth.

## Implemented additions

### Task-history navigation

The left rail is now task-first. It shows Pinned, Active, and Recent metadata
records across **All MainFrame** by default. Archived history is opt-in from the
sidebar's More menu. The scope browser can narrow the catalog to the MainFrame
root or a project from the current file scan; it does not maintain a project
database.

Selecting a task is navigation only. It can focus a runtime that is already
open, but it does not launch or attach one. A durable task that Conduit has
observed as reconnectable exposes a separate Reconnect action. Leave and End
are separate runtime actions as well.

### Explicit New Task

New Task requires an enabled local CLI profile and a scanned MainFrame scope.
It defaults to the scope most recently submitted through that sheet, or to the
scanned MainFrame root on a fresh setup. The operator reviews both choices
before Conduit opens a process.

Creating the task allocates a stable `TaskSessionID`, starts a separate
`RuntimeAttemptID`, opens Conversation, and begins the project-scoped work
session if needed.

### Conversation and Raw

Every live runtime has two surfaces over the same terminal controller.
Conversation is the default. It renders the session opening or reattachment,
exact native-composer submissions, local attachment paths, forwarded-output
provenance, and **Queued** / **Sent to terminal** / **Delivery failed** terminal
handoff. Its activity header uses observed process state.

Raw mounts the unchanged SwiftTerm PTY/TUI for approvals, direct CLI input,
debugging, and output that Conduit cannot structure. It is available from the
segmented control, **Open Raw**, or `⌘2`; `⌘1` returns to Conversation. Starting
the process does not depend on mounting Raw.

When a runtime detaches or ends, Conversation removes the active composer,
keeps Raw available for inspection, and shows applicable Reconnect or Restart
Runtime controls alongside New Task.

Conversation compares rendered SwiftTerm or tmux snapshots after a delivered
prompt and shows bounded output labelled **Derived from Raw**. The block may
contain prompt echo, tool logs, terminal chrome, or agent prose. Generic
activity is not called private thinking, and neither output quietness nor prose
is treated as an approval, test result, change record, completion, or
verification. Raw bytes are not retained as an unprocessed transcript.

### Task and conversation continuity

Task metadata is one append-only JSONL stream per task under
`~/.conduit/task-sessions/`. It retains task and runtime identities, a
standardized scope with historical title/slug fallback, optional recorded agent
identity, title overrides, pin/archive changes, and operational lifecycle.

Conversation content is a separate private append-only JSONL stream per task
under `~/.conduit/conversations/`. It retains exact prompts, local attachment
path references, delivery revisions, and source-labelled bounded visible
output. Attaching a path does not copy that file, but text rendered by the CLI
can include file contents or secrets and may enter a retained Derived from Raw
revision. Each rendered revision is capped at 16,000 characters; append-only
earlier revisions remain in the local source. It does not retain an
unprocessed Raw byte transcript or silently import old tmux scrollback.

The catalog combines those events with current live runtimes, tmux discovery,
and the current MainFrame scan. A failed external discovery remains unknown;
it cannot prove that a runtime is unavailable. Corrupt or unsupported task
metadata records are left in place and surfaced from the sidebar's **Issues**
menu. Conversation-log diagnostics appear on the selected task's history
surface; valid conversation records remain visible when possible.

After relaunch, the historical task surface renders retained conversation
events without starting a process. A content-free marker records that history
is expected after the first successful conversation append. Missing marked
history is called unavailable; an unmarked task remains a possible
pre-retention or never-recorded gap. Neither becomes an invented complete
transcript.

### Discovered-session recovery

Tmux sessions not represented by loaded task history appear in a secondary
Discovered section. A legacy session with recorded project identity can be
resumed explicitly and adopted into a new task identity. A session with no
recorded project requires the operator to choose a MainFrame scope. A malformed
task binding is labelled **Needs attention** and is not attached or rewritten.

### Conduit Doctor

Checks configured CLI commands, reports resolved executable paths and versions, validates the public MainFrame lifecycle folders, detects tmux, and surfaces microphone and speech-recognition permission state.

A successful command-path check is not proof that the account is authenticated or that a provider service is available. It is a local readiness signal only.

### Durable sessions (tmux-first, rebuild pass 0.3)

When the setting is enabled and tmux is installed, Conduit creates the session **detached and out-of-band** (`tmux new-session -d`) with a deterministic name from the standardized project path and agent name, then attaches a SwiftTerm client to it. Launching the same agent in the same project focuses an existing runtime, or reconnects to a task-bound tmux session after an app restart. Leaving the runtime detaches via `tmux detach-client` — a real tmux command, never emulated prefix keystrokes, so any operator tmux configuration works.

When tmux is unavailable, the UI labels the session `PTY` and closing it terminates the process explicitly. Conduit does not pretend direct PTYs survived.

New tmux sessions also record project, agent, and task identity as tmux user
options. Name parsing is not identity. Legacy or malformed bindings therefore
take the explicit recovery paths above.

### Prompt delivery

Composer text and forwarded selections are delivered with paste semantics, not
typing semantics: tmux sessions receive them through
`load-buffer`/`paste-buffer -p` (bracketed paste when the agent requested it)
plus one explicit Enter; direct PTYs get bracketed-paste wrapping when the
foreground application enabled it. Multiline prompts arrive as one block.
Delivery to a just-launched agent is queued until output first appears and then
quiesces for 0.6 seconds, with an eight-second cap after the first byte. This
replaces the earlier fixed forwarding sleep with bounded readiness polling.
The timer gates only when Conduit hands prompt bytes to the terminal; it does
not declare the CLI ready, interpret agent state, or imply task completion.

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

This receipt stream remains separate from task history. Receipts are not
imported as Conversation messages, and closing a work session does not mark a
task completed.

### Context bundles

Conduit nominates project files such as README, AGENTS, decisions, log, status, and recent plans. The operator selects sources and previews the exact bundle before attaching it. Every section retains its local path and a trust label.

The bundle is capped in size and marked when truncated. It is context for inspection, not verification.

### Resource Deck

Shows approximate used and total memory, the largest resident processes, and currently loaded Ollama models. The only destructive control in this pass is explicit Ollama model unloading. General process killing remains in Activity Monitor.

### Agent identity in Conversation

Codex and Claude sessions use copied character art in the Conversation activity
header beside the agent name, backend, observed state, and Open Raw action. The
app bundles those resources directly. It has no runtime dependency on the
separate workstation or pixel-agent tracker. Runtime Leave and End remain
explicit task actions rather than sprite controls.

The pose is projected from observable terminal facts:

- starting: process launch is underway
- working: output received recently
- running: process running without recent output
- detached: tmux client detached
- exited: process ended without a nonzero code
- failed: nonzero exit code observed

The detached pose communicates uncertainty about background progress. The
exited pose does not mean the agent completed its task. Shell, Gemini, OpenCode,
and custom profiles receive a generic pixel character with an accessibility
hint that no dedicated sprite exists.

### Responsive navigation and root recovery

The task navigator is searchable; `⌘F` focuses task search. `⌘N` opens New
Task, and `⇧⌘P` opens the source-derived project scope browser. Focused density
uses a two-column task-rail/workspace composition with a temporary context
overlay. Balanced and Operator keep project context in a third column, while
Operator also shows the observed-state resource deck.

The selected MainFrame root is stored with a security-scoped bookmark. When a
development rebuild changes the app identity or macOS invalidates folder
access, startup stays responsive and presents a single folder reauthorization
step. It does not hang the first window on a protected filesystem read.

## Deferred deliberately

- Autonomous routing and agent-to-agent loops
- Automatic task-completion judgments
- Hidden transcript indexing
- Unprocessed Raw byte transcripts
- Destructive clear-history and transcript-body search
- Full agent-response reconstruction without adapter support
- Silent process resurrection
- General-purpose process termination
- MindGraph retrieval blending
- Private project wiring

## Verification

The source contains deterministic selftest/XCTest coverage for task projection,
catalog filtering, corrupt-log preservation, tmux task binding, and conservative
Conversation events, append-only conversation revisions, and rendered-buffer
reduction. Those checks establish mechanics, not installed-app acceptance.

There is no SwiftUI/UI test target for the new task rail, New Task and project
scope sheets, or live Conversation/Raw interaction.

Candidate build, installed-app smoke, and interactive daily-driver acceptance
remain separate. A local pass is still required for CLI authentication, folder
and microphone permissions, task selection, Conversation/Raw focus, multiline
delivery, tmux detach/reconnect, legacy adoption, receipt writing, relaunch
recovery, and the operator's private MainFrame tree.
