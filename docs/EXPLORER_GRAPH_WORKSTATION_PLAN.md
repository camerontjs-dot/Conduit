# Conduit Explorer, Graph, and MainFrame Workstation Plan

Status: proposed product/engineering plan
Date: 2026-09-12
Last usability calibration: 2026-09-14
Scope: Conduit UI/navigation/retrieval programme
Authority boundary: planning document only; no implementation, promotion, release, or MainFrame lifecycle mutation is implied by this file.

The 2026-09-14 calibration incorporates direct use of the first installed Explorer shell. It confirms the overall Explore → Graph → Workstation direction while changing several presentation priorities: the reader should wrap and render Markdown by default, ordinary prose should use a readability-first proportional font, file-path actions should be first-class, symlink targets should be inspectable without weakening traversal safety, Explorer should use the application's actual sidebar rather than nesting a second rail, and bounded Markdown editing should become a later maintained capability rather than a permanent non-goal.

## 1. Objective

Turn Conduit into a native visual interface for understanding and operating a MainFrame installation without replacing MainFrame's file-backed authority model.

The programme should provide three complementary surfaces over the same underlying MainFrame root:

1. **Explore** — a simple, dependable file explorer and Markdown reader for everyday navigation.
2. **Graph** — an investigative relationship view for links, paths, clusters, retrieval nominations, and spatial understanding.
3. **Workstation** — a higher-level visual overview that combines lifecycle regions, project/operation context, agent/task presence, observed work evidence, and navigational history into a useful sense of orientation and progression.

`Work` / Conversation / Raw remain the execution surfaces. Explore, Graph, and Workstation must not become parallel sources of project truth.

The target product experience is:

> Open Conduit and move naturally from a MainFrame file, to its surrounding context, to the project or operation that owns it, to linked or related material, to observed work associated with that scope, and back to the exact underlying file or task without losing provenance.

## 2. Product principles

### 2.1 Filesystem first

MainFrame files remain authoritative. Conduit may build temporary derived indexes for navigation, search, backlinks, graph layout, and presentation, but it must not introduce a shadow project or knowledge database.

Every visual node, edge, badge, progress signal, and relationship must be traceable to an inspectable source.

### 2.2 Simple navigation remains first-class

The visual system must never make the ordinary file explorer worse.

A user who wants only folders, files, search, breadcrumbs, and a Markdown reader should be able to ignore Graph and Workstation entirely.

### 2.3 Progressive disclosure

The default experience should be calm and obvious. More advanced controls appear when the operator asks for them.

Examples:

- Explorer begins with the file tree and reader, not graph controls.
- Graph begins with a local one-hop view, not every file in MainFrame.
- MindGraph semantic retrieval is opt-in and visually distinct.
- Detailed provenance, trust metadata, Git evidence, and runtime diagnostics live in the Inspector rather than crowding the canvas.

### 2.4 Stable spatial memory

Graph positions and Workstation regions should be deterministic enough that revisiting the same scope feels familiar.

Avoid gratuitous force-directed movement. A graph that continuously rearranges itself is visually exciting but difficult to learn.

### 2.5 Fun must not imply false state

Pixel art, motion, spatial navigation, agent companions, route trails, and scene transitions may make the app enjoyable.

They must not fabricate:

- agent thinking;
- progress percentages;
- project health;
- verification;
- successful completion;
- readiness;
- approval;
- activity that has not actually been observed.

### 2.6 MainFrame lifecycle semantics remain intact

Conduit should target the public MainFrame contract and support the current lifecycle tree:

```text
00_inbox/
01_ingest/
10_knowledge/
20_live/
30_projects/
40_operations/
90_archive/
```

`30_projects/<slug>` and `40_operations/<slug>` are distinct typed work records that share a cross-root slug namespace.

Folder location alone must never be treated as proof of health, focus, completion, or approval.

## 3. Proposed top-level Conduit surfaces

