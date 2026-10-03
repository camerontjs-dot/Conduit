# Conduit agent contract

## Purpose

Conduit is a personal native macOS interface for operating MainFrame projects through existing CLI agents. Keep the app useful before making it clever.

> **Binds:** agents working in this Conduit repository.
> **Tier:** T0, advisory repository instructions.
> **Check:** none; this document does not enforce task authorization, source custody or qualification. Test, CI and machine receipts establish their separate evidence.
> **Escape:** when an applicable check or authority is unavailable, record the exact NOT_RUN/BLOCKED prerequisite in the owning issue or PR and continue independent authorized work. Explicit session authority and applicable host contracts govern actions outside this repository.

## Non-negotiable boundaries

1. MainFrame files remain the source of truth. Do not introduce a shadow project database.
2. Do not wire private project names, paths, or corpora into the repository.
3. Capture operations create new files; never silently overwrite MainFrame history.
4. Agent CLIs remain independent tools. Conduit launches and communicates with them but does not impersonate their APIs. Codex uses `codex app-server` (D-038). Grok, OpenCode, Claude, Antigravity, and Gemini CLI use their first-party structured hosts (D-040) with PTY fallback. Shell stays PTY. Gemini CLI ACP needs an API key; do not pair it with Antigravity on the same task.
5. Terminal work that still lives in a TUI requires a real PTY. Do not replace SwiftTerm with a text-output imitation. Codex Raw may attach to the same app-server instead of scraping a TUI.
6. Attachments are referenced by local path. Never upload files without an explicit future feature and consent boundary.
7. Speech output enters the editable composer before submission.
8. Keep durable logic in `ConduitCore` and test it without AppKit where practical.

## Changelog (required)

Product history lives in **`CHANGELOG.md`** (Keep a Changelog style).

- Update **`CHANGELOG.md` in the same commit** as any user-visible product change (UI, behavior, Settings, packaging).
- Prefer editing **`## [Unreleased]`** during a session; cut a dated section when shipping a coherent pass.
- Record architecture boundary changes in **`DECISIONS.md`** as well when the contract changes.
- Do not put private MainFrame project inventories or host-only smoke paths in the changelog.

## Verification

Select the repository checks that apply to the change:

```bash
./scripts/test.sh            # selftest, repository contracts and XCTest; resolves Xcode
./scripts/build-app.sh
```

Record the exact source/build identity, commands actually executed, results,
skips, first failures and remaining UNKNOWNs. Documentation-only validation
may consist of source/reference, diff and leak checks; name native or machine
checks that were not run rather than imply they passed.

Installed-app verification is a separate machine experiment:

```bash
./scripts/verify-installed.sh
```

Run it only when that exact installed app, state, listener, tasks and provider
activity are covered by the session's explicit qualification authority. A
source test or package build does not authorize installation, replacement of
an operator app, use of unrelated sessions or a write-gate change.

`scripts/test.sh` proves ConduitCore logic. It cannot prove the installed
bundle drives a real runtime: the Session API, the adapters, and the PTY all
sit outside the deterministic suite. Every defect found on 2026-09-04 — a
duplicate objective delivery, an intermittent PTY observation gap, a provider
error reported as a completed turn — passed 291 tests and failed on the first
live run.

`verify-installed.sh` refuses to run when the installed bundle is not the build
you just made, then runs the canary several times, because a single green run
hides intermittent defects. It needs the operator's Session API write gate;
that switch is never flipped for you.

`scripts/test.sh` runs `conduit-selftest`, the repository's Python contract
checks and then `swift test`. Pass through
args work, so `./scripts/test.sh --filter MCPAdmissionTests` narrows the XCTest
run.

`scripts/probe-provider-resume.py` checks a premise neither suite can reach:
D-047 reports a refused resume as `restarted`, which is only correct while
providers actually refuse an id they no longer own. The probe asks them
directly, outside Conduit — read-only, no task, no write gate. Re-run it when a
provider updates; if one starts answering an unknown id with a session, the
client would report continuity it does not have.

Background, so this is not misdiagnosed again: `swift test` needs XCTest, which
ships inside Xcode.app and **not** with the Command Line Tools. If
`xcode-select -p` points at `/Library/Developer/CommandLineTools`, a bare
`swift test` fails with `no such module 'XCTest'`. That is toolchain selection,
not a missing dependency, and `scripts/test.sh` resolves it the same way
`build-app.sh` already did. It only reports XCTest as unavailable when there is
genuinely no Xcode at the developer directory.

Keep `Sources/ConduitSelfTest` and `Tests/ConduitCoreTests` in step when core behavior changes.

macOS CI is required for merges touching terminal, speech, AppKit, or packaging code.

## Session closeout

Before ending a multi-step product session:

1. Update `CHANGELOG.md`, or record an explicit N/A for documentation-only work.
2. Reconcile the owning GitHub issue or PR with exact base/head/tree, changes,
   executed checks, negative evidence, remaining prerequisites and disposition.
3. Keep substantial reusable qualification records under
   `docs/qualification/` when suitable for repository publication. Private
   machine receipts stay in the separately authorized local evidence location;
   the owning issue or PR carries their bounded claims and receipt identities.

This portable checkout does not require a sibling `../log.md` or `../plans/`
and gives no authority to create or edit them. When a host workspace separately
requires coordination, follow its applicable contract and actual project paths
under the session's authorization. Do not infer those paths from this clone's
parent directory.
