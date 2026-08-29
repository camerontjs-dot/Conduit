# Conduit private repository migration receipt

Date: 2026-08-29
Repository: `camerontjs-dot/Conduit` (private)
Migration shape: dedicated reconciliation branch/PR

## Boundary

This repository contains the portable Conduit engineering object: Swift
application and library source, deterministic tests and fixtures, protocol and
schema definitions, adapter/MCP source, package/build files, reusable scripts,
developer documentation, resources, CI, and Git hooks. The outer MainFrame
coordination repository is not part of this repository.

The following remain local-only: outer `30_projects/conduit` coordination,
MainFrame `20_live` receipts, `~/.conduit` task/conversation/worklog/
bundle/attachment/auth/config state, installed application copies, `.build`,
`dist`, SwiftPM dependency checkouts, `.claude/settings.local.json`, secrets,
session caches, logs, sockets, and machine-specific runtime state. No live
credential or operator transcript is included.

## History and identity

The live GitHub default branch before migration was `25faee50cf4df9627eac0f02442d2960681c06f5`.
The old draft PR #1 head was `55ad069f78923c98811ea0346731d3d403165257`.
The current local product source before migration was `90282eebbf48d996d7580f9404cc6f7ef0aaf2f2`.
The local workbench history had been reset by the operator, so it shared no
common ancestor with GitHub. This reconciliation joins the two histories with
an ours merge, preserving both lines without rewriting either one.

## Verification

Baseline checks on the current product source:

* `./scripts/test.sh` passed: self-test `432 passed, 0 failed`; XCTest
  `273 tests, 0 failures`. Existing compiler warnings remain non-blocking.
* `./scripts/build-app.sh` passed and produced an ad-hoc code-signed app.
  The built binary SHA-256 was
  `6b0a719e850283c7e5480b9b72c72c401324aa6f5c820234686f2c52ee77fca5`.
* The strict leak scan found only synthetic path/redaction fixtures; the
  committed allowlist scopes those exact path-and-substring pairs.
* The public-surface lint found only intentional MainFrame contract references
  and synthetic path fixtures; the committed allowlist scopes those exact
  references.
* `git diff --check` was clean before publication.

Machine-bound checks not executed here include installed-app parity and GUI
relaunch/persistence, authenticated agent CLI and adapter acceptance, tmux
session lifecycle, MainFrame live-root and permission behavior, ChatGPT tunnel
or hosted MCP wiring, speech/microphone behavior, local Ollama planning, and
account-usage checks.

## Non-claims and next authority

This receipt does not claim production readiness, universal agent or adapter
support, complete MCP integration, reliable session recovery, cross-machine
portability, or general MainFrame reproducibility. Existing CI covers the
deterministic macOS build/test path only. GitHub branch-protection and ruleset
settings were not readable from the current account (API returned 403).

Review and CI for the reconciliation PR are the next authority. Merge, release,
and tag operations remain separately authorized. The old draft PR is preserved
for evidence and will be marked superseded only after the replacement PR exists.
