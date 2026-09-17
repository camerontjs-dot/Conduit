# Conduit conversation-first UI plan

Status: implementation in progress in Draft PR #37

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

## Implementation status

Draft PR #37 now contains the first implementation of the plan. The following items are implemented in code but remain unqualified until the exact PR head is compiled, tested, and exercised in the installed macOS app:

- the permanent full-width Conversation / Raw segmented strip is removed; Conversation remains the default and Raw has a compact switch-back action;
- completed assistant presentation is cached, live follow-latest scrolling is coalesced, and whole-transcript / whole-turn projection is deferred until the operator invokes a copy/export action;
- assistant documents are rendered through one selectable attributed document rather than separate selectable nodes for every heading/list/code block;
- Copy turn, Copy transcript, explicit Markdown export, and Reveal retained JSONL in Finder are available from live and historical thread surfaces;
- OpenCode structured tool/patch events are projected through a fail-closed, session-bound typed activity model and displayed as expandable activity cards in Conversation;
- OpenCode activity cards never parse assistant prose, do not retain arbitrary tool output, label provider status as non-independent evidence, and deep-link exact in-project paths into the existing Source Workbench when such a path is available.

The remaining material work is qualification, broader shell/rail polish where the installed-app review still shows excess chrome, and any follow-up required by measured streaming performance. Activity persistence across closed/relaunched historical threads is not yet claimed by PR #37.

## Current live state at planning baseline

PR #33 merged the Context IDE / Graph / Workstation / source-workbench batch into `main` at the pinned base above.

The workspace at that baseline was capable but vertically expensive:

- `ProjectWorkspaceView` stacked `WorkspaceHeader`, optional operator state, optional multi-agent peek, then `SessionSurfaceView`;
- `WorkspaceHeader` could show task identity, resource summary, New Task, Forward, Tools, and Inspector actions;
- `SessionSurfaceView` added a permanent Conversation / Raw strip before the transcript;
- `ConversationView` added an activity header and optional terminal-control strip before the turn stream;
- the right Inspector was already independently collapsible and overlay-capable;
- Raw intentionally stayed mounted behind Conversation so PTY continuity survived surface switching.

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

The baseline `ConversationView` gave several testable hypotheses:

- `turns` is derived from the full `runtime.presentationEvents` collection during view evaluation;
- `streamContentSignature` traverses presentation state and changes as live output grows;
- assistant rendering derives display text, splits preserved thinking, detects interactive menus, and parses prose blocks;
- follow-latest invokes `scrollTo` on streaming changes;
- the live turn is mixed into the same view hierarchy as completed turns;
- Raw remains mounted while hidden;
- multiple `@Published` / observed runtime changes may invalidate a larger part of the tree than necessary.

Conversation persistence is already dispatched to a utility queue, so disk I/O should not be blamed without evidence. Verify the actual callback/main-actor interaction before changing it.

### Measurement first

Before declaring the performance work complete, preserve a reproducible workload and result.

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

### Implemented candidate directions

PR #37 currently implements several candidate reductions in work rather than claiming a measured performance result:

- completed assistant projections cache their scrubbed/attributed presentation;
- the active streaming turn remains mutable while completed projections are reused;
- follow-latest scrolling is coalesced over short streaming bursts;
- transcript and whole-turn serialization is invoked by copy/export actions rather than eagerly during ordinary rendering;
- the multi-node Markdown view used for completed assistant prose was replaced by one selectable attributed document.

A performance change is successful only if it improves the installed app under the reproduced workload without weakening capture or authority semantics.

## Workstream B: turn selection and copy

### Baseline problem

Assistant prose was rendered as many independent SwiftUI `Text` nodes for headings, paragraphs, bullets, and code. Each node had selection enabled independently. That made macOS selection stop at view boundaries instead of behaving like one normal document.

### Implemented behavior in PR #37

For live and retained threads the candidate now provides:

- one selectable attributed assistant document for normal Markdown output;
- standard macOS selection and Command-C within that document;
- explicit whole-turn copy controls for user and assistant turns;
- explicit whole-transcript copy and Markdown export;
- visible turn text as the default copy payload;
- hidden provenance/debug metadata excluded from default copy/export.

Installed-app selection behavior still requires direct macOS verification before merge.

## Workstream C: inline code / tool activity

### Product goal

The source workbench should feel connected to the agent thread.

When a structured provider reports useful activity, Conversation should be able to show compact, expandable activity inside the relevant live thread.

### Implemented OpenCode boundary in PR #37

OpenCode now has a typed provider-reported activity projection for structured `tool` and `patch` parts. The implementation:

- requires an exact matching OpenCode session identity;
- rejects foreign-session or session-less activity;
- does not parse assistant prose;
- excludes reasoning/text/step chrome from activity;
- records compact tool identity/status/title and exact provider-reported file paths when present;
- deliberately does not retain arbitrary successful tool output in the card model because tool output may contain source contents or secrets;
- bounds error detail;
- displays activity as expandable cards in Conversation;
- labels the status as provider-reported, not independently verified;
- offers Copy path and Source Workbench deep links only for exact paths that resolve inside the task project scope;
- keeps the full Source Workbench as the real source inspection/editor surface.

This is intentionally narrower than inventing generic structured history for every provider. PTY agents still have no fabricated tool history. Persistence of these cards into historical/relaunched threads is not yet claimed.

## Workstream D: accessible logs and retained history

### Existing durable source

Conduit stores one private append-only JSONL conversation source per task under:

```text
~/.conduit/conversations/
```

The log retains source-labelled prompts and bounded visible output revisions. It is separate from MainFrame project files and work-session receipts.

### Implemented operator access in PR #37

From live and historical task surfaces the candidate now exposes:

- Copy transcript;
- Export rendered transcript through an explicit save panel;
- Reveal the exact retained JSONL source in Finder;
- existing retained Conversation history remains directly viewable inside Conduit.

The human-readable export is derived from projected Conversation events and does not rewrite the JSONL, silently copy into MainFrame, or commit to Git.

## Workstream E: chrome reduction

### Implemented reduction

PR #37 removes the permanent Conversation / Raw segmented strip. Conversation is still the product default, Raw remains mounted/authoritative where required for PTY continuity, and Raw exposes a compact Conversation return control.

Focused-mode header and side-surface polish should be judged again in the installed app before deciding whether additional chrome needs to move. Do not remove useful features merely to satisfy a screenshot target.

## Testing and evidence

### Deterministic coverage added

PR #37 adds Core coverage for:

- turn/transcript copy serialization;
- prompt attachments and role-labelled Markdown export;
- exclusion of hidden source metadata from default export;
- OpenCode activity session binding;
- rejection of foreign/session-less activity;
- exclusion of reasoning/text parts from tool activity;
- tool status/title/path projection;
- omission of arbitrary successful tool output;
- bounded failure detail;
- patch file-list projection;
- Codable round-trip of the bounded activity snapshot.

These tests are implementation evidence only after they are actually run on the exact candidate.

### Installed-app evidence required before merge

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
- structured OpenCode activity/workbench deep-link receipt;
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
