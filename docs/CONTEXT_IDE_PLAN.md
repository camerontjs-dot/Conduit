# Conduit Context IDE

Status: active product direction, implementation beginning on Draft PR #33.

## Product thesis

Conduit should not become a conventional code-first IDE. Its primary object is context: the exact material an agent can see, the authority behind that material, the task and repository scope it belongs to, what changed since a prior handoff, and the evidence produced in response.

Code remains important, but it is one context source alongside Markdown, research, Git state, tests, receipts, terminal observations, task history, issues, pull requests, MindGraph retrieval, lifecycle records, and other agents' outputs.

Working model:

- MainFrame is the durable world.
- Conduit is the context IDE and agent workbench.
- Agents are bounded workers operating on explicit context.
- GitHub, tests, receipts, and preserved failures are evidence surfaces.

The UI should make unsupported context claims difficult to sustain. A user should be able to answer: what does this agent know, why does it know it, which exact object is it acting on, what changed since the last handoff, and what came back?

## Existing foundation already in flight

Draft PR #33 is the current integrated experience batch. It includes or is assembling:

- lifecycle-first Explorer navigation with System Files demoted from primary visual weight;
- focused project and operation scopes;
- multiple document tabs while preserving one conflict-safe writable buffer;
- readable Markdown Read / Source / Edit separation;
- deterministic Find over bounded MainFrame content;
- authored outgoing links and backlinks;
- MindGraph query as an explicitly separate semantic nomination path;
- Graph surfaces: Orbit, Atlas, Pathfinder, and Radar;
- Workstation project/operation surfaces derived from lifecycle authority;
- evidence-bound agent sprites only where a real task/runtime association supports the scope;
- task association edges in Graph as their own provenance-bearing relationship class.

These remain Draft / unqualified until one exact integrated head passes local macOS compile, test, build, install, and installed-app acceptance.

## Context IDE primitives

### 1. Context Stack

Every active agent task should expose an inspectable context stack. It can contain:

- current task objective;
- project / operation / repository scope;
- exact Git commit and branch when applicable;
- pinned files and selected excerpts;
- Git diff or working-tree observations;
- test failures and qualification receipts;
- PRs and issues;
- terminal observations;
- task-history excerpts;
- agent-produced material;
- MindGraph nominations;
- operator notes.

The stack is presentation / delegation state unless a separate durable record explicitly persists it. It must not become hidden project authority.

### 2. Context authority and provenance

Every context item should identify its source class. Initial authority vocabulary:

- filesystem source;
- Git commit / immutable Git object;
- Git working-tree observation;
- operator-pinned input;
- lifecycle record;
- test / qualification receipt;
- terminal observation;
- task history;
- PR / issue record;
- MindGraph semantic nomination;
- agent-produced output.

MindGraph output remains a retrieval nomination. Agent output remains an output. Neither silently becomes authored source truth.

### 3. Context Preview

Before delegation, the user should be able to inspect exactly what will be sent:

- objective and instructions;
- exact scope;
- exact commit / branch identity;
- selected files and excerpts;
- receipts and failures;
- previous outputs included in the handoff;
- source / authority labels;
- rough token or size contribution by item.

No invisible context soup.

### 4. Context snapshots and handoffs

Important agent turns should be able to retain a lightweight snapshot of the context actually supplied. This enables:

- exact reproduction of a prior handoff;
- comparison between what two agents saw;
- audit of a surprising answer;
- agent-to-agent delegation without manual reconstruction;
- explicit inclusion of the predecessor agent's output without pretending it is source truth.

### 5. Context Diff

Conduit should answer: what changed since I last asked this agent?

Useful change classes:

- commit / branch moved;
- file added, removed, or changed;
- selected excerpt changed;
- new or invalidated test receipt;
- new PR / issue state;
- new MainFrame lifecycle record;
- new terminal observation;
- new MindGraph nomination;
- stale context item detected.

### 6. Staleness and identity

Context should warn when an item no longer matches the current object. Examples:

- file content from an older commit;
- a diff against a superseded branch head;
- a test receipt tied to a different SHA;
- a task output produced before the implementation changed;
- a semantic nomination whose source path is no longer present.

The UI should prefer exact identity over vague freshness labels.

### 7. Context budget

Show which items consume context budget. Let the user include, exclude, pin, or replace with a bounded summary. Token count is useful, but provenance and identity are more important than merely fitting the model window.

### 8. Context recipes

Provide transparent presets rather than invisible automation. Candidate recipes:

- Review PR;
- Investigate failure;
- Implement issue;
- Research architecture;
- Qualification run;
- Reproduce bug;
- Agent handoff.

A recipe nominates useful context classes. The final bundle remains inspectable before send.

## IDE-capable source workbench

Conduit should be able to inspect and edit source comfortably without trying to reproduce VS Code.

### First source-workbench slice

- syntax-aware source presentation for common text/code formats;
- line numbers and current-line emphasis;
- selection and copy with exact `path:line` identity;
- Find / Replace within the current file;
- conflict-aware explicit save for approved UTF-8 source types using the existing exact-file writer;
- code/source tabs;
- split view for two files or source beside diff / test output;
- source outline for symbols where a deterministic lightweight parser is available;
- Git status and diff inspection;
- direct navigation from compiler/test diagnostics to file and line;
- Open Terminal Here / Run Tests as explicit actions using existing Conduit runtime surfaces rather than creating a second shell architecture;
- file history / blame / open-at-commit where Git evidence is available.

