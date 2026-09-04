# Local environment and deterministic baseline

Plan provenance: PR #5, `docs/LOCAL_ACCEPTANCE_AND_CONTROL_PLANE_TEST_PLAN.md`, blob `dcd1cfdc4f93aa6039585a4abfb48d2c8034e026`.

Contract context: draft PR #6, `docs/CONTROL_PLANE_CONTRACT_V1.md`, blob `11abf723410b875bbb3a33a962641fe03b43b0a9`.

## L0.1 — Repository state

Test ID: L0.1
Date/time: 2026-08-29T19:36:54-04:00
Conduit SHA: `2c0f27c0008cb2cf8873685f909b385651ab63c9`
Branch: `research/control-plane-local-acceptance-20260829`
Installed-app/build identity: not applicable
Machine/environment: macOS 26.5.2 (25F84), arm64
Provider/runtime: Git + GitHub API
Preconditions: nested product worktree was clean; outer MainFrame coordination repository was separately dirty and not touched.
Action: fetched `origin/main`, fast-forwarded the clean product worktree, and reran `bin/github-preflight`.
Expected: local product worktree derived from the current GitHub default-branch object.
Observed: starting local SHA `90282eebbf48d996d7580f9404cc6f7ef0aaf2f2` was 20 commits behind GitHub `main`; it fast-forwarded cleanly to `2c0f27c0008cb2cf8873685f909b385651ab63c9`. Preflight classification then became `SYNCED`.
Result: PASS
Evidence: `bin/github-preflight … --json`; `git rev-list --left-right --count HEAD...origin/main` returned `0 20` before the fast-forward.
Negative findings: outer coordination work is pre-existing and remains untouched. Product build/cache/app outputs are ignored and excluded from Git state.
Follow-up: retain the pinned SHA for every subsequent result.

## L0.2 — Deterministic suites

Test ID: L0.2
Date/time: 2026-08-29T19:37:41-04:00
Conduit SHA: `2c0f27c0008cb2cf8873685f909b385651ab63c9`
Branch: `research/control-plane-local-acceptance-20260829`
Installed-app/build identity: source build
Machine/environment: macOS 26.5.2 (25F84), arm64; Xcode 26.6 (17F113); Swift 6.3.3
Provider/runtime: `conduit-selftest` plus XCTest
Preconditions: Xcode was installed although the active developer directory was Command Line Tools; the repository script selected Xcode itself.
Action: `./scripts/test.sh` twice: baseline, then a full captured rerun for counts.
Expected: self-test and XCTest both execute through the script.
Observed: exit status 0; 432 `ok …` self-test assertions; final XCTest summary 273 tests and 0 failures. Output had 72 lines matching `warning:`, normalizing to three repeated messages with 24 matching lines each: two `ConversationCaptureMerge` unused-variable diagnostics and one `ConduitSafety` unused `withLock` result diagnostic.
Result: PASS
Evidence: `./scripts/test.sh`; output summarized with `rg -c '^ok '`, XCTest summaries, and normalized warning extraction.
Negative findings: the green suite does not remove the three compiler-warning classes.
Follow-up: do not use this result as provider, installed-app, or tunnel acceptance.

## L0.3 — Packaged app build

Test ID: L0.3
Date/time: 2026-08-29T19:38:14-04:00
Conduit SHA: `2c0f27c0008cb2cf8873685f909b385651ab63c9`
Branch: `research/control-plane-local-acceptance-20260829`
Installed-app/build identity: `dist/Conduit.app`; bundle identifier `dev.camerontjs.conduit`; ad-hoc signed arm64 bundle
Machine/environment: macOS 26.5.2 (25F84), arm64; Xcode 26.6 (17F113)
Provider/runtime: release Swift build
Preconditions: L0.2 completed at the same SHA.
Action: `./scripts/build-app.sh`, then absolute-path signature verification and executable SHA-256 calculation.
Expected: release bundle builds and verifies its signature.
Observed: build exit status 0; signature verification passed. Executable SHA-256: `7e1630960e1f0b2f5295fff90d1d21f39e506ca4c737f7df787f382369157aee`.
Result: PASS
Evidence: `./scripts/build-app.sh`; `codesign --verify --deep --strict --verbose=4`; `shasum -a 256 dist/Conduit.app/Contents/MacOS/Conduit`.
Negative findings: this establishes build/package integrity only, not installed-app permission, provider, persistence, or runtime-hosting behavior.
Follow-up: use this exact bundle for machine-bound tests.
