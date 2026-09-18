# Explorer and Graph navigation reset

Status: implementation plan

Date: 2026-09-17

Base: `main` at `8f4a00d0c133f575c7f7d4be7cbf6e396638a311`

## Objective

Make MainFrame easier to navigate without hiding the filesystem, and make Graph understandable and responsive enough to be useful in ordinary work.

This slice is deliberately isolated from the active agent/conversation shell work in PR #41. It should not modify Conversation, task drawer, Inspector shell geometry, provider activity cards, Raw presentation, or agent-runtime semantics.

## Observed product problems

1. Explorer currently optimizes density by separating lifecycle roots from a collapsed `SYSTEM FILES` section and by presenting project/operation scopes shallowly. That makes real source trees feel hidden, especially code under project folders.
2. The sidebar contains multiple navigation concepts at once: lifecycle roots, focused scope duplication, system-file disclosure, Quick Open, and MindGraph. The result is less predictable than a normal project tree.
3. Graph exposes Orbit, Atlas, Pathfinder, Radar, edge classes, depth controls, MindGraph overlays, task associations, and refresh behavior before the basic mental model is clear.
4. Graph projection/layout can be recomputed from live task/runtime publications even when the visible relationship set has not materially changed, which is a plausible contributor to lag and unstable-feeling scenes.
5. Generic folder/file glyphs give weak visual landmarks in large trees.

## Product principles

### Filesystem first

The canonical Explorer view is the complete selected MainFrame tree. A file should not disappear from ordinary navigation because it is source code, configuration, non-lifecycle material, or outside a validated work record.

Lifecycle, scope, Git, task, and semantic information annotate the tree. They do not replace it.

### Simplify by views, not deletion

Optional views may reduce what is shown temporarily, but `All Files` remains the default and always provides a route back to the complete tree.

Candidate secondary views:

- All Files
- Current Scope
- Open Files
- Changed Files
- Recent
- Lifecycle

The first implementation does not need every view. Prefer a small useful subset over a new mode maze.

### Progressive disclosure

Use ordinary project-navigation techniques:

- folders collapsed by default;
- remembered expansion state;
- folders before files;
- compact single-child folder chains where it genuinely helps;
- active-file reveal;
- Quick Open / Cmd-P;
- local filter/search above the tree;
- recent and pinned locations later if use demonstrates value.

Generated/dependency directories may be visually de-emphasized and may be excluded from expensive indexing, but they should not silently disappear from `All Files`.

## Explorer V1 behavior

### Default tree

Replace the current lifecycle-versus-system split with one canonical `ALL FILES` tree derived from the real MainFrame root.

The seven lifecycle directories may keep friendly labels and badges, but they remain ordinary directories in the same tree.

Validated project/operation identity should be shown as a small badge or secondary marker on the corresponding directory row rather than forcing a separate duplicate focused-scope tree.

### Scope navigation

A project/operation may offer `Focus Scope`, but focus is an explicit temporary view. Closing focus returns to `All Files` with the previously selected path still revealable.

Do not truncate project/operation descendants merely because they live under `30_projects` or `40_operations`.

### Filter and reveal

Add a lightweight tree filter that matches names/paths without becoming semantic retrieval. Keep Quick Open for broader path jumping.

When a file is opened from Find, Graph, MindGraph, Workstation, diagnostics, or Source Workbench, Explorer should be able to reveal that exact file in `All Files` without changing authority or silently entering a scope mode.

## Semantic pixel glyph system

The goal is not decoration for decoration's sake. The tree needs stronger visual landmarks.

Introduce a small programmatic pixel-glyph system for Explorer rows. It should be crisp, cheap to render, accessible, and presentation-only.

### Why programmatic first

- no runtime dependency on the separate sprite repository;
- no redistribution/licensing ambiguity;
- no asset-loading latency;
- easy scaling for Retina displays;
- deterministic mapping from visible file/path facts;
- easy to keep status/progress semantics out of the iconography.

### Candidate glyph categories

Folders:

- ordinary folder
- lifecycle root
- project
- operation
- source/code
- tests
- docs/knowledge
- assets/resources
- configuration
- generated/dependency
- archive

Files:

- source code
- Markdown/docs
- test/spec
- JSON/YAML/TOML/config
- shell/script
- image/asset
- Git/control file
- generic text
- unknown/binary

Use distinct silhouettes/pixel marks, not color alone, so the tree remains legible in different themes and for color-vision differences.

