# PR #175 separate repair successor: source implementation record

Date: 2026-10-19. Disposition: uncommitted implementation for managing-engineer
review; not merge, release, installed qualification, or independent review.

Branch: `repair/api-replay-authority-20261019`.
Base and unchanged live HEAD: `2958b285310a3f882deeffe3ea36a9786661a6fe`.
HEAD tree: `68b31a9ba3f86f325f18c6d9ecb7e1392f13e249`.
Working-source tree before adding this record:
`c9a078e00178400797ac7d0025daccf0819303bb` (Git-compatible tree SHA-1 computed
from tracked and nonignored new files without staging or writing Git objects).
The final handoff reports the tree including this record separately to avoid a
self-referential digest. HEAD alone does not identify the uncommitted candidate.

## Implemented boundary

- `SessionAPIReplayJournal` reserves synchronized intent before the action that
  performs admission/dispatch. Caller + exact operation + exact key select the
  receipt; framed canonical fields bind the fingerprint. Create also binds the
  project path. Completed replay returns the original acceptance snapshot and
  task/event UUID without entering admission or dispatch. The controller itself
  remains intentionally nonpersistent; the original external red test was not
  opened, edited, or claimed repaired in isolation.
- Private app-state receipts use directory/file descriptors, no-follow traversal,
  owner/mode/link checks, a lifetime owner lock, and a mutex. Checksummed outcomes
  require matching intent, reservation, identity, fingerprint and schema. Missing,
  corrupt, oversized, orphan or unsafe receipts fail closed. Capacity is bounded
  at 2,048 intents; uncertain intent is never pruned. Stored outcomes whitelist
  identities and acceptance states, redact errors/warnings and omit raw text.
- AppModel consults the journal before admission. Original writes still pass
  existing policy/resource admission. Optional prompt keys parse exactly; create
  keys retain their exact bytes and malformed/conflicting aliases refuse.
  Unkeyed create/prompt requests remain non-idempotent.
- Send refuses before admission when no runtime is live; it cannot call reconnect
  or queue a history-load continuation. Explicit reconcile remains available.
- Only ancillary work-log append failure enters `ancillary_warnings` (desktop
  uses status feedback). Authoritative errors retain the existing API error sink.
  Prompt acceptance returns event UUID; create also returns objective event UUID.
- Updated both tool catalogs, CHANGELOG Unreleased, D-063, SelfTest, Core XCTest,
  transport fixtures and source contracts. The prior reconnect assertion was
  replaced with an explicit no-reconnect assertion. The provider-conformance
  AppModel artifact hash was refreshed after inspecting the unchanged OpenCode
  inventory/adoption guard; no provider observation was refreshed or inferred.

## Verification and reproducibility

No Internet or providers were used. Dependency checkouts and repositories were
copied from existing local caches into `.build`; Package.resolved was unchanged.
Xcode was selected only through `DEVELOPER_DIR`, with compiler/package caches in
this checkout. A disposable `.build/offline-bin/swift` wrapper selects Xcode's
Swift and adds `--disable-sandbox --skip-update --cache-path "$PWD/.build/local-cache"`
to each SwiftPM subcommand. It does not modify the host toolchain or settings.

Commands (cache environment variables point to `.build/local-cache/clang` and
`.build/local-cache/swift`; the full-suite command also prepends the wrapper to PATH):

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --disable-sandbox --skip-update --cache-path "$PWD/.build/local-cache" \
  --filter SessionAPIReplay
./scripts/test.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release \
  --product Conduit --disable-sandbox --skip-update \
  --cache-path "$PWD/.build/local-cache"
