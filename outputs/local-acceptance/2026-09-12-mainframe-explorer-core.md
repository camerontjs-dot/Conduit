# MainFrame Explorer core verification

Date: 2026-09-12
Branch: `feat/mainframe-explorer-core-20260912`
Stacked base: `feat/mainframe-lifecycle-records-20260912` (PR #24)
Work class: standard engineering / Explorer foundation

## Objective

Verify the deterministic read-only Explorer core before any SwiftUI integration.

The tested source is the exact `Sources/ConduitCore/MainframeExplorer.swift` content committed on this branch, exercised in a minimal Swift 5.9 package with the focused Explorer test file adapted only for the temporary package module name.

## Environment

```text
Swift version 6.2.1 (swift-6.2.1-RELEASE)
Target: x86_64-unknown-linux-gnu
```

## Command

```text
swift test --disable-sandbox
```

## Result

```text
Test Suite 'MainframeExplorerTests' passed
Executed 10 tests, with 0 failures (0 unexpected)
Build complete
```

## Cases exercised

- root Explorer includes useful hidden MainFrame surfaces (`.agents`, `.context`, `.github`);
- `.git` and `.DS_Store` are excluded by default;
- lifecycle-zone classification is path-derived and deterministic;
- project/operation scope hints are path-derived and explicitly non-authoritative;
- outside-root directory traversal is rejected;
- symbolic links are visible as leaf nodes but never traversed;
- recursive Quick Open indexing never follows symlinks;
- bounded indexing reports `truncated` instead of claiming completeness;
- Quick Open ranking prioritizes exact/prefix/name matches before path-only/fuzzy matches;
- ordered-subsequence matching works for compact queries;
- UTF-8 text reading is bounded by byte limit;
- reader rejects symlink and outside-root files;
- back/forward history truncates stale forward history after a new branch.

## Authority boundary

This receipt is portable deterministic evidence only. It does not prove:

- compilation of the complete Conduit package on macOS;
- interaction with AppModel or SwiftUI;
- installed-app behavior;
- security-scoped bookmark behavior in the app sandbox/host environment;
- usability of the eventual Explorer tree/reader;
- performance against the user's populated MainFrame installation.

Those belong to the local Mac reconciliation and installed-app acceptance pass.

## GitHub Actions status

Private-repository macOS Actions are currently infrastructure-blocked before workflow steps execute. A GitHub CI failure with no assigned runner and no steps is therefore not counted as code evidence.