The application should evolve toward these complementary workspaces:

```text
Conduit
├── Work
│   ├── Conversation
│   ├── Raw
│   ├── task history
│   └── receipts / execution context
├── Explore
│   ├── MainFrame tree
│   ├── Markdown reader
│   ├── deterministic search
│   ├── backlinks / outgoing links
│   └── document/work context
├── Graph
│   ├── Orbit
│   ├── Atlas
│   ├── Pathfinder
│   └── Radar
└── Workstation
    ├── MainFrame lifecycle map
    ├── projects / operations
    ├── observed work signals
    ├── investigation / navigation trails
    └── optional pixel-art presentation layer
```

`Orchestrate` may remain a separate workspace where appropriate. This plan does not require collapsing existing workspaces.

### 3.1 Sidebar ownership

The first installed Explorer shell proved that a second file-tree rail nested inside the existing task sidebar creates unnecessary visual hierarchy.

The target topology is one first-class application sidebar whose contents adapt to the active workspace:

- **Work:** task/session navigation;
- **Explore:** MainFrame tree and file-navigation controls;
- **Graph:** scene/navigation controls and graph filters;
- **Workstation:** lifecycle/work-record navigation appropriate to the overview.

The active workspace may keep its own local Inspector or secondary controls, but it should not recreate a second primary sidebar inside the detail area unless a later usability test demonstrates a real need.

Workspace switching must preserve task/runtime continuity. Changing sidebar contents is presentation state, not permission to remount or replace active execution state.

## 4. Explore workspace

Explore is the reliable everyday interface and should be useful before Graph or Workstation exist.

### 4.1 Left rail: MainFrame tree

The file tree should present the entire selected MainFrame root while giving lifecycle roots stronger visual grouping.

Recommended presentation:

```text
MAINFRAME

Lifecycle
  ▸ Inbox
  ▸ Ingest
  ▸ Knowledge
  ▸ Live
  ▾ Projects
      Claim Audit Lab              PROJECT
      Evidence Bundler             PROJECT
  ▾ Operations
      AI Research Radar            OPERATION
  ▸ Archive

System
  ▸ .agents
  ▸ .context
  ▸ scripts
  ▸ other root surfaces
```

`Lifecycle` and `System` are Conduit presentation groups only. They do not relocate files.

Project and operation badges appear only when the record validates against the MainFrame lifecycle identity contract.

The tree should occupy the application's actual sidebar in Explore mode rather than a nested Explorer-only rail in the detail pane.

### 4.2 Core interactions

Explorer should support multiple routes to the same destination:

- mouse/tap navigation through the tree;
- keyboard tree navigation;
- Quick Open / fuzzy file search;
- deterministic full-text search;
- Back / Forward navigation history;
- breadcrumbs;
- heading navigation;
- Reveal in Tree;
- Recent Files;
- Collapse All;
- optional auto-reveal of the active file;
- Copy MainFrame-relative Path;
- Copy Absolute Path;
- Reveal in Finder where the platform permits it.

Suggested shortcuts:

```text
⌘P      Quick Open
⌘⇧F    Search MainFrame
⌘[      Back
⌘]      Forward
⌘L      Focus current path/breadcrumb
```

Exact shortcuts should be reconciled against existing Conduit shortcuts before implementation.

The breadcrumb/path surface should remain easy to select and should expose path-copy actions without requiring the operator to locate the same file elsewhere.

### 4.3 Reader

The initial implementation may remain read-only while the rendering and navigation boundary is qualified, but read-only source text is not the target reader experience.

The default Markdown reader should provide:

- rendered Markdown rather than raw Markdown syntax;
- normal line wrapping for prose;
- headings;
- lists;
- block quotes;
- code blocks;
- tables;
- ordinary Markdown links;
- local images where safe and resolvable;
- heading anchors;
- text selection;
- an Outline synchronized with the current heading;
- a source/raw Markdown mode for exact inspection.

