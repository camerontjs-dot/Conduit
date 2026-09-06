# Conduit agent contract

## Purpose

Conduit is a personal native macOS interface for operating MainFrame projects through existing CLI agents. Keep the app useful before making it clever.

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

Run:

```bash
./scripts/test.sh            # both suites; resolves the Xcode toolchain itself
./scripts/build-app.sh
./scripts/verify-installed.sh  # after installing: live canary against the real app
```

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

`scripts/test.sh` runs `conduit-selftest` and then `swift test`. Pass through
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

1. `CHANGELOG.md` updated (or explicitly N/A for docs-only).  
2. Outer `../log.md` entry if coordination state moved.  
3. Handoff under `../plans/YYYY-MM-DD-session-handoff.md` (or update the latest active handoff).
