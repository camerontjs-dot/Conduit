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
swift run conduit-selftest   # always (works with Command Line Tools only)
swift test                   # when full Xcode is available
./scripts/build-app.sh
```

Keep `Sources/ConduitSelfTest` and `Tests/ConduitCoreTests` in step when core behavior changes.

macOS CI is required for merges touching terminal, speech, AppKit, or packaging code.

## Session closeout

Before ending a multi-step product session:

1. `CHANGELOG.md` updated (or explicitly N/A for docs-only).  
2. Outer `../log.md` entry if coordination state moved.  
3. Handoff under `../plans/YYYY-MM-DD-session-handoff.md` (or update the latest active handoff).