Broken or unresolved links must be shown as broken/unresolved. Conduit must not guess targets.

#### Reader typography

Normal prose should use the native macOS system text face, effectively SF Pro Text through SwiftUI's system font APIs, rather than a monospaced font. This keeps the reader aligned with Dynamic Type/accessibility behavior and gives the best default readability without adding a font dependency.

Recommended reading posture:

- proportional system body text for prose;
- roughly 15–17 pt equivalent at the default scale;
- comfortable line spacing;
- a bounded readable text measure rather than an infinitely wide line, targeting roughly 70–85 characters for ordinary prose where layout permits;
- monospaced treatment only for source Markdown, code blocks, paths, hashes, terminal material, and other content whose exact character geometry matters.

A later reader preference may offer a system serif treatment and/or a qualified accessibility-oriented face, but the default should remain native and dependency-free until real use demonstrates a need for bundled fonts.

#### Bounded Markdown editing

Editing should become a later maintained Explorer capability after rendered reading and file-authority behavior are stable.

The preferred first editing model is deliberately simpler than Obsidian Live Preview:

- **Read** mode: fully rendered Markdown;
- **Edit** mode: wrapped Markdown source in the same reader area;
- optional split preview only if it remains useful after real use;
- visible dirty/saved state;
- explicit save command and standard keyboard save behavior;
- atomic file replacement where practical;
- conflict detection when the file changed on disk after the edit buffer was opened;
- failed writes leave the original file intact and surface the error visibly.

This slice does not authorize rename, delete, move, drag-to-reorganize, graph-created links, or a full syntax-hiding/WYSIWYG Markdown editor. A true Obsidian-style Live Preview may be considered later if the simpler Read/Edit model proves insufficient.

### 4.4 Explorer Inspector

The existing right Inspector should be reused rather than creating another floating panel.

Suggested sections:

**Outline**
- heading hierarchy;
- current heading;
- click to navigate.

**Links**
- incoming links/backlinks;
- outgoing explicit links;
- unresolved links.

**Document**
- path;
- lifecycle zone;
- record type where validated;
- frontmatter;
- basic filesystem facts;
- path-copy actions;
- symlink target and target classification where applicable.

**Related**
- optional MindGraph nominations;
- explicit scope/trust/retrieval metadata;
- always labelled as retrieval nominations rather than authored relationships.

**Work**
- observed Conduit tasks/sessions associated with the validated project/operation scope;
- agent identity and lifecycle labels derived from existing Conduit task/runtime evidence;
- optional sprite companion as presentation only.

### 4.5 Symbolic links

The current fail-closed non-traversal rule remains the safety default, but a symbolic link should be informative rather than opaque.

For a selected symlink, Explorer should expose:

- the link path;
- the raw/resolved target where the operating system can provide it safely;
- whether the target resolves **inside MainFrame**, **outside MainFrame**, or is **missing/unresolved**;
- an explicit `Open Target` action only when the resolved target remains inside the selected MainFrame root and the same path-safety checks succeed.

Explorer must not recursively traverse symlinked directories during ordinary tree scans or indexing. External targets may be displayed as facts without silently expanding the filesystem authority boundary.

## 5. Deterministic search versus semantic retrieval

Conduit should preserve a hard distinction between finding and retrieving related material.

### Find

Question answered:

> Where does this path, filename, text, heading, or tag actually occur?

Properties:

- deterministic file/path/text search;
- no embedding requirement;
- no semantic inference;
- results link directly to source locations.

### Related

Question answered:

> What does MindGraph nominate as potentially relevant to this file or question?

Properties:

- operator-triggered;
- visibly separate from authored links;
- trust profile and retrieval metadata remain available;
- no result is presented as verified merely because retrieval returned it.

The UI should never blend these into one unlabeled result list.

## 6. Graph workspace

Graph should be an investigative environment, not a decorative global hairball.