### Authority boundary

A pixel glyph may communicate presentation category only. It must never imply:

- task success;
- completion;
- verification;
- agent activity;
- priority;
- health;
- merge state;
- lifecycle progress.

Heuristic categories such as `Sources`, `Tests`, `docs`, `.build`, or file extension are allowed only as visual organization hints. They are not project truth.

Agent sprite poses remain a separate visual vocabulary tied to observed runtime facts. Do not reuse agent pose semantics for filesystem rows.

## Graph product reset

The default Graph experience should answer one question:

> What is directly related to the thing I am looking at?

### Default: Related

Replace the mode-first experience with a small local neighborhood around the selected source-backed file/project/operation.

Default properties:

- one hop;
- roughly 10-24 visible nodes;
- stable focus at the center;
- authored links, containment, and explicit task associations enabled by default;
- semantic nominations visually distinct and opt-in via MindGraph;
- clicking a node selects it;
- an explicit `Center here` action recenters the local neighborhood;
- `Open in Explorer` reveals the exact source path.

The UI should explain the visible relationship classes in plain language rather than requiring the operator to understand Graph internals first.

### Advanced graph tools

Atlas, Pathfinder, Radar, edge toggles, and depth controls remain available, but move behind an `Advanced` disclosure/menu so they do not define the first-run mental model.

Radar continues to label MindGraph results as nominations, never authored/source-backed relationships.

### Stability and performance

The visible graph should not churn merely because a runtime emitted another status/output publication.

Implementation direction:

- derive a stable visible-scene signature from node IDs + edge IDs/classes + focus + mode;
- reuse layout while that signature is unchanged;
- only rebuild task overlays when the actual task-association set changes;
- only rebuild observed Workstation facts when their projected values change;
- avoid whole-graph refreshes for presentation-only runtime state changes;
- keep local-neighborhood node caps small;
- move expensive indexing/layout work off the main actor where practical while preserving current authority boundaries.

Do not claim the current lag cause until profiling or before/after instrumentation confirms it.

## Interaction hierarchy

The intended Explore hierarchy becomes:

```text
Explorer / All Files
    canonical filesystem navigation

Related
    small local relationship view for the selected thing

Workstation
    lifecycle + observed task/runtime projection

Advanced Graph
    Atlas / Pathfinder / Radar / relationship controls

Find / Quick Open / MindGraph
    explicit navigation/retrieval tools
```

## Non-goals

This slice does not:

- redesign the active Conversation shell in PR #41;
- change agent/task/runtime identity;
- infer authority from pixel art;
- turn Graph into project truth;
- hide files to obtain a cleaner screenshot;
- add automatic Git mutation;
- add LSP/project-index semantics merely for navigation;
- replace MainFrame's filesystem/lifecycle authority.

## Evidence plan

### Deterministic tests

Cover at least:

- `All Files` includes lifecycle and non-lifecycle roots without hidden `SYSTEM FILES` behavior;
- project/operation descendants remain navigable without forced focused-scope duplication;
- filter/reveal preserves exact paths;
- glyph classification is deterministic and presentation-only;
- generated/dependency categories remain visible;
- Related graph node cap / one-hop behavior;
- unchanged relationship inputs do not invalidate cached layout/projection;
- changed task associations do invalidate the relevant overlay;
- Radar nominations remain non-authoritative.

### Installed macOS acceptance

Every user-visible UI change requires exact-build installed-app review, not source/tests alone.

Exercise:

- a real project with Swift/source files, tests, docs, config, generated material, and nested folders;
- verify all are reachable in default `All Files`;
- evaluate scanability of pixel glyphs at normal and compact sidebar widths;
- open/reveal from Quick Open, Find, Graph, Workstation, and Source Workbench;
- compare Graph interaction latency before/after on the same MainFrame root;
- confirm Related stays stable during unrelated agent output/runtime publications;
- verify Advanced tools remain reachable;
- verify PR #41 conversation/session behavior is unaffected after eventual integration.

## Exit condition

This slice is ready to merge when:

1. the default Explorer behaves like a complete, predictable file navigator;
2. pixel glyphs improve landmarks without carrying false authority;
3. ordinary Graph use is understandable as `Related to this` without learning four modes first;
4. the observed lag/stuck behavior is either materially reduced with evidence or preserved as an explicit unresolved defect with a bounded next experiment;
5. exact installed macOS acceptance passes on the qualified commit.
