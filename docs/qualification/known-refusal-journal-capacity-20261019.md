# Known-refusal journal capacity repair — implementation evidence

2026-10-19. Local, uncommitted implementation; no independent review claim.
Owning review: #178, whose source-review FAIL remains frozen at
`7092224ec8af0755ecb99191460ae8d45546240d` (the session-supplied baseline;
GitHub was not accessed). Branch:
`repair/known-refusal-journal-capacity-20261019`.
Base and unchanged HEAD: `7092224ec8af0755ecb99191460ae8d45546240d`.
Base tree: `87032f06a71eb1a0258048e0335a3293f6a5216d`.
Original reviewed source is retained in Git and a local archive, SHA-256
`143ff906f860639d37893c756fd670241f791a0f0a3688828b38f1eb7508eed6`.
Earlier qualification records and their negative review hashes are unchanged.

## Change and safety argument

The journal now has a synchronous admission overload. It validates identity,
keys, location, owner, every receipt, replay/conflict and capacity before invoking
admission. Its nonescaping `beginDispatch` checkpoint creates and synchronizes
intent exactly once. AppModel propagates that checkpoint only to keyed create
and send; unkeyed behavior is unchanged. Existing conservative action callers
still receive an intent before any action.

Create preconditions and `admitCreate` precede the checkpoint, with the exact
reservation cancellation defer already installed. The checkpoint precedes
`createTask`, including its first possible work-log append and runtime/task
registration. Send validates text, task and live runtime, then `admitPrompt`;
its reservation release defer precedes the checkpoint, which precedes
`sessionAPIDeliver` and that method's first acceptance marker, `recordPrompt`.
Resource sampling uses read-only sensors; admission changes only in-memory
budget/reservations. These synchronous paths do not suspend or launch deferred
work before the checkpoint. Authentication, readiness, write gating, caller,
resource, queue and rate ordering remain in place.

No checkpoint means no durable intent and a `not_dispatched` result. No error
string or absent task ID establishes this classification. After the checkpoint,
unknown/error/partial results retain intent; valid queued acceptance retains its
original task/event IDs. Completed replay and conflicts cannot spend admission.
Invalid stores are refused before admission. Existing ownership, no-follow,
link/mode checks and fsync requirements remain unchanged.

Crash before intent: no dispatch was authorized. Crash during/after intent:
retained or partial intent fails closed on reconstruction. Crash after refusal:
there was no receipt to remove. A removal-crash test is therefore N/A, not a
claim that deletion is atomic. Reconstruction fixtures model durable boundaries;
physical power-loss testing was NOT_RUN. File/directory sync failures forbid
dispatch and release the exact create reservation; prompt release is installed
at the same checkpoint boundary. Spent rate budget is not refunded. Previously
retained UNKNOWN receipts, including old refusals without proof, are not pruned.

## Tests and local evidence

Local logs and exit sidecars are preserved under `.build/capacity-evidence/`;
`SHA256SUMS` identifies them, and `candidate.patch` captures the final diff.
The initial original binary was compiled with the new RED test before production
edits; its slow execution continued while the implementation was edited. The
RED source is reconstructed alongside the archived original source. Thus this
is baseline-binary RED evidence, not a claim that editing waited for RED exit.

| Log | Exit | Result |
| --- | ---: | --- |
| `first-red.log` | 1 | Setup failure: copied manifest was read-only; SwiftPM fell back to root dependency resolution, whose HTTPS transport was disabled. No dependency fetched. |
| `red.log` | 1 | Original source: 2,048 of 2,049 denied actions ran, 2,048 intents retained; both assertions failed. |
| `python-first.log` | 1 | 29 checks, 2 failures from AppModel evidence hash drift. Only that source hash was refreshed; no provider claims changed. |
| `focused-first.log` | 0 | 20 journal and in-process HTTP/MCP tests passed (13 Core, 7 transport). |
| `python.log` | 0 | All 29 Python source checks passed. |
| `full.log` | 1 | SelfTest and Python passed; 752 native tests, 3 skipped, 13 failures. Eleven were fixture path artifacts from symlinked Sources; two were socket EPERM and its unwaited expectation. |
| `full-physical.log` | 1 | Physical byte-identical source copies: 559 SelfTest checks and 29 Python checks passed. 752 native tests, 3 skipped; only socket bind EPERM and resulting unwaited expectation failed. |
| `release.log` | 0 | Offline unsigned release compilation passed; no explicit signing or packaging script invoked. |

RED log SHA-256:
`64cb65f4200ba3bbbca58f1769c1d33020379e1eacefa389963508c1d2dac5b2`.
Final full-suite log SHA-256:
`623c12cee15a3380c366f6720339e7ab7bfd7efd1186a23768f300a5a5d8335e`.
Focused log SHA-256:
`fed445d8ffcfdb37d71c6e6bc2c3ace6a750afc74de91488fc7233c4181d7eb2`.

New coverage exercises 2,049 distinct denied keys, 2,049 real rate refusals,
missing initialize and unknown resources through transport, healthy accepted
queued work after refusals, exact replay without further admission, conflict,
identical error text before/after checkpoint, reconstruction and both intent
file/directory sync failures. Existing corruption, symlink/mode, capacity,
outcome-sync, concurrent replay and UNKNOWN tests remain intact. Python adds
checkpoint/cleanup/first-effect ordering assertions; no assertion was weakened.

## Offline reproduction and limits

All build/cache/fixture changes stay inside this checkout. Disposable package:
`.build/offline`. SwiftTerm source is from pinned local checkout
`58915b1010d7dbc86d0e79dc2c40f0c183ccaf5b`; argument-parser checkout:
`6a52f3251125d74daf04fcbd5e6f08a75d074382`.
Only disposable manifests use local dependency paths and omit SwiftTerm's unused
DocC dependency. Repository manifests, lockfile and original checkouts are
unchanged. Sources/Tests were initially symlinked, then physically copied to
avoid URL-relative-path artifacts. Final copied source bytes are verified.

Commands use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`,
`CLANG_MODULE_CACHE_PATH=$PWD/.build/cache/clang` and
`SWIFTPM_MODULECACHE_OVERRIDE=$PWD/.build/cache/swift`:

```sh
swift test --package-path .build/offline --disable-sandbox --skip-update \
  --cache-path "$PWD/.build/cache" \
  --filter SessionAPIReplayJournalTests/testDistinctKnownRefusalsDoNotExhaustCapacity
swift test --package-path .build/offline --disable-sandbox --skip-update \
  --cache-path "$PWD/.build/cache" --filter SessionAPIReplay
python3 -m unittest discover -s Tests -p 'test_*.py'
PATH="$PWD/.build/offline-bin:$PATH" ./scripts/test.sh
swift build --package-path .build/offline --disable-sandbox --skip-update \
  --cache-path "$PWD/.build/cache" -c release
git diff --check
```

The local `offline-bin/swift` wrapper routes script invocations to Xcode Swift
with the same package/cache flags. The full suite is **not green**: local socket
bind is denied by the sandbox, and assertions remain unchanged. The three skips
are installed OpenCode authority, installed OpenCode persistence and live shell
OpenCode correlation, all requiring separately authorized fixtures.

NOT_RUN: installed app verification, provider resume/live delivery, real
MainFrame mutations, mounted UI qualification, power-loss experiments, signing,
installation, release, macOS CI, permission/host/tunnel/App restarts, GitHub
reconciliation and independent review. `scripts/build-app.sh` is not run because
it explicitly signs; release compilation is used instead. No commit, push,
merge, plugin mutation or permanent host change was performed. The local record
substitutes for issue/PR updates because this session explicitly forbids GitHub.