The default graph should be local and intentionally small.

The Graph workspace remains an explicit part of the programme. Its absence from the first installed Explorer shell reflects implementation sequencing, not removal from the product direction.

### 6.1 Graph relationship classes

Every visible edge must have a type and provenance.

| Relationship | Meaning | Source |
| --- | --- | --- |
| authored link | one Markdown document explicitly links another | file content |
| containment/region | file belongs to a path/lifecycle region | filesystem path |
| work-record identity | node is a validated project or operation | direct README + MainFrame lifecycle contract |
| semantic nomination | MindGraph returned a related result | retrieval output only |
| task/session association | observed Conduit task/session is scoped to the work record | Conduit task/runtime evidence |
| path highlight | Conduit computed a route through selected edge classes | derived from graph model |

Incoming and outgoing authored links are two directions over the same explicit-link graph. A backlink is not a new epistemic relationship.

### 6.2 Orbit

Orbit is the default Graph mode.

It centers one selected document or work record and shows a deterministic local neighbourhood.

Default:

- depth 1;
- authored links only;
- incoming + outgoing enabled;
- semantic nominations disabled;
- stable radial or layered layout;
- selected node visually central;
- node count kept intentionally bounded.

Controls may expose depth 1–3 and relationship filters.

Orbit is intended to answer:

- What does this file point to?
- What points here?
- What is immediately around this project/decision/note?

### 6.3 Atlas

Atlas is a broader MainFrame overview.

Instead of encoding every directory parent/child pair as graph edges, MainFrame lifecycle zones become spatial regions or districts.

Conceptually:

```text
┌──────────── KNOWLEDGE ────────────┐
│     linked knowledge nodes        │
└───────────────────────────────────┘

┌──────────── PROJECTS ─────────────┐
│  CAL        Evidence Bundler      │
│       Decision Engine             │
└───────────────────────────────────┘

┌─────────── OPERATIONS ────────────┐
│  recurring programmes / controls  │
└───────────────────────────────────┘
```

The region means only that the item resides in that lifecycle root. It does not imply state.

Atlas should load a bounded meaningful subset first and allow the operator to expand the scene deliberately.

### 6.4 Pathfinder

Pathfinder answers:

> How are these two selected nodes connected through the currently allowed relationship classes?

With two nodes selected, Conduit may compute a shortest path through explicit authored links or another explicitly selected edge class.

The route is highlighted and unrelated nodes are dimmed.

If no explicit path exists, Conduit may later offer:

> No explicit path found. Search for semantic bridge candidates?

That semantic step must require an explicit operator action and remain visually distinct from the authored path.

### 6.5 Radar

Radar is the MindGraph graph lens.

The existing explicit graph remains in place. When the operator chooses `Find Related`, semantic nominations appear as a separate layer around the current scene.

Recommended visual language:

- solid edge: authored link;
- region placement: filesystem containment;
- dashed/faint edge: semantic nomination;
- provenance label or Inspector explanation available on selection.

Radar must be optional and the graph must remain useful when MindGraph is unavailable.

## 7. Graph scene model

Treat the interactive graph as a **scene** rather than a global database view.

A scene contains only what the operator has chosen to inspect or expand.

Local scene state may include:

- displayed node IDs/paths;
- edge-class filters;
- focus node;
- selected nodes;
- graph mode;
- depth;
- camera/zoom state;
- temporary manual positions;
- recent navigation trail.

Scene state is presentation state, not project or knowledge authority.

Initial implementation should keep scene state ephemeral. Durable saved scenes may be considered later if repeated use demonstrates value.

## 8. Workstation: visualizing MainFrame as a working system

Workstation is the creative layer above Explorer and Graph.

It should answer a different question:

> What is happening across my MainFrame, where is my attention, and what evidence of movement actually exists?

It should not become a kanban clone or a fake game dashboard.

