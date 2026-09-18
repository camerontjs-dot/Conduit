# Conduit conversation-root UI plan

Status: implementation candidate

Tracking issue: #34

Implementation base: merged #40 at `525d9fe677aa6aaba466b2d5db7a0e403936a90b`

Date: 2026-09-17

## Objective

Conduit’s ordinary task window is the conversation.

The active Conversation and composer own the usable window at rest. Tasks, history, Inspector, resources, agent controls, files, review, Raw, Workbench, diagnostics, and other operator surfaces remain available, but they do not reserve permanent screen space merely because they exist.

The governing rule is:

> At rest, every pixel below the minimal native toolbar belongs to the active conversation and composer. A secondary surface takes space only after the operator explicitly opens it.

This replaces the earlier, more conservative interpretation of “conversation-first” where chat remained one large region inside a permanently visible multi-section workspace.

## Default shell

The ordinary Sessions workspace should read as:

```text
┌────────────────────────────────────────────────────────────┐
│ tasks   current thread                     tools inspector │
├────────────────────────────────────────────────────────────┤
│                                                            │
│                                                            │
│                       Conversation                         │
│                                                            │
│                                                            │
│                                                            │
│                                                            │
├────────────────────────────────────────────────────────────┤
│ attachments / voice   Ask the active agent…         Send │
└────────────────────────────────────────────────────────────┘
```

The native toolbar is intentionally small. It provides only high-frequency entry points: task drawer, current thread identity, New Task, Tools, and Inspector.

The default Sessions canvas does not mount the prior permanent workspace header, resource summary, operator diagnostics deck, multi-agent Peek row, selected-session card, or full-width Conversation/Raw selector.

Those capabilities are not deleted. They move behind explicit operator actions.

## Secondary-surface rule

Secondary surfaces have exactly two presentation modes:

- **temporary**: overlay Conversation and disappear when dismissed;
- **pinned**: reserve their width and Conversation reflows into the remaining rectangle.

Closing a panel immediately restores Conversation to the available window.

Pinning is presentation only. It must never restart, duplicate, reconnect, detach, or otherwise mutate the active runtime.

A pin is honored only when enough room remains for a useful conversation canvas. At narrow widths the effective presentation falls back to overlay rather than crushing chat.

## Tasks and history

Tasks/history live in a left drawer.

Default behavior:

- closed at rest;
- opens above Conversation;
- may be explicitly pinned;
- search requests reveal it;
- selecting retained history remains navigation-only;
- selecting a task never reconnects or launches merely because the row was selected.

The drawer continues to use the narrow `TaskSidebarModel` projection introduced by #40. High-frequency Conversation revisions must not return to application-wide sidebar invalidation.

## Inspector

Inspector lives in a right drawer.

Default behavior:

- closed at rest;
- overlays Conversation when opened;
- may be explicitly pinned;
- a pin reflows Conversation only when the window has enough room;
- retains existing Session, Files, Review, Context, Usage, Attention, and other inspector capabilities.

Inspector remains a presentation surface. It does not become runtime or project authority.

## Tools and operational surfaces

The compact Tools menu is the launch point for less-frequent operator surfaces, including:

- Sessions / Explore / Orchestrate workspace switching;
- project browser;
- context bundle;
- project shell;
- durable-session resume;
- forwarding;
- resources;
- agent usage;
- Focus Board;
- MindGraph;
- diagnostics;
- appearance;
- settings.

Operational capability is preserved without permanently displaying operational telemetry.

## Raw

Raw remains authoritative for PTY/TUI state where applicable.

Conversation is the default visible surface. Raw is an explicit alternate view of the same runtime:

- Conversation → Raw does not restart or duplicate the runtime;
- Raw stays mounted when needed for terminal continuity;
- Raw carries a compact Conversation return action;
- no permanent full-width Conversation/Raw selector is required;
- structured adapters that do not expose a second TUI continue to say so explicitly.

## Conversation chrome

Chrome inside Conversation should also be progressive.

Permanent conversation identity should be compact. Controls that only matter for an interactive terminal menu should appear when such a menu is actually present rather than occupying a row at rest.

Copy turn, transcript actions, provider-reported tool activity, Raw access, retained-history diagnostics, and other thread-local actions remain available without turning the thread into a dashboard.

## Inline code and tool activity

The typed OpenCode activity projection from the prior #37 work is retained:

- only structured provider `tool` / `patch` events with exact session identity are admitted;
- successful arbitrary tool output is not copied into cards;
- provider-reported state remains labelled as provider-reported, not independently verified;
- exact in-project paths may open the existing Source Workbench;
- PTY-only agents do not receive invented structured activity.

Workbench, source browsing, and diff inspection are on-demand surfaces. They do not replace Conversation as the default workspace.

## Copy, selection, logs, and retained history

The previously qualified behavior remains part of the candidate:

- continuous native selection inside an assistant turn;
- Copy turn;
- Copy transcript;
- explicit Markdown export;
- reveal exact retained JSONL in Finder;
- fenced code survives copy/export;
- append-only `~/.conduit/conversations/` remains the durable conversation source;
- export/copy never silently writes into MainFrame or Git.

## Streaming boundary

The shell is based on merged #40.

Normal structured streaming must keep its high-frequency presentation updates local to Conversation. Opening or closing secondary panels must not reintroduce broad task-catalog invalidation.

The intermittent post-completion pin observed during the #37 investigation remains a separate unresolved observation. Non-reproduction is not a fix claim.

## Authority boundaries

This redesign changes presentation topology, not authority.

- MainFrame files remain project/knowledge truth.
- Raw remains PTY/TUI authority where applicable.
- structured provider events remain provider-reported unless independently observed elsewhere.
- task/runtime identity stays below the shell.
- opening, closing, overlaying, or pinning UI panels has no lifecycle meaning.
- Conversation JSONL remains private local append-only history.
- Explore and Orchestrate remain explicit alternate workspaces rather than hidden semantic modes of Conversation.

## Acceptance conditions

The candidate is ready for review only when an installed macOS build demonstrates all of the following:

1. Sessions opens with Conversation + composer occupying the usable window, with no dashboard stack above it.
2. Tasks opens as a left overlay; closing it restores full chat width; pinning it shrinks chat without remounting the runtime.
3. Inspector behaves equivalently from the right.
4. Narrow windows fall back to overlays rather than squeezing Conversation below the policy minimum.
5. Raw switches on the same mounted runtime and returns to Conversation without state loss.
6. New Task, Tools, Explore, Orchestrate, resources, agent usage, diagnostics, context, and project browsing remain reachable.
7. selection/copy/export/log-reveal behavior from the previous candidate still works.
8. structured activity cards remain honest and Workbench deep links resolve only exact in-project paths.
9. Shell and structured OpenCode smoke remain green.
10. normal structured streaming does not reintroduce the #39 sidebar/catalog invalidation storm.
11. composer typing, scrolling, task drawer, and Inspector remain usable while output streams.

## Qualification posture

Implementation and qualification are separate roles.

The implementation is authored in GitHub on the product branch. A local macOS qualification agent may compile, test, build, install, profile, and exercise the exact candidate, but must not modify product source during the qualification pass. Failures return to the implementation thread for correction.

Do not merge based on code inspection alone.
