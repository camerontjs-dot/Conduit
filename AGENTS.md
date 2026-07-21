# Conduit agent contract

## Purpose

Conduit is a personal native macOS interface for operating MainFrame projects through existing CLI agents. Keep the app useful before making it clever.

## Non-negotiable boundaries

1. MainFrame files remain the source of truth. Do not introduce a shadow project database.
2. Do not wire private project names, paths, or corpora into the repository.
3. Capture operations create new files; never silently overwrite MainFrame history.
4. Agent CLIs remain independent tools. Conduit launches and communicates with them but does not impersonate their APIs.
5. Terminal work requires a real PTY. Do not replace SwiftTerm with a text-output imitation.
6. Attachments are referenced by local path. Never upload files without an explicit future feature and consent boundary.
7. Speech output enters the editable composer before submission.
8. Keep durable logic in `ConduitCore` and test it without AppKit where practical.

## Verification

Run:

```bash
swift test
./scripts/build-app.sh
```

macOS CI is required for merges touching terminal, speech, AppKit, or packaging code.
