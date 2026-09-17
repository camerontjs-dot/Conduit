# Conduit conversation-first UI plan

Status: planning candidate

Tracking issue: #34

Pinned planning base: `0d2dccc23999312b2f231b2b6d02408734a5d25b`

Date: 2026-09-16

## Objective

Make Conduit feel like an agent application first.

The active Conversation and composer should be the visual and interaction center of the app. Task navigation, Raw terminal access, context, files, review, source inspection, usage, resources, work-session state, Graph, Workstation, and other operator surfaces should stay available without all competing for permanent screen space.

This pass also owns four usability problems that are now part of the same interaction boundary:

1. the UI becomes visibly laggy while an agent streams a response;
2. text selection is fragmented across rendered blocks, making partial-copy awkward;
3. the new Context IDE / source-workbench capability is not yet integrated into the chat flow;
4. retained Conduit chat logs exist but are not easy to discover, inspect, copy, or export from the app.

The target is not a visual clone of another product. The target is the interaction hierarchy that mature chat and coding-agent products have converged on: conversation in the center, navigation on the left, contextual inspection from the side or inline, and history treated as a first-class object.

## Current live state

PR #33 merged the Context IDE / Graph / Workstation / source-workbench batch into `main` at the pinned base above.

The current workspace is capable but vertically expensive:

- `ProjectWorkspaceView` stacks `WorkspaceHeader`, optional operator state, optional multi-agent peek, then `SessionSurfaceView`;
- `WorkspaceHeader` can show task identity, resource summary, New Task, Forward, Tools, and Inspector actions;
- `SessionSurfaceView` adds a permanent Conversation / Raw strip before the transcript;
- `ConversationView` adds an activity header and optional terminal-control strip before the turn stream;
- the right Inspector is already independently collapsible and overlay-capable;
- Raw intentionally stays mounted behind Conversation so PTY continuity survives surface switching.

That architecture gives us a useful constraint: simplify presentation without breaking runtime continuity.

## External product research

Research was limited to current official product material and is used only as interaction reference.

### OpenAI Codex / ChatGPT desktop

OpenAI describes the Codex app as a focused place for parallel agent threads organized by project. Agent changes can be reviewed in the thread, commented on as diffs, or opened in an editor. The current ChatGPT desktop app keeps Chat, Work, and Codex as distinct modes while chats and projects remain easy to reach from Recents and Projects.

Relevant official material:

- https://openai.com/index/introducing-the-codex-app/
- https://help.openai.com/en/articles/20001276/
- https://openai.com/index/chatgpt-for-your-most-ambitious-work/

Design lesson for Conduit: code review and developer tooling can remain close to the thread without turning the entire default workspace into an always-open IDE.

### Claude / Claude Code

Anthropic's Claude Code desktop direction supports multiple local and remote sessions in parallel. Its IDE integration uses a dedicated sidebar with inline diffs. Anthropic also explicitly documented cases where long model latency made the UI appear frozen, reinforcing the need to keep the operator surface responsive even when the model is busy.

Relevant official material:

- https://www.anthropic.com/news/enabling-claude-code-to-work-more-autonomously
- https://www.anthropic.com/news/claude-opus-4-5
- https://www.anthropic.com/engineering/april-23-postmortem

Design lesson for Conduit: keep contextual code inspection close and expandable, and treat UI responsiveness as a separate product requirement from provider/model latency.

### Conversation history and granularity

ChatGPT exposes persistent conversation history, whole-conversation sharing/export, and individual-response sharing. The specific mechanics are not a Conduit requirement, but the granularity is useful: a conversation, a turn, and selected text are all legitimate operator objects.

Relevant official material:

- https://help.openai.com/en/articles/7925741-chatgpt-shared-links
- https://help.openai.com/en/articles/7260999-how-do-i-export-my-chatgpt-history-and-data

Design lesson for Conduit: copying one selection, copying one turn, reopening one retained thread, and exporting one transcript should all be natural operations.

## Governing interaction model

### Default workspace

The default `Focused` experience should read visually as:

```text
┌──────────────┬────────────────────────────────────────────┐
│              │ compact thread header                      │
│ task/project │────────────────────────────────────────────│
│ navigation   │                                            │
│              │                Conversation                │
│ collapsible  │                                            │
│              │                                            │
│              │────────────────────────────────────────────│
│              │ persistent composer                        │
└──────────────┴────────────────────────────────────────────┘
                                  ╲ optional Inspector overlay
```

