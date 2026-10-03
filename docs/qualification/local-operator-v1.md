# Local Operator V1 candidate boundary

This candidate advances [#51](https://github.com/camerontjs-dot/Conduit/issues/51)
within [#4](https://github.com/camerontjs-dot/Conduit/issues/4),
[#49](https://github.com/camerontjs-dot/Conduit/issues/49) and
[#60](https://github.com/camerontjs-dot/Conduit/issues/60). D-066 is a proposal.
The existing qualified #70 Shell correlation is reused with its bounded claims.
The whole Local Operator V1 is not qualified by this source change.

## Supplied boundary and local authorizer

`conduit_local_preflight` observes nominated regular files and repository/process
state for one existing exact Shell task without writing a record.
`conduit_local_begin` records a stable operation UUID, immutable objective,
acceptance condition, requested mode, explicit nominated/protected paths and
bounded unrelated pre-existing dirty files. `conduit_local_checkpoint` appends
an observation at the exact expected revision; it executes no command.
Status, receipt, changes and children helpers read the last durable record.

Begin and checkpoint require the existing local Session API write gate. The
record distinguishes that observed gate from the supplied mode. The listener's
nominal initialized caller identity does not become a scoped principal or an
operator approval. CONSEQUENT_LOCAL_CHANGE always records
OPERATOR_DECISION_REQUIRED; this candidate has no consequent grant path.

Supplying `local_operation_id` to existing `conduit_send_prompt` checks one exact
continuing BOUNDED_WRITE operation immediately before delivery. It requires
canonical full task and operation UUIDs with no known runtime/runtime-attempt
aliasing; an operation cannot reuse its task or attempt identity. It requires
unchanged nominated/protected files, repository/root and an exact live owned
Shell launcher plus current Shell cwd. Missing authority or identity, malformed
arguments, unknown coverage or changed state is refused before prompt recording
or terminal delivery. OBSERVE does not authorize arbitrary Shell input.

The helper does not classify arbitrary command text, sandbox Shell, make check
plus delivery atomic, or extend the separately available generic Shell surface.
A regular file outside Git or outside the nominated/protected set is not covered.
A fixed bounded file set is deliberate; a directory is not silently treated as
a recursive inventory. Working trees whose project/task/Shell identity cannot
be resolved exactly remain unavailable.

## Recorded observation and recovery

Inspection is nonrecursive: at most 64 nominated/protected regular files, each
at most 1 MiB. Descriptor-based reads refuse leaf/parent symlink traversal,
nonregular files, changing file identity and incomplete Git state. Missing,
unavailable and unchanged remain distinct. Digests and exact relative paths are
retained without file bodies; observed changes do not establish authorship.

Protected changes, OBSERVE mutations, changed repository identity/branch/HEAD,
and repository status changes outside the nominated file scope block the
operation. Authenticated Shell command observations stay bound to the recorded
runtime attempt; raw command text and terminal bytes are not retained. Fleet's
existing #70 correlations retain their original provider/process stamps and
UNKNOWNs. A first page and 64 retained links are bounded summaries, not a claim
that all children or provider sessions were enumerated.

Revisions are exclusive append-only owner-readable files under task state.
Expected revisions reject stale/duplicate writers. A durable read validates the
same immutable boundary/preflight/authorizer, contiguous history, typed fields,
recomputed deltas and disposition constraints. Torn or inconsistent history
fails closed without repair. A stopped record cannot reopen. This is operational
recovery, not authenticated custody against other processes of the same OS user.
Acceptance is always NOT_ESTABLISHED, including a terminal receipt or exit zero.

## Evidence and outstanding acceptance

Owner source/native checks are implementation evidence. They do not establish
independence or the installed AppModel/HTTP/Shell path. Exact candidate identities,
executed checks and preserved failures are recorded in the associated Draft PR
and machine receipt. Frozen failed source and attempts remain preserved in the
programme evidence; a later pass does not rewrite their disposition.

The latest owner run executed 486 selftests, 10 Python contract tests and 637
XCTest cases with no failures. Three existing installed/provider qualification
cases were explicitly skipped; the 33 Local Operator cases ran. The maintained
release build, uninstalled bundle signing/resource/minimum-OS checks and 486
release selftests passed. A separate native owner writer and reader recovered
the same two immutable records; torn, gapped and hidden-change copies were
refused without repair. These are bounded owner mechanics and packaging checks.

The earlier green 25-case Core run was followed by a failing semantic-tampering
pressure check. A later identity check also failed when an operation UUID reused
task/attempt identity. Both failed source snapshots and actual logs are preserved;
the final source includes the corresponding regressions. The interrupted disk
capacity run executed no tests and remains an apparatus failure, not a candidate
pass. Initial sandbox/toolchain/compile failures are retained separately.

| #51 acceptance case | Available owner evidence boundary | Remaining runtime gate |
| --- | --- | --- |
| 1. Read diagnosis | Physical bounded files/repository preflight without mutation | Exact ChatGPT-origin Shell/task/listener read journey |
| 2. Bounded write | Physical file deltas, protected bytes, authorizer/identity refusal | Real Shell delivery and command/checkpoint readback |
| 3. Artifact reveal | Exact created path and digest in changes receipt | Qualified Explorer reveal/open composition |
| 4. Worker correlation | Readback of existing #70 Fleet wire identity and authority | Isolated exact child/provider session and existing correlation gate |
| 5. External conflict | Physical file/repository mutations refused or recorded BLOCKED | Mounted delivery refusal before any input side effect |
| 6. Process scope | Actual qualification-owned process identity and unknown controls | Mounted exact Shell process ownership without unrelated cleanup |
| 7. Protected actions | Consequent mode has no grant; malformed supplied boundary refused | Runtime refusal; no arbitrary-command classifier is claimed |
| 8. Recovery | Immutable typed revision/readback and torn/gapped/semantic controls | Exact app restart and durable read without terminal reconstruction |

All remaining runtime gates require the
[#87](https://github.com/camerontjs-dot/Conduit/issues/87) qualification isolation
boundary, the frozen candidate and fresh independent qualification where
consequential behavior is claimed. Normal operator state, sessions, apps and
listeners are protected. New paid usage, account/auth/model changes, installation
or release are not authorized by this candidate. A blocked real-provider gate
does not promote a deterministic fixture into provider qualification.
