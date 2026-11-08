# Supervisor successor D2: deadline and observation-only recovery

Historical D2 record. The current successor's identity and selected D3 recovery
repairs are in the [M1/M2 disposition](m1-m2-offline-development.md).
References below to D2's `CANDIDATE.json` mean the preserved D2 snapshot.
Its raw file map remains in private custody and is not republished here.

`CONDUIT-SUPERVISOR-20261031-D2` is a separate, uncommitted source successor to
preserved [D1](supervisor-local-candidate.md). Its Git HEAD remains frozen R3
`382290bded447ea805ac71ed7d57bebeaf65f471`; HEAD does not identify the D2 source.
`CANDIDATE.json` and `supervisor-d2-candidate-files.json` identify the complete
content snapshot. D1's exact manifest and evidence remain historical inputs,
not an assertion that its old hashes match modified D2 files.

## Deadline semantics

The active execution deadline starts at committed GO. Each supervisor turn
observes the owned root before deciding whether to start timeout cleanup. Once
root exit is observed, the active clock no longer changes the outcome during
the 250 ms cancellation window or later cleanup observation. A timeout that
already started keeps its cause and cleanup obligations. Root exit code/signal
facts are retained independently of the timeout/cancellation disposition.

This is observation-order semantics, not an exact kernel exit timestamp or a
hard real-time guarantee. If root exit first becomes observable in the same
turn as an expired but unprocessed deadline, root observation wins. A still
running root remains subject to timeout. Accepted late cancellation still uses
the existing bounded original-group cleanup path. A naturally exited root
with an unresolved original group reports `unknown` and retains capacity;
crossing the active deadline does not manufacture cleanup success or signal
authority. The CDS1 wire format and existing cleanup budgets are unchanged.

> **Binds:** D2's internal disposable supervisor.
> **Tier:** T1, detected for the focused development cases.
> **Check:** `scripts/test.sh --filter 'ConduitSupervisorSuccessorTests|ConduitCommandSupervisorTests'` and source review. The script also runs the selftest and repository contracts.
> **Escape:** retain unknown outcomes and capacity; stop advancement when checks fail. These checks do not admit production execution or establish scheduling guarantees.

## Recovery contract

Recovery here means reading evidence without the original live owner. It grants
no execution, cancellation, ownership transfer, PID adoption, signal authority,
capacity release, claim removal or new attempt nonce.

| Retained object | Observation and allowed action |
| --- | --- |
| Valid terminal receipt | Read historical phase, root result, output and transitions. Terminal cancellation is an observation-only return. These facts do not establish present process absence or ownership. |
| Nonterminal receipt from another owner | Return a derived `unknown` phase while preserving recorded transitions, owner and process facts. Do not write a terminal event. Cancellation refuses with `process_ownership_unavailable`. |
| Exact original request and project/cwd binding | Return `idempotent_replay=true` with the same attempt nonce, without helper/payload launch, write admission, new slot or receipt update. |
| Changed request, project or directory identity | Refuse reuse. Omitted tail and explicit zero remain distinct request identities. |
| Reservation or launch claim without a readable outcome | Report `operation_receipt_missing`. Marker bytes are preserved; absence of a receipt does not mean no attempt occurred. |
| Corrupt, inaccessible or nonordinary receipt | Refuse; preserve the evidence. No fall-through to a new attempt. |
| Neither readable receipt nor known marker | `operation_not_found` means no readable record was located, not proof of non-execution. Production admission still refuses. |

V2 disk `executionCapacityReleased` remains false. Only the live owner's
successful final persistence can restore its own in-memory acknowledgement.
A fresh reader cannot reconstruct it from a terminal phase, FINAL frame,
observed group absence or marker contents. False historical capacity is not a
claim that a process is currently alive.

A fresh helper-enabled owner refuses new work when an old launch claim is not
in its in-memory receipt set (`supervisor_recovery_required`). Empty, malformed
and foreign claim bytes do not grant authority. An intact old v2 record still
blocks capacity when its claim is missing (`unresolved_command_ownership`). A
surviving reservation without a receipt is unresolved evidence. Failed execute
admission may create/synchronize the store lock; only lookup, exact replay and
historical cancellation are specified as observation-only paths.

Old used stores remain observation-only. Do not retire claims, adopt numeric
PIDs, switch stores or retry with a new ID to evade uncertainty. If external
tampering removes all evidence, this mechanism cannot reconstruct the attempt
or prove non-execution. No hostile same-user guarantee is claimed.

> **Binds:** D2 receipt observation/replay and internal fixture admission.
> **Tier:** T1 for the tested refusal/projection cases; operator guidance about preserving or retrying evidence is T0.
> **Check:** `scripts/test.sh --filter ConduitSupervisorSuccessorTests`; byte snapshots verify read paths preserve records. The selftest also checks marker-only status/refusal.
> **Escape:** keep evidence, report unknown/unavailable and refuse execution. Recovery execution requires a separate design and authority; no recovery API is introduced here.

## Development evidence and boundaries

The pre-repair regression run retained real fixture receipts and six failing
assertions across two tests: early exit 0/7 became `timed_out` with timeout
cause 2, and claim-only outcome lookup/replay did not report missing evidence.
The successor's private receipt binds before/after source, raw test-engine logs
and actual fixture bytes. Synthetic nonterminal snapshots and omitted-marker
cases are declared source-test fixtures, not crashed-owner or power-loss
evidence. The first adverse results are retained rather than overwritten.

The early-exit test explicitly requires root observation within 200 ms of
submission, which includes storage/bootstrap work before GO. A missed timing
precondition is retained as a failed/inconclusive fixture, not silently retried
or called proof of a deadline defect. Raising the timeout above the 250 ms
window would lose this immediate-exit regression's purpose.

Production initialization remains `execution_authority_unavailable`. A session
write gate cannot change it. No guest, execution profile, installation,
provider, hosted CI, release or guarded trial is implemented or run here.
The intended macOS 15.7.9 runtime and real crash recovery remain untested.
R3 A01–A06 remain NOT_RUN; B01–B10 remain BLOCKED_PROFILE_MISSING / NOT_RUN.

Reconsider recovery execution only with a separately bounded ownership,
confinement and unresolved-evidence design. This source repair does not choose
or implement that profile.