The Workstation also remains in the implementation programme. It should not be exposed merely as an empty placeholder before the underlying Explorer/Graph projections can support a useful interface.

### 8.1 MainFrame map

The Workstation can render lifecycle regions as a spatial overview:

```text
                 MAINFRAME

   [Knowledge Archive]       [Live Control Room]
             │                      │
             └───────┬──────────────┘
                     │
              [Projects Lab]
             /       |       \
           CAL      EB       DE
                     │
              [Operations Tower]
```

This can use restrained pixel-art environmental motifs after navigation is proven useful.

Clicking any building/region/work record must open the actual corresponding Explorer scope or file.

### 8.2 Work cards / stations

Validated projects and operations can appear as stations or workbenches rather than generic dots.

A station may show only inspectable signals, for example:

- record type;
- explicit lifecycle/project state from README where present;
- current `goal` and `next_action` where present;
- observed local Git state when intentionally queried;
- open Conduit task/session count for that exact scope;
- recorded work-session receipt availability;
- explicitly recorded test/verification receipts where Conduit can identify them without guessing;
- last source update timestamp as a fact, never as a health score.

Every signal must link to its source or explanation.

### 8.3 Evidence-grounded progression

The interface should provide a satisfying sense of movement without fake percentages.

Use **progression as accumulated inspectable evidence**, not XP.

Possible progression lenses:

#### Navigation trail

Show the investigation path the operator actually followed:

```text
Evidence Bundler
  → Contract B
  → CAL
  → Decision Engine
```

Recently traversed graph edges can remain subtly highlighted until the scene is cleared.

This reflects operator navigation only.

#### Work movement

For a selected project/operation, show a chronological strip of observed records when available:

```text
README state updated
→ task created
→ files changed
→ test receipt recorded
→ PR opened
→ verification receipt recorded
```

Only include event types for which Conduit has a direct source. Missing evidence remains missing.

#### Acceptance checklist

When a project document itself contains explicit acceptance criteria or task checkboxes, Conduit may render those exact checkboxes as a navigable progress view.

Do not generate a completion percentage unless the denominator is a literal bounded checklist and the UI clearly states what was counted.

#### Evidence trail

For research/engineering work, allow the operator to see the growing chain of durable receipts:

```text
hypothesis / objective
→ implementation or experiment
→ test / observation
→ failure or result
→ review
→ decision / next action
```

This is particularly appropriate for MainFrame because progression can mean **better evidence**, not merely more completed tasks.

#### Attention map

Workstation may highlight where attention is concentrated based on actual recent navigation, current selected tasks, and explicit operator pins.

It must not infer that neglected areas are unhealthy or that busy areas are important.

### 8.4 No universal progress bar

There should be no default `73% complete` for a project.

Projects, operations, research experiments, maintenance work, and open-ended programmes do not share one meaningful denominator.

Progress should instead be shown through typed evidence views such as:

- explicit state;
- explicit checklist completion;
- evidence trail;
- navigation/history trail;
- recorded milestones;
- Git/PR/test receipts;
- current next action.

## 9. Pixel-art and agent companion layer

Pixel art should strengthen identity and orientation after the functional navigation surfaces work.

Possible environmental motifs:

- Inbox: intake tray / hatch;
- Ingest: sorting bench;
- Knowledge: archive/library terminal;
- Live: control console/radar;
- Projects: lab/workshop;
- Operations: control tower/machinery;
- Archive: storage stacks.

Use the current Conduit sprite contract for agents.

An agent sprite may appear beside a work station only when Conduit has observed task/session association with that exact scope.

Pose semantics remain those already established by Conduit runtime evidence. The art must never imply progress, success, verification, or hidden activity.

Recommended restraint:

- Explorer: minimal pixel accents;
- Graph: small agent badges only where relevant;
- Workstation: strongest pixel/environmental treatment;
- Work: existing agent sprite treatment remains primary.

Public redistribution clearance for bundled art remains a separate release qualification concern.