The conversation should not be framed by multiple permanent telemetry bars.

### Balanced and Operator

`Balanced` may expose a little more session context.

`Operator` remains the deliberate dense mode for resource telemetry, multi-agent peek, deeper observed state, and other operational surfaces.

Density must remain presentation only. It must not change task identity, runtime lifecycle, authority, or persistence behavior.

### Left rail

The left rail remains the primary task/project/history navigator.

Required behavior:

- independently collapsible;
- smooth show/hide without remounting the selected task/runtime;
- remembers explicit operator preference;
- keeps New Task and search easy to reach;
- history remains navigation-only and never reconnects or launches merely because a row was selected.

### Right Inspector

The existing right Inspector should absorb more secondary chrome rather than growing new central bars.

Likely homes include:

- Session / authority details;
- Files;
- Context Stack;
- Review;
- Usage;
- resource detail;
- work-session detail;
- retained-log / transcript actions;
- source or diff detail that does not belong inline.

The Inspector may overlay Conversation at narrower widths and pin where the existing responsive policy allows it.

### Raw

Raw remains the authority for PTY/TUI state where applicable.

Change the presentation, not the authority:

- Raw stays one click / shortcut away;
- remove the need for a permanently visible full-width Conversation / Raw picker in the default layout;
- a compact thread-header action, keyboard shortcut, or contextual control may switch the same runtime surface;
- surface switching must not duplicate or restart the runtime;
- hidden Raw may remain mounted if that is required for terminal continuity, but expensive hidden rendering work should be measured and reduced where possible.

## Workstream A: streaming performance

### Observed symptom

The operator reports that Conduit becomes visibly laggy while an agent is responding.

### Current plausible mechanisms

The current `ConversationView` gives several testable hypotheses:

- `turns` is derived from the full `runtime.presentationEvents` collection during view evaluation;
- `streamContentSignature` traverses presentation state and changes as live output grows;
- assistant rendering derives display text, splits preserved thinking, detects interactive menus, and parses prose blocks;
- follow-latest invokes `scrollTo` on streaming changes;
- the live turn is mixed into the same view hierarchy as completed turns;
- Raw remains mounted while hidden;
- multiple `@Published` / observed runtime changes may invalidate a larger part of the tree than necessary.

Conversation persistence is already dispatched to a utility queue, so disk I/O should not be blamed without evidence. Verify the actual callback/main-actor interaction before changing it.

### Measurement first

Before optimizing, create a reproducible workload and preserve the result.

At minimum exercise:

- 25-turn thread;
- 100-turn thread;
- 250-turn thread;
- one long streaming assistant response;
- mixed Markdown including headings, lists, and code blocks;
- Inspector closed and open;
- Raw hidden and visible;
- one structured adapter and one PTY-backed path where practical.

Collect practical evidence such as:

- Instruments Time Profiler / main-thread samples;
- SwiftUI body invalidation observations if available;
- update frequency for transcript projection;
- auto-scroll frequency;
- parse work performed for completed turns during a live final turn;
- operator-visible responsiveness of composer typing, selection, scrolling, and Inspector open/close while output streams.

Do not choose an arbitrary frame-time target before seeing the baseline. The acceptance claim should be tied to the tested workload and before/after receipt.

### Candidate implementation directions

These are hypotheses to test, not mandatory architecture:

- give completed turns stable presentation models and cached parsed content;
- isolate the active streaming turn from immutable completed turns;
- update only the live turn when provider output extends an existing event revision;
- move pure projection/parsing into Core where it can be deterministically tested and measured;
- coalesce follow-latest scrolling rather than scrolling on every tiny text update;
- avoid recomputing menu/prose structure for completed output;
- keep hidden Raw attached while minimizing hidden visual work if SwiftTerm allows it safely;
- use lazy transcript loading / paging for very long retained history if profiling shows the visible view tree is itself the limit.

A performance change is successful only if it improves the installed app under the reproduced workload without weakening capture or authority semantics.

## Workstream B: turn selection and copy

### Current problem

Assistant prose is rendered as many independent SwiftUI `Text` nodes for headings, paragraphs, bullets, and code. Each node has selection enabled independently. That makes macOS selection stop at view boundaries instead of behaving like one normal document.

### Required behavior

For both live and retained threads:

