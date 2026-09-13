# Explorer shell v0 remote preflight

Date: 2026-09-13

## Authority boundary

This receipt covers the remote-side staging work for the first read-only SwiftUI Explorer shell. It does **not** claim a macOS build, installed-app usability, or user-visible acceptance.

Base Conduit main observed before branching:

`420ab3b2e2d2a8d3783a0f342df3f2ee657c2444`

Branch:

`feat/mainframe-explorer-shell-v0-20260913`

## Staged implementation

`Sources/Conduit/MainframeExplorerWorkspaceView.swift`

The staged file provides a self-contained read-only Explorer workspace and workspace-local navigation state. It consumes the already-qualified `MainframeExplorerScanner`, `MainframeQuickOpen`, `MainframeNavigationHistory`, and `MainframeLifecycleScanner` surfaces from merged main.

The staged boundary includes:

- lazy one-directory-at-a-time expansion;
- lifecycle roots before system surfaces in presentation only;
- read-only UTF-8 source display;
- explicit symlink non-traversal messaging;
- bounded 20,000-entry Quick Open with visible truncation state;
- Command-P Quick Open while the Explorer view is mounted;
- back/forward navigation and breadcrumbs;
- reveal-in-tree for visited / Quick Open nodes;
- project/operation badges that become authoritative only when the lifecycle scanner validates the matching record;
- inline filesystem/lifecycle errors rather than task/runtime errors;
- no MainFrame writes, file mutation, task/runtime mutation, Graph, MindGraph, backlinks, or Workstation behavior.

Explorer selection/expansion state remains local to the view model rather than becoming AppModel task/runtime state.

## Static verification performed remotely

The exact staged Swift source was parsed with Swift 6.2.1 on x86_64 Linux:

```text
swiftc -parse MainframeExplorerWorkspaceView.swift
PASS
```

This proves Swift syntax only. Because the implementation is inside `#if os(macOS)` and depends on SwiftUI plus the real Conduit target, it does **not** prove macOS type checking or app integration.

A separate pure presentation/path prototype was exercised with eight deterministic checks for lifecycle-root ordering, breadcrumbs, ancestor expansion, and labels. That prototype was used as a design check only and was not added to ConduitCore, avoiding a new Core contract that would require duplicating authority already present in the qualified Explorer scanner.

## Intentionally not wired remotely

The GitHub connector can safely create new files but updates existing files only as whole-file replacements. `RootView.swift` is a large, actively evolved shell file. Replacing it wholesale from this environment would create an unnecessary stale-copy / collateral-change risk.

The local macOS reconciliation must therefore make the small existing-file edits required to:

1. add `explore` to `ConduitWorkspace` in `Sources/ConduitCore/OrchestrationPolicy.swift`;
2. route `.explore` in `RootView.workspaceColumn` to `MainframeExplorerWorkspaceView(root:)` before task/project fallthrough;
3. decide whether the existing task rail remains visible in Explorer v0 or is swapped for the Explorer tree after inspecting the live layout. The staged view is self-contained and already includes its own tree, so keeping the task rail is the smallest initial integration;
4. add the required `CHANGELOG.md` Unreleased entry in the same integration commit;
5. add focused tests/selftest coverage for `ConduitWorkspace.explore` and any new pure shell policy introduced during integration.

## Required macOS acceptance

Before merge, the local pass must establish at minimum:

- full `./scripts/test.sh` PASS;
- `./scripts/build-app.sh` PASS and strict codesign PASS;
- Explorer appears as a first-class workspace and does not remount or mutate an existing terminal session when switching workspaces;
- real MainFrame tree expands lazily and remains read-only;
- `.agents` / `.context` / `.github` remain visible when present and `.git` remains excluded;
- projects and operations show authoritative badges only when the lifecycle scanner validates them;
- UTF-8 files open read-only; binary/non-UTF-8/oversized/symlink cases show bounded errors instead of being followed or edited;
- Quick Open reports truncation honestly on the real MainFrame bound;
- back/forward, breadcrumbs, and reveal-in-tree work against real paths;
- installed bundle hash matches the tested build before the normal canary is used;
- existing Work/Conversation/Raw behavior remains unchanged.

No Explorer UI acceptance is claimed by this remote preflight.