## 10. Interaction model

Recommended graph interactions:

```text
Click                 select node
Enter / double-click  open node in Explore
Space                  focus / recenter selected node
E                      expand one hop
Shift-E                choose edge type before expansion
⌘ click                multi-select
Esc                    clear selection / step out
Back / Forward         graph focus history
Scroll / pinch         zoom
Drag background        pan
Drag node              temporary manual placement
```

Context actions may include:

- Open;
- Open in Explore;
- Focus Here;
- Expand Neighbours;
- Show Incoming;
- Show Outgoing;
- Find Related with MindGraph;
- Find Path From…;
- Hide From Scene;
- Hide Everything Else;
- Copy Path;
- Reveal in File Tree.

Every primary graph action must also have a non-pointer-accessible route through keyboard controls and/or the Inspector.

## 11. Accessibility and rendering boundary

Do not tie the graph data model to one rendering technology.

Recommended separation:

```text
Graph model / layout
├── visual renderer
└── semantic node + relationship representation
    ├── keyboard navigation
    ├── VoiceOver-accessible Inspector/list
    └── equivalent actions
```

Dense edges may eventually use Canvas/AppKit/Metal-backed rendering, but individual graph nodes and actions must remain semantically accessible.

Reduce Motion must preserve a fully usable static state.

## 12. Core architecture

Keep durable deterministic logic in `ConduitCore` where practical.

Candidate structure:

```text
ConduitCore
├── MainframeWorkRecord
│   ├── project
│   └── operation
├── MainframeTreeScanner
├── MainframeTreeNode
├── MarkdownDocumentParser
│   ├── frontmatter
│   ├── headings
│   └── explicit links
├── MainframeLinkIndex
│   ├── incoming
│   └── outgoing
├── ExplorerNavigation
├── MainframeSearch
├── GraphNode
├── GraphEdge
├── GraphScene
├── LocalGraphBuilder
├── GraphPathfinder
├── GraphLayout
└── WorkstationProjection

Conduit
├── ExploreWorkspaceView
├── MainframeTreeView
├── MarkdownReaderView
├── MarkdownEditorView
├── ExplorerInspectorView
├── QuickOpenView
├── SearchView
├── GraphWorkspaceView
├── GraphSceneView
├── GraphInspectorView
├── GraphLegendView
└── MainframeWorkstationView
```

Derived indexes must be rebuildable from their authoritative sources.

## 13. Implementation programme

### Slice A — public MainFrame compatibility reconciliation

Before Explorer UI, bring Conduit's model up to the current public MainFrame contract.

Required outcomes:

- `30_projects` project records supported;
- `40_operations` operation records supported;
- explicit record kind available to presentation;
- cross-root duplicate identity is an explicit diagnostic/failure, not first-wins behavior;
- malformed operation identity is surfaced honestly;
- existing project behavior remains compatible;
- no new `operations` MindGraph scope is invented;
- Conduit documentation stops describing MainFrame as project-only.

This is a compatibility/architecture prerequisite rather than Explorer polish.

### Slice B — read-only Explorer shell

Deliver a useful file browser before graph work.

Include:

- new Explore workspace;
- lifecycle-aware MainFrame tree;
- entire root available, not only projects;
- file selection;
- text/Markdown read-only display;
- breadcrumbs;
- Back / Forward;
- Quick Open;
- Reveal in Tree;
- Recent Files.

Usability calibration after the first installed shell:

- keep the qualified read-only filesystem safety boundary;
- move the MainFrame tree into the application's real sidebar in Explore mode rather than keeping a nested rail;
- preserve Sessions ↔ Explore runtime/task continuity while the rail contents change;
- add direct path-copy actions;
- display symlink target/classification without recursively traversing links.

### Slice C — Markdown reader and explicit-link index

Include:

