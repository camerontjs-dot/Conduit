# Durable logical orchestration records

The schema/fixture half of [#56](https://github.com/camerontjs-dot/Conduit/issues/56)
and [#60 Wave 4 Phase A](https://github.com/camerontjs-dot/Conduit/issues/60)
adopts a logical run above Fleet. `OrchestrationRun` retains one proposal, plan
version, policy version and bounded ordered step list. The existing
`OrchestrationRunState`, proposal reducer and proposal policy remain unchanged.

This Core slice has no AppModel, UI, Session API or provider consumer. A recorded
proposal is still staged work. Its `suggestedAgent` and scope pass through the
existing policy before any later approved handoff. A run record, condition,
checkpoint or successful append creates no route, approval, writer lease, task,
provider session or turn.

## Identity and observations

| Record | Meaning |
| --- | --- |
| `OrchestrationRunID` | One durable logical objective/plan |
| `OrchestrationStepID` | One logical step in that immutable plan |
| Proposal fingerprint | The existing proposal content identity |
| Command UUID | One exact retryable logical-record request |
| Event UUID and sequence | One recorded occurrence in the run journal |
| `TaskSessionID` / `RuntimeAttemptID` | Existing task and concrete attempt references |
| Provider/session/turn/workspace fields | Separate known or UNKNOWN correlation references |
| Evidence reference | Declared source ID, revision, authority, freshness and time |

The step list has 1–64 unique identities and references only earlier steps in
the same run. This is a bounded plan representation; it does not implement a DAG
scheduler, concurrency policy, dynamic plan changes or recursive delegation.
Workers can be released and replaced only by matching the complete current
reference. Run and step identity survive that change. Every earlier reference
remains in the journal.

Conditions describe route readiness, worker binding, input requirements,
verification, capacity, writer collision and workspace mismatch. UNKNOWN and
stale observations stay labelled. No condition selects a route or resolves an
approval. Provider, process and Shell observations can support recorded
progress; they cannot substitute for a separately recorded verification,
external acceptance or logical terminal decision.

The latter decisions require a current, timed `conduit_recorded` reference.
That checks the declared receipt category only. It does not authenticate its
author or inspect the referenced evidence. Future consumers need qualified
control-plane feeds and their own caller authority. This store cannot turn a
self-declared stamp into trusted live authority.

Replay preserves each observation's original freshness and time. A historical
`current` stamp describes the declaration when it was recorded; recovery does
not re-age it or assert that the runtime fact is still current. Live consumers
must revalidate the referenced source before using it for a new decision.

A completion report leaves verification and acceptance UNKNOWN. Subsequent
UNKNOWN/blocked observations cannot erase its monotonic completion fence and
re-queue the same step. A dependent step can be recorded queued/running only
after its predecessors have separate passed verification and accepted outcome
records. A completed run also needs those explicit step decisions and separate
run verification/acceptance. Failure and supersession remain separate terminal
dispositions. All of these are caller-supplied logical records, not independently
verified outcomes or physical scheduling decisions.

## Journal and recovery

`OrchestrationRunJournal(directory:runID:)` requires an explicitly chosen,
existing, current-user private directory (`0700`). There is no home-directory
default and reads do not create directories or files. Journal and checkpoint
files must be private regular files (`0600`) with a single link. Leaf symlinks,
FIFOs, nonprivate paths and mismatched opened/named identities are refused.
Ancestor-path confinement and hostile same-user mutation are not established.

An append supplies the exact command UUID, run ID, expected revision, action,
event UUID and record time. The first action is a validated create record.
Subsequent records require the current revision. A retry of the entire same
command returns its original event without appending another record, including
after later events have advanced the journal. A conflicting command/event ID
fails closed. An unused replacement event UUID/time on an exact retry does not
replace the originally recorded event.

Records use schema v1 canonical JSON, explicit millisecond dates, a contiguous
sequence and the preceding record's SHA-256 digest. Canonical decoding rejects
unknown fields and noncanonical bytes; hashes identify content and are not
signatures. Journal limits are 1,024 events, 8 MiB total and 256 KiB per record.
Bounds do not auto-expand or evict old records.

Cooperating processes use nonblocking shared/exclusive locks on the same named
journal inode. Contention returns `busy`. File and directory identity are
checked around access. Writes synchronize the file and containing directory.
These checks do not make filesystem mutation an atomic transaction. A failed
append or checkpoint may have written bytes before an I/O or subsequent
identity failure; the result does not promise rollback.

Recovery replays the complete journal in file order. Empty, partial, malformed,
gapped, wrong-run or duplicate history is unavailable. Reads and append refusal
do not trim, skip, heal or rewrite those bytes. A crash before the first complete
record can leave an empty file requiring a separately authorized disposition.
No recovery path silently reuses it as a new run.

Checkpoints are immutable, separately identified files created exclusively.
The selected checkpoint must match the complete event prefix's digest and
replayed projection. Recovery then returns the journal's current projection,
including the suffix. A missing or corrupted selected checkpoint fails; it does
not fall back silently. A checkpoint cannot outrank, repair or replace source
events. Replaying the prefix first establishes consistency, not a performance
optimization or authenticated custody.

Checkpoint creation is bounded to 256 KiB. A selected checkpoint read has the
same 8 MiB input bound as a journal, then must match the replayed prefix exactly.
An oversized creation fails without a checkpoint; recovery does not evict
history or trust a larger supplied snapshot as source authority.

The physical owner fixture covers distinct writer/recovery processes, a
committed append followed by an abrupt exit before response, competing writers,
held locks, corrupt copies and older checkpoint recovery. It does not establish
GUI restart, runtime/provider continuity, hard power-loss durability, hostile
same-user resistance, live source truth or full supervisory journey acceptance.

## Authority and qualification

[#4](https://github.com/camerontjs-dot/Conduit/issues/4) remains the canonical
task/runtime/turn event and command authority. #53 owns provider/process
reconciliation; #57 owns workspace leases; #58 owns context provenance. This
run journal stores logical orchestration history and references those contracts.
It neither reconstructs their state nor supplies missing runtime facts.

The [owner evidence index](qualification/orchestration-run-owner.json) separates
finite component/physical replay checks from pending independent qualification.
Keep the candidate Draft until the required fresh gate names the exact head and
tree. Native packaging is a build check; it is not a release, installation,
mounted journey or operator acceptance.
