# MainFrame lifecycle compatibility verification

Date: 2026-09-12
Branch: `feat/mainframe-lifecycle-records-20260912`
Public MainFrame compatibility reference: `camerontjs-dot/MainFrame@200a95e847e7f69a35c9e4d9d3f5a9e48c02f508`

## Scope

This receipt covers the new standalone `ConduitCore` lifecycle compatibility layer only:

- `Sources/ConduitCore/MainframeLifecycle.swift`
- `Tests/ConduitCoreTests/MainframeLifecycleTests.swift`

It does not establish installed-app, AppKit, task/runtime, Explorer UI, or private MainFrame smoke behavior.

## Verification environment

The new source and focused tests were copied into a minimal temporary Swift package with the same `ConduitCore` / `ConduitCoreTests` target names and compiled independently with:

```text
Swift version 6.2.1 (swift-6.2.1-RELEASE)
Target: x86_64-unknown-linux-gnu
```

Command:

```bash
swift test --package-path /tmp/conduit-lifecycle-check
```

Result:

```text
Test Suite 'MainframeLifecycleScannerTests' passed
Executed 9 tests, with 0 failures (0 unexpected)
Build complete
```

Covered cases:

1. legacy project README without `record_type` resolves as a project;
2. operation README with `record_type: operation` resolves as an operation;
3. missing `40_operations/` is tolerated;
4. operation missing explicit `record_type: operation` is invalid;
5. duplicate slug across `30_projects/` and `40_operations/` fails closed;
6. missing README authority is invalid;
7. conflicting `project_state` and `lifecycle_state` is invalid;
8. `PROJECT.md` coordination state can own state while disagreement remains visible as an issue;
9. malformed nested frontmatter is rejected and expected record type can be enforced.

## GitHub Actions status

The immediately preceding docs-only PR #23 triggered CI run `34711607794`, but GitHub created no executable steps and assigned no runner (`runner_id: 0`, empty runner name). That failure is therefore not evidence of a code/test failure.

The implementation PR should still request normal macOS CI. Until a runner actually executes the workflow, repository CI remains **UNKNOWN / infrastructure-blocked**, not PASS.

## Authority boundary

The new scanner is additive and is not yet wired into `AppModel` or the current task rail. Existing `MainframeProject` behavior remains unchanged. This slice creates a typed project/operation authority surface for the upcoming read-only Explorer without making the current runtime flows depend on it.