git diff --check
```

- Focused final XCTest: **11 tests, 0 failures, exit 0** (9 Core + 2 HTTP/MCP
  transport fixtures), including stronger decoded-receipt privacy assertions.
- Full suite: **553 SelfTest checks, 0 failures; 26 Python contracts, 0 failures;
  741 XCTest tests, 3 skips, 2 failures, exit 1**. The failures are both in
  `testPrivateZshHooksAuthenticatePeerAndRejectForgedOrOutOfOrderFrames`:
  `posix("bind", 1)` at ShellTelemetrySocketServer.swift:74, then an unwaited
  `validated shell events` expectation at the test's line 22. This environment
  refuses socket binding; no permission change or assertion weakening attempted.
- The three skips require separately authorized installed OpenCode authority,
  installed OpenCode persistence, and isolated live shell/OpenCode fixtures.
- Release product build: **exit 0**. Bundle contents were staged using the build
  script's copy layout at `.build/unsigned-package/Conduit.app`, without codesign,
  launch, or install. `scripts/build-app.sh` itself was **NOT_RUN** because it
  invokes codesign. Staging and `git diff --check`: **exit 0**.
- Release executable SHA-256:
  `1592007b7107e87634e5504a929e5051555fc3c2cbd8b0267d1fb5364ef9b9b8`.
  Complete staged file hashes: `.build/receipts/unsigned-bundle-sha256.json`.

## Negative evidence retained locally

Raw logs remain in the authorized worktree's ignored `.build/receipts/` directory:

- `first-targeted.log`: exit 1, compilation failed because caller identity was
  optional while the initial journal signature required a String. Fixed by
  accepting optional identity and refusing an unidentified caller before intent.
- `targeted-2.log`: 9 tests, 8 initialization failures, exit 1. `diagnostic.log`
  isolated no-follow traversal rejecting the fixture's `/var` symlink (ENOTDIR).
  Fixtures moved into private worktree scratch directories; storage checks stayed
  strict. Diagnostic prints were removed.
- `first-python.log`: 26 tests, 3 failures, exit 1: two stale AppModel artifact hash
  assertions and the prior assertion requiring send to reconnect. Hash refresh
  and the new negative reconnect contract address these, without changing the
  original external failed admission test.
- `targeted-3.log`: 9 tests passed; `targeted-final.log`: 11 tests passed.
- `full-test-1.log`, `full-test-final.log`, `full-test-final2.log`: full-suite
  receipts retaining the socket failure. `release-build.log`: release build.
- A read-only build-process diagnostic (`ps`) was also denied by the sandbox;
  build completion was obtained from its own process result instead.

## Scope and remaining prerequisites

These are source and injected-fixture results, **not mounted acceptance**.
HTTP tests use the real parser/server, durable journal and admission controller
with injected task effects, then reconstruct all three. Core tests exercise
restart replay, changed fingerprints, missing reservation/outcome, simulated
crash windows, corruption, size/mode/symlink refusal, competing owner, concurrency,
capacity, sync errors and privacy. The decoded checksum and matching reservation
establish a retained acceptance snapshot; they do not establish provider delivery.
A failed outcome sync reports UNKNOWN in that call. If its complete checksummed
outcome survives reconstruction, retry may return that original snapshot; it
never redispatches. A partial or missing outcome remains UNKNOWN.

AppModel no-deferred-reconnect and warning/modal routing are source-contract
checks, supported by injected transport warning/isError assertions. A real
AppModel history callback race, forced work-log failure in the desktop, process
kill/relaunch, wrong-UID filesystem fixture, power loss and installed app behavior
are **NOT_RUN**. The owner check is implemented but wrong-UID testing would need
separate fixture authority. Same-UID malicious rewriting is outside the journal's
custody model. Exhausted or uncertain journals require explicit reconciliation
and evidence-preserving maintenance; no automatic recovery/pruning is provided.

No commit, push, PR, GitHub update, upstream change, service restart, permissions
change outside disposable fixtures, provider turn, signing command, install or
release was performed. GitHub reconciliation is **NOT_RUN by explicit session
boundary**; the managing engineer owns that record. Independent review, permitted
socket/CI checks, and separately authorized mounted qualification remain required.
