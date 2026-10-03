# Source-derived global supervisory cursor

`TaskSupervisoryHistory` prepares a deterministic, paginated view of declared
`TaskSessionEventLogReadResult` snapshots. The existing per-task event logs
remain the append authority. This Core helper performs no filesystem access,
append, repair, task transition, runtime launch or provider operation.

This is the bounded schema and fixture preparation for
[#4](https://github.com/camerontjs-dot/Conduit/issues/4), section 9, and its
[canonical-history acceptance](https://github.com/camerontjs-dot/Conduit/issues/4#issuecomment-5843421082).
It does not satisfy the full
[#53 consequential-consumer gate](https://github.com/camerontjs-dot/Conduit/issues/53#issuecomment-5843421229).
D-074 remains Proposed/T0. No app, HTTP or MCP endpoint consumes this helper yet.

> **Binds:** proposed consumers of this Core helper and this candidate's bounded claims.
> **Tier:** T0, advisory consumer contract; this document grants no execution or source authority.
> **Check:** source tests exercise admission, cursor reconciliation, projection and privacy; independent qualification and integration are separate gates.
> **Escape:** keep input authenticity, unavailable runtime facts and missing integration UNKNOWN; preserve refusals instead of discarding a cursor or healing a source.

## Input and source authority

A caller supplies one logical store UUID and one decoded snapshot per task.
The UUID is a namespace, not directory authentication. The helper cannot prove
who read the files, that a source was authentic, or that separate task reads
represent one atomic instant.

Admission checks the current task event schema, the existing
`TaskSessionEvent.hasValidAuthority` contract and the task identity on every
record. Each source begins with a distinct creation event. Any diagnostic from
the supplied read result blocks the whole query with `reconciliationRequired`.
Only diagnostic kinds and task identities appear in that refusal; source paths
and diagnostic detail do not appear.

The snapshot summarizes diagnostics as a sorted set of their finite typed kinds.
Each kind appears once, regardless of occurrence count or diagnostic input order;
every distinct kind remains visible. Refusals reuse that summary. Occurrence
counts and line positions remain in the original per-task read result, which
this helper does not change. This normalization never makes a diagnostic source
clean or allows a page or replacement cursor.

An identical decoded event UUID within one task retains its first occurrence.
Its duplicate positions still contribute to the source prefix identity. A
different decoded record with that same UUID, or a second distinct creation
event, requires reconciliation. The same UUID in different tasks is valid:
global event identity is `(taskSessionID, sourceEventID)`.

## Projected records and UNKNOWNs

The projection exports source identity, original decoded source ordinal,
internally computed decoded record digest, exact source dates, source authority,
an explicitly supplied runtime-attempt reference where representable, and one
of these content-free kinds:

- task created;
- runtime provisioning, opened, provisioning failed with recoverability, or detached;
- task closed with its recorded reason;
- interrupt observed;
- conversation activity or retention enabled;
- Shell telemetry phase or process observation recorded.

Titles, paths, backend names, failure strings, command text, approval content,
file bodies and PTY transcripts are absent. Ordinary title/pin/archive changes
contribute to prefix identity but do not become supervisory records.

`runtimeOpened` is the recorded task event kind; it is not provider readiness.
A runtime reference is a source-supplied reference, not a freshly verified
runtime binding. Shell exit, task closure and conversation activity do not
imply provider completion, task success, verification or acceptance.

Every ready page explicitly lists unsupported facts: source authenticity,
provider session and turn identity, provider progress, workspace identity,
approval authority, verification, acceptance, current native state, global
append time and total chronological order. The current source lacks the typed
queue/delivery, provider-turn, approval-resolution and recovery-result facts
needed for the broader programme contract. This helper does not invent them.

## Reconciliation and pagination

Schema version `1` and policy `task-metadata-supervisory-v1` use a `gsv1:` cursor
containing canonical base64url JSON. It names the store, sorted task identities,
consumed source positions, the count and digest of each entire previously
observed source prefix, and the last emitted task.

Each query recomputes these digests from supplied decoded source records.
Caller-supplied hashes are never substituted for source data. All previously
observed records are bound, including the suffix not yet emitted in an earlier
page. Removing a known source, truncating it, changing its prefix or changing a
hidden metadata field produces an explicit refusal with no usable page or new
cursor. Appends and new tasks remain queryable with the old cursor, including
backdated events and tasks whose UUID sorts before existing tasks.

Per-task order follows the source ordinal. Across tasks, pagination uses stable
UUID sorting and round-robin selection after the last emitted task. A source
timestamp never sorts records ahead of their append position. This is a
deterministic enumeration policy, not a new chronological global ledger.

The cursor is an untrusted query position. It is not signed, does not prove a
client consumed a page and cannot grant task, runtime or provider authority.
Malformed, noncanonical, wrong-version, wrong-policy, wrong-store, duplicate,
out-of-range and unknown-field cursor inputs fail closed instead of silently
starting again. A clean exhausted continuation preserves its cursor.

## Identity encoding and privacy limits

The digest covers all typed decoded fields, including metadata excluded from
the public projection. Canonical JSON uses sorted keys and exact finite
reference-time `Double` bit patterns for dates. It does not claim equality to
literal JSONL bytes, authentication of the file writer or physical log custody.
An identical decoded record represented differently on disk has the same
decoded identity.

Digests can reveal equality and are unsalted; removing literal content does not
establish cryptographic confidentiality or protection from content guessing.
`canonicalData` supplies deterministic Core output bytes.
`decodeCanonicalData` rejects noncanonical encodings and preserves those bytes;
it is mechanical deserialization, not validation of arbitrary results against
an authentic source or authorization to consume them as runtime truth.

## Logical budgets

| Boundary | Limit |
| --- | --- |
| Source snapshots | 128 |
| Decoded records per source | 4,096 |
| Decoded records total | 8,192 |
| Canonically encoded decoded record | 65,536 bytes |
| Canonically encoded decoded records total | 8,388,608 bytes |
| Encoded cursor | 65,536 bytes |
| Default / maximum exported page | 20 / 50 records |
| Diagnostic kinds per snapshot and generated refusal | 9 distinct current typed kinds |

Missing or nonpositive page limits use the default; larger limits clamp to 50.
These are admission and output budgets over already allocated snapshots. They
do not bound physical traversal, upstream decoding or total process memory.
The diagnostic summary and the single generated refusal issue do not grow with
repeated diagnostic occurrences. This is a bound on helper-produced metadata;
`canonicalData` and `decodeCanonicalData` do not admit arbitrary caller-authored
results as validated helper output.

## Evidence and remaining gates

`TaskSupervisoryEventsTests` and matching `conduit-selftest` checks cover the
portable contract. Machine pressure additionally uses distinct native processes
and qualification-owned physical task logs to persist a cursor, append in a new
process, resume it and preserve a torn source line. A new reader within one
XCTest process is a separate, narrower check.

Owner checks do not independently qualify the candidate. Before promotion,
a fresh qualifier must derive and freeze its oracle against the exact candidate.

Frozen [#145](https://github.com/camerontjs-dot/Conduit/pull/145) failed a later
source-exposed supervisor pressure check: repeated read-diagnostic kinds grew
the refusal output to 131,242 and 524,458 bytes; 9,216 mixed diagnostics produced
193,690 bytes. Its fail-closed, privacy and roundtrip controls passed. This
separately identified successor normalizes the finite distinct-kind summary;
the failed candidate and its dated owner checks remain historical evidence.
Its previously retained temporary native/package artifacts became unavailable
at their recorded paths after an environment change. New source or builds do
not reconstruct that custody, and the separate first-release retention failure
remains FAIL.

Before app or control-plane integration, an adopted source adapter must establish
authenticated source selection, bounded physical reads and the identities and
typed runtime facts the intended consumer actually needs. Mounted restart,
duplicate create/send safety, provider/runtime disagreement and the complete
supervise/follow-up/verify/accept journey remain separate programme work.