- rendered Markdown as the default view;
- ordinary prose wrapping;
- native proportional system typography and readable line measure;
- source toggle using monospaced text;
- heading outline;
- link interception;
- deterministic outgoing-link index;
- backlinks/incoming index;
- broken-link handling;
- local image policy.

Do not assume wiki-link syntax unless the actual supported corpus demonstrates a requirement.

### Slice D — deterministic search and Explorer Inspector

Include:

- full-text/path search;
- Outline;
- Links;
- Document;
- path and symlink facts/actions;
- Work context;
- optional MindGraph Related section;
- auto-reveal preference.

Milestone outcome: Conduit is useful as a MainFrame reader/navigation tool even if Graph never ships.

### Slice D2 — bounded Markdown editing

Add editing only after the rendered reader and file-watch/conflict behavior are stable.

Include:

- Read/Edit mode in the reader area;
- wrapped source editor;
- dirty/saved state;
- explicit and keyboard save;
- atomic write behavior where practical;
- external-change conflict detection;
- write-error recovery that preserves the original file.

Do not include rename/delete/move, drag reorganization, graph-authored links, or full Obsidian-style Live Preview in this slice.

### Slice E — Orbit graph MVP

Include:

- graph model independent of renderer;
- explicit authored links only by default;
- depth 1–3;
- deterministic layout;
- pan/zoom/focus;
- selection Inspector;
- graph Back / Forward;
- Open in Explore;
- accessible equivalent node/edge list.

The first graph UI should expose Orbit before attempting a visually complete Atlas/Workstation environment. A small useful graph is the acceptance target.

### Slice F — Atlas and Pathfinder

Include:

- lifecycle-region spatial layout;
- bounded scene expansion;
- filtering;
- node isolation;
- multi-select;
- shortest-path traversal through selected explicit edge classes.

### Slice G — Workstation progression projection

Build the MainFrame visual overview only after Explorer and graph primitives are stable.

Include a deliberately small set of evidence-backed signals first:

- work-record identity;
- explicit goal/next action/state;
- observed task/session presence;
- navigation trail;
- explicit checklist state where available.

Experiment separately with Git, PR, CI, test, and receipt projections. Do not bundle all of them into the first Workstation slice.

### Slice H — MindGraph Radar

Add semantic nominations as an optional graph layer.

Acceptance requires visible distinction from authored relationships and preserved provenance/trust metadata.

### Slice I — pixel visual pass

Add approved lifecycle/environment artwork and agent companion integration after usability is proven.

The pixel pass should not be allowed to conceal missing labels, inaccessible interactions, or weak navigation.

## 14. Acceptance conditions

### Source-of-truth safety

- no shadow project/knowledge authority;
- no silent file mutation;
- no path traversal outside selected MainFrame root;
- symlink/root-escape behavior defined fail-closed;
- projects and operations follow public MainFrame lifecycle identity rules;
- invalid/ambiguous identities are visible rather than guessed.

When editing is enabled, `no silent file mutation` means every write is an explicit operator edit/save action with visible failure/conflict behavior, not that Conduit must remain permanently read-only.

### Explorer

- tree reflects filesystem changes after refresh/watch;
- the tree uses the application sidebar in Explore mode rather than a nested primary rail;
- switching between Work/Sessions and Explore preserves active task/runtime identity and retained output;
- selection alone does not mutate content;
- Markdown prose wraps and rendered Markdown is the default reader posture;
- normal reader prose uses readability-first proportional system typography; source/code/path surfaces remain monospaced where character geometry matters;
- ordinary prose does not require horizontal scrolling at normal window sizes;
- navigation history is deterministic;
- relative Markdown links resolve from source file location;
- broken links remain broken;
- file path can be copied directly as MainFrame-relative and absolute forms;
- symlink target/classification is inspectable without automatic directory traversal;
- Quick Open and search work without MindGraph;
- keyboard-only navigation is practical;
- VoiceOver exposes meaningful file/document structure.

