# Conversation-first UI foundation — local macOS acceptance

Status: `CONDITIONAL PASS` for the bounded PR #37 slice on the exact head
qualified below. Deterministic, installed-app, control-plane, and measured
pipeline evidence is green; GUI-press verification that needs a trusted
accessibility client or operator hands is explicitly listed as remaining.

This receipt records local evidence only. It contains aggregate observations;
no private MainFrame inventory, project names, corpus material, or host paths
beyond the qualification fixture are recorded.

## Identity

- Repository: `camerontjs-dot/Conduit`
- Pull request: `#37` (Draft, Open) — Conversation-first UI foundation
- Feature branch: `feature/conversation-first-ui-20260916`
- Expected candidate at handoff: `ed45b5ef74939dbf294b4037c7fefbd612618e45`
- Actual PR head at preflight fetch: `ed45b5e` — **matches** (`origin/pr-37`
  == `origin/feature/conversation-first-ui-20260916` == `ed45b5e`)
- PR merge-base with `main`: `2407c70` (merged PR #26). Note: `origin/main`
  moved to `a8d75d5` during this pass; the candidate was qualified
  against its own head, not re-based.
- Local qualification branch: `feature/conversation-first-ui-20260916`
  (tracking the PR branch; workbench was detached at `a1cb139` on arrival
  and is now on the PR branch — see outer log)
- Qualification changes (2 minimal fix commits on the PR branch):
  - `4a51c2c` fix(conversation): preserve fenced code blocks in
    workstation display projection
  - `525b2e7` fix(conversation): compile display-text regexes once for
    streaming scrub
- Exact head qualified: `525b2e7be118a38ac3491601fe99caa022a4207f`
- Exact tree qualified: `9e25d557fca8f76d9ce4a95965c3731027aab01b`
- Tracked workbench tree at commit: clean (only untracked
  `outputs/local-acceptance/canary/*` receipts alongside).

## Toolchain

- macOS: `26.5.2` (`25F84`), arm64
- Xcode: `26.6` (`17F113`); Swift `6.3.3` (`swift-driver 1.148.6`)
- `xcode-select -p` points at Command Line Tools; both repo scripts resolve
  the Xcode developer directory explicitly (pre-existing arrangement).

## Deterministic suite

- `./scripts/test.sh` on the exact head: `PASS`
  - `conduit-selftest`: `443 passed, 0 failed`
  - XCTest: `449 passed, 0 failed`
- Initial run on `ed45b5e` was `448/449`: one real defect in the
  candidate's own new coverage —
  `ConversationTranscriptTests.testMarkdownRendersReadableRoleLabeledThread`.
  `workstationDerived` classified a lone ` ``` ` fence as decorative chrome
  and reflowed code lines into prose, exporting
  `"```swift let answer = 42"` for a fenced block. Fixed in `4a51c2c`
  (fenced regions pass through the projection verbatim); suite re-ran green.
- Full suite re-ran green after `525b2e7` as well (same `443`/`449`).

## Compile, build, signing, install

- `./scripts/build-app.sh` on the exact head: `PASS` (incl.
  `codesign --verify --deep --strict` inside the script).
- Built executable SHA-256:
  `df3d84f01d05fd1e8521c246a5fd6eab9edb9e85995a8262d094b5bffbc71f1d`
- Installed to `/Applications/Conduit.app` after backing the previous
  install up to `/tmp/conduit-install-backup.20260917-pr37`; post-install
  `codesign --verify --deep --strict`: `PASS`.
- Built/installed hash equality verified (`df3d84f0…` both).
- An earlier install of the pre-fix head (`4a51c2c`,
  `243e0fc0f0988c0bf9265575009daa22c2fc65c832a00acf975cf4ce3c50e887`)
  was exercised first, then replaced by the exact-head build above.
- The operator-owned Session API write gate was observed enabled and was
  not changed. No Conduit crash reports appeared during the pass.

## PTY smoke and runtime continuity (installed app)

- `./scripts/canary-control-plane.py --run --repeat 3 --agent Shell`
  against the pre-fix install: 3 attempts × 9 lanes, `0 FAIL`.
- `--repeat 1 --agent Shell` against the exact-head install: 9 lanes,
  `0 FAIL` (receipt `2026-09-17T050315Z-canary-6a53a679.md`).
- Lanes cover create / ready / objective-delivery semantics / cursor
  revision / interrupt request-vs-observation / visibility /
  false-completion / detach (`close_outcome: detached`, recoverable) /
  same-task reconnect.
- Conversation↔Raw continuity: by construction both surfaces observe one
  `TerminalRuntime`; Raw stays mounted under Conversation (opacity-only
  switch, no teardown) and switching only flips `selectedSurface` plus a
  capture resync (`Sources/Conduit/SessionSurface.swift`). Switch controls
  exist in both directions and mutate nothing else. Runtime identity
  stability is corroborated by the L4.2/L4.3 detach/reconnect lanes (same
  task id recovered, no restart). The physical toggle press in the
  installed GUI was not driven headlessly (see Limitations).

## Structured OpenCode smoke (installed app)

- `./scripts/canary-control-plane.py --run --repeat 1 --agent OpenCode`:
  9 lanes, `0 FAIL` (receipt
  `2026-09-17T045440Z-canary-989ed367.md`). Task created on the
  `http-server` backend, reached ready, streamed provider-authored events
  with in-place revision (`revised_in_place=1`), interrupt recorded as
  request (not cancellation), close stopped the structured host
  (`recoverable=false`, expected for this backend).
- Dedicated tool-use probe: an OpenCode task (`5F40D262…`) was asked to
  read `/tmp/conduit-pr37-fixture/notes.txt` (read-only, fixture outside
  every repo). Turn completed; provider ground truth in
  `~/.local/share/opencode/opencode.db` shows session `ses_f5247d35…`
  with a real `tool` part (`tool=read`,
  `filePath=/tmp/conduit-pr37-fixture/notes.txt`, `status=completed`).
  Conduit's `session_events` surface for the task shows the linked
  `agent_output` turns with `extraction=structuredAdapter` and honest
  `turn.state=completed` ("reported turn completion. Not verified
  success."). The tool part's full output embeds source file bytes —
  live confirmation that the PR's decision to withhold successful tool
  output from activity cards (identity/status only) protects real
  content, not a hypothetical.
- Authority boundary (unit-verified, all green):
  `OpenCodeConversationActivityTests` covers provider identity/status
  mapping, no output retention on success, bounded error detail on
  failure, exact patch file lists, foreign-session rejection,
  session-less rejection, and text/reasoning parts never becoming
  activities. The extractor additionally requires the
  `message.part.updated` envelope and an exact bound session id.
- Rendering of the admitted activity card in the installed GUI was not
  driven headlessly (see Limitations). The live SSE→`conversationActivities`
  path was reviewed: per-turn reset on `sendTurn`, upsert by part id,
  provider-status-only labelling in the view
  ("Provider-reported status · not independent verification").
- The probe task's completed turn survived reinstall/relaunch as retained
  history (`thread_id_source: persisted`), consistent with the PR's stated
  limitation that typed activity snapshots are live-only.

## Copy / export / retained-log reveal

- Deterministic cores are unit-covered (`ConversationTranscriptTests`,
  incl. the fence case fixed here) and the full suite is green.
- Write audit of `Sources/Conduit/ConversationTranscriptActions.swift`:
  `copy` touches only the pasteboard; `revealLog` selects the retained
  JSONL in Finder (fail-closed `logMissing` when absent); the file's only
  `write(to:)` targets the operator-chosen `NSSavePanel` URL; empty
  transcripts throw instead of writing. Nothing in the copy/export path
  writes to `~/.conduit/conversations`.
- Live durability: the probe task's JSONL is append-only envelope lines
  (`schemaVersion`, `taskSessionID`, `recordedAt`, `event`) capturing the
  live→closed revision progression with extraction provenance and prompt
  linkage; file hashes are stable across control-plane reads.
- Copy turn defers serialization to press time via autoclosure (matches
  head commit `ed45b5e`); the transcript menu (Copy transcript / Export /
  Reveal) is wired in the live thread, the historical thread view, and
  the session surface.
- Assistant rendering is one selectable `Text` node per turn
  (`ConversationSelectableDocument`, plus the cached variant), removing
  the previous per-block selection boundary; whole-turn copy still uses
  the Markdown projection so fences survive. The fixed projection output
  parses as a Markdown `AttributedString` (`parsedNil=false` in probes).
- Assistant text selection feel, button presses, save-panel completion,
  and Finder reveal were not driven headlessly (see Limitations).

## OpenCode activity → Source Workbench

- `resolvableFile` admits only exact paths contained by the task's project
  scope (standardized URLs, prefix check) and the workbench performs its
  own containment check on load; out-of-scope paths render without the
  Workbench button (still shown and copyable). The probe's `/tmp` tool
  path therefore correctly would not offer a jump.
- A positive in-project jump was not exercised live (would require the
  model to touch project files; the probe was filesystem-inert by
  design). `MainframeSourceWorkbenchTests` and
  `OpenCodeConversationActivityTests.testPatchActivityPreservesExactProviderFileList`
  are green.

## Streaming performance (measured, real engine)

Method: temporary `PR37PerfProbeTests` (removed after the run) driving the
shipped `ConversationTranscript` / `ConversationDisplayText` /
`TerminalMenuParser` code with mixed-Markdown turns (headings, lists,
fenced code). macOS timings on this machine, `swift test` release-adjacent
reset between cases; representative figures:

| Workload | Result |
| --- | --- |
| Whole-thread serialization, 25 turns / 50 events | `3.8 ms` |
| Whole-thread serialization, 100 turns / 200 events | `15.8 ms` |
| Whole-thread serialization, 250 turns / 500 events | `39.0 ms` (linear) |
| Closed-turn single-pass derivation (cached path) | `~1.5 ms` |
| Typical live-turn scrub, ~2.6 KB / ~10.7 KB | `1.2 ms` / `4.8 ms` |
| Long streaming response, 64 incremental revisions to ~135 KB | mean `34.6 ms`, p95 `64.8 ms`, max `67.4 ms` per revision |
| Same ~135 KB doc: plain live render vs full Markdown parse | `4.6 ms` vs `42.5 ms` (parse avoided per revision by `29a2c17`) |
| Menu-option parse on the ~135 KB doc (runs per revision) | `~8 ms` |

What this establishes:

- The original lag mechanisms are reduced, not merely re-architected:
  closed turns derive once and are cached (no repeated scrub + Markdown
  parse per view evaluation); the live turn renders as plain attributed
  text (the `~42 ms` Markdown parse per revision at 135 KB no longer
  runs); whole-thread serialization is deferred to explicit Copy/press
  (`ed45b5e`) and costs milliseconds linearly; follow-latest scrolling is
  coalesced to at most one scroll per 75 ms burst.
- Residual: per-revision work re-scrubs the full live text, so cost grows
  linearly with response length (O(n²) per response with a smaller
  constant). Typical turns stay in single-digit ms; a sustained ~135 KB
  single response can exceed a frame budget per burst. `525b2e7`
  (compile-once regexes, same patterns/results) cut the measured mean
  `43.6 ms → 34.6 ms` (~20%). Further incremental-scrub work would be a
  redesign and was deliberately not attempted here.
- Not established: GUI frame rates, Instruments traces, composer-typing
  feel, and scroll smoothness while streaming (see Limitations). No
  before/after GUI A/B exists; the "material improvement" claim rests on
  removed per-revision parse work measured above, not on observed frames.

## Inspector / sidebar / workspace

- Chrome changes reviewed: permanent Conversation/Raw segmented picker
  removed in favor of per-surface compact switch-backs; Inspector
  overlay/pin and density geometry covered by green
  `WorkbenchChromeTests` (7) and `WorkspaceGeometryTests` (11).
- Installed-app interaction feel (nav collapse preference persistence,
  Inspector open/close while streaming) was not driven headlessly; the PR
  body itself flags the collapse-preference UX check as remaining.

## Failures, limitations, untested areas

1. Fixed during this pass: fenced-code destruction in copy/export
   (`4a51c2c`); per-line regex recompilation hotspot (`525b2e7`).
2. No GUI-press evidence: this harness is not a trusted accessibility
   client (`AXIsProcessTrusted()=false`), so no AX tree, button presses,
   save-panel completion, Finder-reveal observation, or selection-drag
   verification was possible. A purpose-built AX probe was compiled and
   confirmed blind (`Build-OK`, empty tree). These steps need an
   operator-driven or Computer-Use pass: Conversation↔Raw toggle feel,
   Copy turn/transcript pasteboard check, export completion, log reveal,
   activity-card render/expand, Workbench jump, Inspector/sidebar feel,
   composer typing while streaming.
3. No Instruments / SwiftUI-invalidation traces; performance verdict is
   pipeline timings plus removed-work accounting, not frame observation.
4. VoiceOver was not run.
5. Hosted Actions unavailable (quota); CI status is neither pass nor
   failure. Local macOS evidence is the basis, per the task brief.
6. Positive in-project Workbench jump untested live (probe was
   filesystem-inert by canary discipline).
7. Live SSE activity for a foreign/second session on the shared
   `opencode serve` lease was not staged; isolation rests on unit tests
   plus the exact-match extractor design.
8. Shell-canary `L3.7`/`OBS-2` "ambiguous" notes are the canary's own
   provider-boundary honesty labels (quiet PTY output), not PR #37
   findings; receipts retain them unmodified.

## Verdict

The exact head `525b2e7` compiles, passes the full deterministic suite
(`443` selftest + `449` XCTest), installs and launches with verified
executable identity, preserves PTY and structured OpenCode runtimes with
honest provider boundaries, keeps the retained JSONL durable and
untouched by copy/export, and shows measured, linear, materially reduced
per-revision streaming work with two real defects found and fixed.

The remaining gap is GUI-press and frame-observation evidence, which this
headless pass could not produce by construction. If the project's bar for
leaving Draft is "exact-head deterministic + installed + control-plane +
measured-pipeline evidence", that bar is met. If the bar additionally
requires operator hands on the new Conversation chrome (toggle feel,
copy/export presses, activity-card render, collapse preference), those
checks are sharply scoped above and should gate the Draft→ready flip.