### Agent-native source actions

Selection should be usable as context directly:

- Explain Selection;
- Ask Current Agent;
- Start Task From Selection;
- Review This File;
- Investigate This Failure;
- Add Selection to Context;
- Copy Selection With Location.

These actions must include exact repository / path / line / commit identity when available.

### Deferred until real use justifies them

Do not turn the first Context IDE into an unfinished conventional IDE. Defer:

- full Language Server Protocol architecture;
- autocomplete / completion engines;
- inline ghost-writing;
- debugger / breakpoint system;
- package-manager UI;
- large refactoring engine;
- provider-specific coding-assistant replicas.

## Source Context Inspector

Selecting a file or source range should be able to expose a compact inspector containing, where evidence exists:

- repository and current branch;
- exact commit / HEAD;
- relative and absolute path;
- selected line range;
- Git working-tree status;
- enclosing symbol;
- related tests;
- recent commits touching the file;
- open PR containing it;
- associated Conduit task(s);
- authored links / backlinks for documents;
- MindGraph nominations in a separate section;
- action to add exact source context to the current task.

Do not invent unavailable Git, symbol, test, or task relationships.

## Hover explainer design rule

The user explicitly prefers pop-up explanations on hover. Conduit should adopt this as a product rule, especially because many controls carry authority implications.

### Simple controls

Use a compact explanation:

- action name;
- one-sentence effect;
- shortcut when applicable.

### Consequential or unusual controls

Use an anchored explainer card with:

- what it does;
- what object / scope it affects;
- what it does not do;
- current target when known;
- authority / provenance boundary when relevant;
- shortcut.

Examples:

**MindGraph**

Searches semantic project knowledge. Results are retrieval nominations, not filesystem relationships. Does not modify MainFrame.

**Save**

Writes only the selected file after confirming the disk source still matches the edit baseline. Does not rename, move, or write adjacent files.

**Resume Task**

Attaches Conduit to the existing runtime. Does not create a new task or restart the agent.

### Interaction

- short hover delay, approximately 350-500 ms;
- keyboard-focus access as well as pointer hover;
- no permanent explanatory clutter;
- standard `.help` text remains as an accessibility / fallback layer;
- informational cards do not themselves mutate state;
- no tooltip should claim authority not present in the underlying action.

Future option: an advanced / Option-hover form can expose source authority, mutation class, and scope for power users.

## Agent visual layer

Pixel sprites remain presentation only. Existing Conduit sprite contracts and the Mainframe-pixel-sprites handoff remain authoritative for art provenance and identity. A sprite may decorate a task / station only when a real runtime/task association supports that scope. Visual identity never establishes completion, success, verification, progress, or even current execution by itself.

## Implementation sequence

### Phase A: foundation, begin now

1. Add durable Context IDE product plan (this document).
2. Add typed context item / bundle / snapshot / diff primitives in `ConduitCore`.
3. Add a reusable hover `ActionExplainer` component in the macOS UI.
4. Add a read-only Context Stack preview / inspector UI over the typed primitives.
5. Keep these primitives epistemically typed so later UI cannot quietly merge filesystem facts, Git identity, semantic nominations, terminal observations, and agent output.

Acceptance: pure context-diff / authority behavior is unit-testable; UI compiles on macOS; no filesystem or agent authority added.

### Phase B: wire the current Explorer / Workstation batch

1. Attach explainers to high-value controls first: Find, MindGraph, Links, Save, Discard, Graph modes, Workstation routing, Resume / reconnect actions.
2. Expose selected Explorer file / scope as initial Context Stack items.
3. Add explicit `Add to Context` and `Preview Context` actions without sending anything automatically.
4. Show exact path and known Git / task identity when available.

Acceptance: preview shows only observed inputs; no hidden sends or mutation.

### Phase C: source workbench

1. Generalize the current conflict-aware writer from Markdown-only UI policy to an allowlisted UTF-8 source policy.
2. Add source reader/editor with line numbers and syntax-aware presentation.
3. Add `path:line`, selection-to-context, Find / Replace, source outline, split view.
4. Add Git status / diff and diagnostic navigation.

Acceptance: explicit exact-file saves only; dirty navigation remains fail-closed; unsupported / generated / oversized / symlink targets remain read-only.

### Phase D: agent-context workflows

1. Context Preview before send.
2. Context snapshots tied to task/turn identity.
3. Context Diff since prior handoff.
4. Agent-to-agent handoff.
5. Transparent context recipes.
6. Context budget and staleness warnings.

Acceptance: every delegated item has inspectable provenance and exact identity where available; semantic/agent-derived material stays labelled.

### Phase E: use-driven refinement

Evaluate whether actual use justifies LSP, richer symbol resolution, deeper Git tooling, or debugger features. Do not assume conventional IDE feature parity is the target.

## Testing strategy

The user currently prefers batching the discussed experience features before the next local installed-app session. Therefore:

- keep PR #33 Draft;
- implement the coherent batch on one exact branch;
- preserve existing Core tests and add focused tests for new pure context logic;
- do not interpret exhausted GitHub macOS runners as product-code failure;
- before promotion, freeze one exact head and run local macOS compile, focused/full tests, build, codesign/install identity, installed canary, and an integrated acceptance session;
- use that session to refine interaction design rather than prematurely demanding theoretical closure on every Context IDE feature.