When bounded Markdown editing is enabled:

- dirty/saved state is visible;
- save writes only the selected source file;
- an external modification after buffer load cannot be silently overwritten;
- failed save leaves the prior file content recoverable/intact;
- editing does not expand authority to rename, move, delete, or reorganize files.

### Graph

- every edge has a type and provenance;
- authored and semantic edges cannot be confused;
- same bounded input produces stable graph placement within the chosen layout policy;
- Pathfinder traverses only explicitly selected edge classes;
- semantic layer defaults off;
- Graph remains functional with MindGraph unavailable;
- accessible non-canvas representation exists.

### Workstation/progression

- no universal fake progress percentage;
- every progression signal identifies its source type;
- lifecycle folder does not imply status;
- agent presence comes from observed Conduit scope association;
- absence of evidence is not rendered as failure or inactivity;
- the operator can open the underlying source behind a signal.

### Pixel layer

- presentation only;
- existing sprite truth boundaries retained;
- Reduce Motion respected;
- accessibility labels remain canonical;
- missing/unapproved art falls back safely.

## 15. Verification strategy

Each implementation slice should use the strongest practical boundary for its claim.

Minimum deterministic coverage should include:

- synthetic project + operation fixtures;
- duplicate cross-root slug;
- malformed/missing operation metadata;
- relative/absolute/broken Markdown link cases;
- backlink computation;
- link cycles;
- graph depth bounds;
- deterministic layout snapshots/structural checks;
- Pathfinder with disconnected graphs and edge filters;
- path-root escape cases;
- symlink inside-root/outside-root/missing-target classification;
- reader wrapping/rendered-block coverage;
- path-copy value coverage;
- scenes with MindGraph unavailable.

Editing-specific verification, when that slice begins, should add:

- exact-file atomic save behavior;
- external-change conflict case;
- write failure without original-content loss;
- no authority expansion to adjacent files.

Before Atlas/Workstation scale claims, create a synthetic MainFrame fixture large enough to expose responsiveness and layout problems. Choose thresholds from measurement rather than inventing an unsupported performance number.

Repository verification should continue to include the existing Conduit test/build boundary as applicable:

```text
./scripts/test.sh
./scripts/build-app.sh
./scripts/verify-installed.sh
```

Installed-app acceptance should separately cover interaction quality against:

1. a public/synthetic MainFrame reference tree; and
2. the operator's populated local MainFrame installation.

Private inventory details must not enter the repository.

## 16. Explicit non-goals for the first programme

- full syntax-hiding/WYSIWYG or Obsidian-style Live Preview editing;
- rename/delete/move;
- drag-to-reorganize MainFrame;
- graph-created links;
- automatic semantic edges;
- a persistent graph database;
- a global force graph on launch;
- autonomous AI-generated summaries written into MainFrame;
- continuous agent sprite animation;
- inferred project-health scoring;
- inferred completion percentages;
- a new MindGraph operations scope;
- treating graph scene state as knowledge authority.

Basic bounded Markdown source editing is no longer a permanent non-goal; it is intentionally deferred to Slice D2 so the reader and filesystem safety boundary can be qualified first.

## 17. Design question to preserve during implementation

The programme should be evaluated against one central product question:

> Does this make MainFrame easier to understand and operate without making its evidence and authority boundaries harder to see?

If a visual feature is attractive but obscures where a claim, status, relationship, or progress signal came from, the design should be simplified rather than defended.

The intended end state is not merely an Obsidian-like file browser. It is a native MainFrame interface where:

- **Explorer is the map**;
- **the reader is the desk**;
- **links are the trails**;
- **Orbit is the neighbourhood**;
- **Atlas is the wider world**;
- **Pathfinder is the route finder**;
- **MindGraph Radar is the telescope**;
- **Workstation is the control room**;
- **agent sprites are the crew**;
- and the underlying files, receipts, runtime observations, and explicit records remain the evidence.
