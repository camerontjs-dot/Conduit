# Explicit record sources

`ContextRecordSourceAdapter` adapts explicitly selected agent artifacts,
test/qualification receipts and authored lifecycle/project records into the
existing Context Compiler. It reads the selected UTF-8 file or exact line range
through `ContextFileSourceAdapter`; it does not discover the latest record,
parse a receipt result, or look up a live task.

Owner: [Context Compiler #58](https://github.com/camerontjs-dot/Conduit/issues/58).
This is an additive source candidate over frozen
[#148](https://github.com/camerontjs-dot/Conduit/pull/148) at
`2f895fb471ce85c58f28065f23b7d7883ac8f0a0`, tree
`f40aea84d07ff5878badfac810d371025a631683`. It uses the unchanged #140 exact-file
reader and maintained compiler carried by that parent. Its preparation neither
qualifies those dependencies nor incorporates the separate authored-link, Git
producer, runtime, Explorer or Next Move candidates.

## Caller declarations and authority

Every record request must declare its provenance. The adapter cannot establish
authorship from a path, successful read, filename, JSON field, or result word.

| Declaration | Context authority | Meaning retained |
| --- | --- | --- |
| `agentArtifact` | `agentOutput` | Agent-produced material, with an optional explicitly supplied task association. |
| `testReceipt` | `testReceipt` (observation class) | Text of a selected test or qualification record. Its claimed result is not validated. |
| `lifecycleRecord` | `lifecycleRecord` (source class) | Text from a caller-identified authored lifecycle/project record. The record's state claims remain unverified. |
| `unknown` | No admitted candidate | The adapter refuses the declaration before reading; the caller must retain the missing provenance decision. |

A generic task artifact with unknown authorship does not qualify as an authored
lifecycle record. Ordinary authored files can use the existing exact-file API.
An agent-produced report remains `agentArtifact` unless an independent caller
boundary has established a different provenance; merely storing it beside
project records cannot establish that boundary.

The optional `associatedTaskIdentity` is labeled as a caller declaration. It
does not assert that the named task produced the bytes or that the task has
completed. Empty, NUL-containing or oversized task/staleness declarations are
refused. No native task history, provider persistence, PR/issue state, execution
receipt store or filesystem adjacency is consulted.

## Selection, observation and handoff

```swift
let selected = ContextRecordSourceRequest(
    file: .init(
        relativePath: "receipts/qualification.txt",
        origin: .operatorPin,
        expectedContentDigest: knownFullSourceSHA256
    ),
    provenance: .testReceipt,
    associatedTaskIdentity: "explicit-task-reference"
)
let observed = try ContextRecordSourceAdapter().observe(
    root: selectedRoot,
    requests: [selected],
    requiredRequests: requiredExactFiles,
    observedAt: observationTime
)
let contextSet = try observed.makeContextSet(
    id: "review-context", objective: "Inspect the selected evidence"
)
```

`knownFullSourceSHA256`, `selectedRoot`, `requiredExactFiles` and
`observationTime` are caller inputs in this example. If an expected identity is
unavailable, omit it; the adapter still binds the observed bytes to an actual
full-source SHA-256 digest. A digest establishes byte identity, not authenticity,
correctness, freshness, applicability, review independence or acceptance.

Each observation preserves its explicit request, source digest, exact ephemeral
bytes, observation time and any existing reader failure. Record entries use the
declared provenance instead of exposing the reader's internal filesystem-source
entry. Whole files keep the real content digest; excerpts keep the source
revision and exact range, with the represented byte digest in the observation.
Equal bytes in different line ranges retain distinct compiler identities.

All record selections and `requiredRequests` share one bounded reader batch.
The existing request/file/total-byte limits therefore apply to the complete
input, and duplicate exact paths share the reader's bounded read. Missing,
changed, unsafe, linked, oversized, non-UTF-8 or out-of-range selections retain
their failures. Any unresolved selected input, including an ordinary optional
selection, refuses a complete handoff. The caller can inspect partial
observations without representing them as a complete Context Set.

`isComplete` concerns source observation. `isHandoffEligible` also checks that
compiler deduplication can retain record metadata. `makeContextSet` creates
references and component versions; it does not send content to an agent.

## Freshness and duplicate metadata

A read at `observedAt` proves a bounded byte observation. It does not establish
that a historical receipt applies to a current candidate, that a lifecycle
record reflects current project state, or that the path will remain unchanged.
Accordingly, default freshness remains `unknown`. An explicit stale declaration
is retained. A caller-supplied `current` claim is refused by this API.

The adapter uses the maintained compiler's actual deduplication. It does not
change its equality policy, create a parallel identity implementation, or alter
a digest to defeat deduplication. Duplicate reasons, paths and pins coalesce
under that existing policy. A final guard refuses a complete set if that
coalescing would discard a selected record's exact authority label or a declared
stale reason. The result is `incompatibleDuplicateMetadata`, with all original
observations still available.

For example, selecting a stale receipt and separately pinning identical bytes
with unknown freshness cannot erase the stale declaration. Similarly, pinning
a lifecycle record through the ordinary file API cannot replace that selected
record's provenance label silently. The caller should reconcile its explicit
selection declarations; the adapter does not choose an unestablished authority
or freshness policy. Later composition with other adapters requires the same
care at its own boundary.

## Verification scope

This candidate includes `ContextRecordSourceAdapterTests` and matching public
API checks in `ContextRecordSourceChecks.swift`, registered in the existing
`conduit-selftest` executable. The authoring environment has no Swift/Xcode
runtime. Compilation, XCTest, SelfTest, native execution and packaging are
**NOT_RUN** at preparation time. Source inspection is not execution evidence.

The local agent should recover the published candidate's exact SHA/tree and the
governing qualification setup before executing anything. In its owned macOS
checkout, the existing product entry point supports a focused first run:

```bash
./scripts/test.sh --filter ContextRecordSourceAdapterTests
```

This runs the registered SelfTest checks before the focused XCTest suite. The
complete product suite and release build remain separate required gates under
the programme's qualification plan; the focused command alone cannot qualify
the stack. Preserve actual commands, waits/exits, toolchain identity, raw
transcripts and original failures. A missing expected report remains an
apparatus/evidence failure until separately resolved; do not infer execution
from an aggregate summary.

| Boundary | Maintained owner control |
| --- | --- |
| Provenance versus receipt result words | One physical file containing `PASS`, `verified` and `current` yields three separate declared authority classes, all freshness UNKNOWN. |
| Explicit selection | An empty selection reads no nearby `latest` record. |
| Unknown or unsupported declarations | Unknown provenance, current freshness and malformed declaration fields fail before file observation. |
| Staleness and hard context | A pinned stale receipt retains provenance/staleness and an explicit budget conflict. |
| Missing sources | Each selection origin and a separate required contract prevent partial-success handoff. |
| Observed bytes | Known SHA-256, stale expected digest, same-length replacement and physical between-pass mutation retain their exact outcomes. |
| Reader safety and coverage | Unsafe paths, a physical symlink, invalid UTF-8, wrong root, shared request/byte limits and absent lines preserve failures. |
| Deduplication | Equal record bytes retain pin/alias/reasons; metadata-erasing duplicates refuse a complete set. |
| Reproducibility | Reordered explicit requests retain batch and manifest encoding. |

The XCTest-only mutation hook interposes an actual owned file change between
the unchanged reader's two passes. It does not inject success, bytes, identities
or observations. The public SelfTest checks cover the same admission boundaries
available through public API; they do not expose that internal hook.

These are owner-created controls. A separate source review or local agent must
describe its actual independence and remaining exposure. Neither a second
reader of these tests nor a future green owner run establishes independent
qualification, mounted delivery, schema validation, acceptance or release.