- dragging selection across a paragraph/list/code boundary inside one turn behaves naturally;
- standard Command-C copies the selected subsection;
- every user and assistant turn exposes a compact `Copy turn` action;
- whole-turn copy preserves readable line breaks and code fences/indentation;
- code blocks may expose their own copy action;
- copy actions stay out of the permanent visual hierarchy and can appear on hover/context menu;
- visible turn text is the default copy payload;
- provenance/debug metadata is excluded unless the operator explicitly chooses a richer diagnostic copy.

### Implementation boundary

The plan does not prescribe SwiftUI `Text`, `AttributedString`, `NSTextView`, or another concrete implementation. Choose the lightest representation that simultaneously supports:

- continuous native selection;
- Markdown/code presentation;
- stable layout during streaming;
- accessibility;
- good performance on long threads.

The implementation should avoid fixing selection by introducing a more expensive per-line view hierarchy.

## Workstream C: inline code / tool activity

### Product goal

The new source workbench should feel connected to the agent thread.

When a structured provider reports useful activity, Conversation should be able to show compact, expandable activity inside the relevant turn, for example:

- searched repository;
- read `path:line`;
- edited a file;
- working-tree diff changed;
- ran a command;
- ran tests;
- opened/reviewed a PR or issue;
- produced an artifact/reference.

The chat should not become a raw event dump.

### Inline card behavior

A good default card contains only the useful summary:

```text
▸ Edited  Sources/Conduit/ConversationView.swift   +24 -11
```

Expanding may show a bounded diff or excerpt. Actions can include:

- Open in Workbench;
- Open Diff;
- Copy path;
- Copy snippet/diff;
- Inspect provenance.

The existing source workbench remains the full inspection/editor surface. Conversation only provides the context bridge.

### Authority boundary

This is consequential.

The current canonical Conversation event model primarily represents session boundaries, user prompts, interrupts, and agent output. Do not infer structured tool history by parsing prose such as "I edited file X".

If provider adapters expose tool/file/command activity, introduce an additive typed activity/event representation with explicit source/authority.

Examples of authority classes that may matter:

- provider/tool reported;
- Conduit-recorded local action;
- Git/workbench observed state;
- Derived from Raw.

PTY-only agents remain allowed to have less structured UI. Missing provider telemetry stays missing.

### Context IDE integration

Inline activity should deep-link into PR #33 surfaces by exact identity when possible:

- exact path;
- line/range;
- current on-disk blob identity where known;
- working-tree diff;
- relevant Context Stack item;
- PR/issue reference;
- local artifact path.

Do not manufacture an exact target from fuzzy text.

## Workstream D: accessible logs and retained history

### Existing durable source

Conduit already stores one private append-only JSONL conversation source per task under:

```text
~/.conduit/conversations/
```

The log retains source-labelled prompts and bounded visible output revisions. It is separate from MainFrame project files and work-session receipts.

### Required operator access

From an active or historical task, provide obvious actions for:

- Open retained transcript in Conduit;
- Copy transcript;
- Export rendered transcript;
- Reveal source log in Finder;
- Open/reveal diagnostics for malformed or unavailable retained history;
- optionally export the underlying JSONL explicitly for debugging.

A top-level hidden-by-default `Logs`/`History` route under sidebar More or Inspector is acceptable, but the selected thread itself must expose the common actions without requiring filesystem knowledge.

### Export contract

Human-readable export should be derived from the projected retained Conversation events and clearly identify source labels where useful.

The export must not:

- rewrite the source JSONL;
- imply a complete Raw terminal transcript;
- silently copy into MainFrame;
- silently commit to Git;
- include secrets from unrelated local state.

Choose destination explicitly through the operator-facing save/reveal flow.

## Workstream E: chrome reduction

### Central surface to remove or collapse

Candidates to reduce from permanent central layout:

- full resource summary in `WorkspaceHeader`;
- permanent Conversation / Raw segmented bar;
- work-session deck when not in Operator mode;
- multi-agent peek when not explicitly enabled;
- redundant authority labels that can move into Inspector/provenance affordances;
- tool controls that only matter during an interactive menu.

### Central surface to keep

Default central workspace should retain only what helps answer:

- which task/thread am I in?
- which agent is this?
- is it currently working / waiting / stopped?
- where do I type?
- how do I get to Raw or context if I need it?

Everything else should earn its screen space contextually.

## Proposed implementation slices

### Slice 1: projection, performance, and copy foundation

Scope:

- reproduce streaming lag;
- establish before measurement;
- introduce stable/cached turn presentation if justified;
- isolate live-turn updates if justified;
- repair continuous per-turn selection;
- add Copy turn;
- preserve tests for transcript projection/copy serialization.

