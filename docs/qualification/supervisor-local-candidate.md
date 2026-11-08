# Supervisor development candidate D1

Historical D1 record. Its original contents and 429-input manifest are preserved
in private custody; the raw file map is not published here. The current successor
is identified by `CANDIDATE.json` and the
[M1/M2 disposition](m1-m2-offline-development.md); D1's manifest is not the
identity of the modified successor tree.

`CONDUIT-SUPERVISOR-20261023-D1` was prepared for bounded local synthetic testing. It is an uncommitted successor based on frozen R3 `382290bded447ea805ac71ed7d57bebeaf65f471`; its content identity is in the historical private `CANDIDATE.json` and `supervisor-candidate-files.json`. It has no new Git commit. R3 and its historical evidence remain separate.

The public service still rejects execution with `execution_authority_unavailable`. Only the internal disposable-fixture initializer selects this helper. No command, settings or environment option selects it. The helper is a development executable; it has not been packaged into or launched with an installed app.

## What changed

The [CDS1 protocol](supervisor-protocol-v1.md) uses a minimal C supervisor as the payload root's sole parent and waiter. It creates a private session, retains an exited root through a 250 ms cancellation window, and closes signalling authority before reaping. TERM/KILL cleanup applies only to the original process group. Root outcome, cancellation acceptance, output EOF/truncation, cleanup observation and durable completion remain separate facts.

Permanent operation reservations and exclusive launch claims prevent uncertain attempts from being relaunched with the same ID. Receipt updates are serialized. A failed final save keeps the live operation's capacity occupied and reports unknown; persisted v2 records cannot restore a previous owner's acknowledgement. Historical v1 records remain readable. A new owner encountering an existing supervisor launch claim refuses new execution pending a separately designed recovery process.

## Observed development checks

On macOS 27.0 build 26A428, arm64, with per-command Xcode SDK 26.5 / Swift 6.3.3:

- Full repository checks: 591 self-checks, 33 Python tests, and 827 reported XCTest cases (four skipped), zero failures in the final run.
- Eight supervisor integration cases cover late cancellation after exit code 7, TERM-ignoring original-group timeout, stable-ID replay, output bounds, prior-claim refusal, failed final persistence, closed-window cancellation and public guard refusal.
- The persistence test loops through 33 named syscall-fault boundaries with actual EBADF-producing syscalls. These are synthetic single-fault interceptions, not disk-full, power-loss or crash-durability evidence. One additional supervisor/final-save case checks the combined path.
- Eight separate native protocol probes cover the outside waiter's ECHILD refusal, outside-session peer join refusal, disconnect before GO, disconnect after GO with status loss, malformed identity, oversized control frame, output backpressure during cancel and duplicate GO.

The four skips were the opt-in 121-second fixture and three installed/provider checks. No model/API inference ran. Earlier build/fixture failures and pre-repair source snapshots are retained in private evidence. Final source review is informed implementation review, not blind or independent qualification. Prior R3 CI and adverse reproductions are inherited evidence, not new passes.

## Run surface for the next local test

Build `conduit-command-supervisor` with SwiftPM and compile `Tests/SupervisorFixtures/fixture.c` with an explicit macOS SDK. `scripts/test-supervisor-protocol.py` requires absolute executable paths and a new absolute output directory. It refuses to overwrite an existing directory and preserves raw frames, events and output. It runs eight cases sequentially, each with a 15-second controller bound; fixtures self-expire after four seconds. It stops on the first adverse case. Do not reuse old evidence directories or call these development repeats installed acceptance.

For the Swift integration and persistence surface, use `scripts/test.sh --filter 'ConduitCommandSupervisorTests|ConduitDirectCommandPersistenceFaultTests' --jobs 2` after building the helper. Clear opt-in `CONDUIT_*` environment variables; do not enable the public execution guard or any provider qualification switch. A separate review/test campaign should bind this candidate's exact content before execution and retain its own first adverse result.

## Limits and next coverage

This is original-group cleanup, not descendant containment. Escaping descendants, supervisor death, hostile same-user interference and privileged interference are outside the demonstrated guarantee. The 250 ms window is intentionally narrow; a late request after closure cannot recover authority. Buffered GO may commit before disconnect is observed and therefore may have run.

Still untested: the intended macOS 15.7.9/24G830 runtime; supervisor death and real owner crashes at launch boundaries; the broader bootstrap, sticky/short/partial-write/EINTR and recovery/concurrency persistence matrix; status-pipe saturation and malformed-status injection; a combined crash/cancel/storage-failure campaign; installed selection/task/draft behavior. No GUI source changed, and relevant baseline tests passed, but that is not installed human-state evidence.

Private READY-record reads and prelaunch blocking writes still retry EINTR internally. Repeated interruptions are a source-review limitation to strict per-turn bounds, not an observed failure of these cooperative fixtures. Prelaunch filesystem sync may stall; no payload exists then and no hard storage deadline is claimed. Native cancellation traces retain ERROR errno 1 alongside successful final cleanup; these observations do not establish general signal-delivery reliability. Compiled minimum OS 13.0 is build metadata, not runtime compatibility evidence.

**Disposition:** prepared for another bounded local synthetic test; S3 persistence coverage remains partial. App packaging, installed acceptance, guarded trial, production authority and release are NOT_ADMITTED/NOT_RUN. The current execution guard remains mandatory. Future repairs and broader admission require separately identified work; they are not implied by these passes.