Exit:

- long-thread installed-app streaming is materially more responsive under the same workload;
- copy/selection behavior works without changing runtime semantics.

### Slice 2: conversation-first shell

Scope:

- simplify WorkspaceHeader;
- remove/reduce permanent Conversation/Raw bar;
- make transcript + composer dominant;
- strengthen left-rail collapse behavior;
- keep Inspector contextual/overlay-first;
- preserve Operator density for dense telemetry.

Exit:

- daily-driver screenshot reads as an agent chat first;
- side surfaces hide/show without runtime remount or state loss.

### Slice 3: inline provider/source activity

Scope:

- define the smallest honest typed activity model needed;
- connect available structured provider events;
- render compact expandable activity cards;
- deep-link exact source/diff targets into the existing workbench;
- retain less-structured fallback for PTY agents.

Exit:

- a structured coding-agent turn can show what it inspected/changed without forcing a workspace switch;
- no prose-derived fake tool history.

### Slice 4: log/history accessibility

Scope:

- selected-task transcript actions;
- reveal exact JSONL source;
- Copy transcript;
- explicit human-readable export;
- historical task parity.

Exit:

- an operator can find and use one task's retained chat log entirely from Conduit.

### Slice 5: installed-app acceptance and polish

Scope:

- long-thread workload rerun;
- structured + PTY smoke;
- Inspector/rail/Raw transitions;
- selection/copy/export;
- source-card -> workbench navigation;
- VoiceOver/keyboard pass;
- final visual cleanup only after behavior is stable.

## Testing and evidence

### Deterministic coverage

Add Core tests where practical for:

- turn projection stability;
- copy-turn serialization;
- transcript export serialization;
- any additive activity authority/event types;
- workbench deep-link identity resolution;
- log-path derivation / fail-closed behavior;
- long-history paging or cache policy if introduced.

Keep `ConduitSelfTest` and XCTest coverage aligned when Core behavior changes.

### Installed-app evidence

The implementation cannot be qualified by unit tests alone.

Preserve:

- exact base/head SHA;
- macOS/Xcode/Swift identity;
- `./scripts/test.sh` result;
- build/codesign result;
- installed executable identity;
- installed canary result where relevant;
- before/after streaming-performance receipt;
- one long-thread interactive acceptance record;
- selection/copy receipt;
- log reveal/export receipt;
- structured inline-activity/workbench deep-link receipt;
- any failure or remaining unknown.

Hosted CI infrastructure failures remain infrastructure unknowns, not product failures or passes.

## Acceptance conditions

The programme is complete when one exact promoted configuration supports all of the following without weakening existing boundaries:

1. A normal task opens to a conversation-dominant workspace.
2. Left navigation and right Inspector are easy to hide/show and do not remount the runtime.
3. Raw remains immediate and authoritative without requiring permanent central chrome.
4. Long streaming output no longer makes ordinary typing, scrolling, selection, or opening side surfaces visibly stall under the preserved acceptance workload.
5. Completed turns do not repeatedly incur avoidable parse/layout work on every live output update, or profiling establishes and repairs a different root cause.
6. One turn behaves as a coherent selectable document.
7. Whole turns and whole transcripts can be copied explicitly.
8. Structured source/tool activity can appear inline when the provider or Conduit has legitimate authority to report it.
9. Inline code/diff activity can open the exact existing workbench target when that target is known.
10. PTY agents do not receive invented structured tool history.
11. Retained task history, exact local JSONL, copy transcript, and explicit export are discoverable from the selected thread/task.
12. Export/reveal actions do not silently publish private logs to MainFrame or GitHub.
13. Task/runtime identity, prompt delivery, capture semantics, provider authority, and MainFrame source-of-truth rules remain intact unless a separately reviewed contract change is required.

## Non-goals

This plan does not authorize:

- replacing the existing source workbench with a second editor inside chat;
- retaining unprocessed Raw byte transcripts;
- inventing tool activity for PTY agents;
- automatic success/verification claims from code activity;
- silently exporting private chat history;
- weakening exact-file conflict handling;
- changing control-plane lifecycle semantics for layout convenience;
- turning every diagnostic into permanent visible chrome;
- reproducing another product's visual design pixel-for-pixel.

## Decision rule

Prefer the smallest implementation that makes Conversation feel native and responsive while preserving the existing authority boundaries.

If a UI simplification requires runtime/control-plane semantic change, stop that slice and review the boundary separately rather than hiding the change inside presentation work.
