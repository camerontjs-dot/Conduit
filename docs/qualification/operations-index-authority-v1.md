# Operations database authority repair qualification

This is the replay protocol for the separately frozen producer, engine-contract
and consumer successors of Conduit #110 and MainFrame #43. Implementation tests
are development evidence. They are not independent qualification.

The exact three heads, trees and source commits belong in the cross-repository
GitHub handoff. Refuse moved identities or new semantic changes. The consumer
manifest pins the producer and engine; the producer manifest pins the engine.

## Ownership and contract

MainFrame owns membership, source manifests, typed coverage, source/document map
verification, stage/promotion receipts and daemon configuration. After its exact
map checks pass, it declares index/trust/scope/lifecycle and manifest/map hashes.
MindGraph binds that declaration inside the selected database to its complete
stored document map, then validates identity and retrieval in one read snapshot.
Conduit checks the explicit v1 envelope and retains every existing returned-row
guard before projecting nomination text. Caller scope and DB filenames supply
expectations; neither creates authority.

The additive engine contracts are `mindgraph-index-identity/v1` and
`mindgraph-query-identity/v1`. The legacy knowledge/projects CLI arrays and intent
envelopes remain available. Conduit requires the new envelope for operations in
the Core Session API function used by AppModel and in Query Station. MainFrame's
opt-in three-scope daemon requires stored operations identity at startup and on
each query. See the pinned engine's `docs/index-identity-v1.md`.

## Independent execution

1. Verify live GitHub heads/trees, Draft status, predecessor preservation,
   compiler blobs and all tracked bytes before execution. Create isolated
   worktrees, build/model caches, TMPDIR, DBs, loopback ports and daemon resources.
   Inventory unrelated worktrees and shared operator resources without changing
   them. Use a real engine built/imported from the pinned source; record its
   executable, Python/runtime, wrapper bytes, imported source and model provenance.
2. Use explicit selected, hash-bound sources and manifests with the real frozen
   MainFrame producer. Create separate disposable knowledge, projects and
   operations DBs. Do not substitute the known failing whole-workspace route.
   Record namespaces, source/document identities, hashes, stored identity and
   exact stage/promotion receipts. Knowledge's legacy producer route does not
   become a claim of native knowledge stage/promotion machinery.
3. Inspect the stored binding independently through `index-identity --db DB` and
   actual query envelopes. Require index `mainframe-operations`, trust
   `operations_status`, scope `operations`, lifecycle `40_operations`, producer
   `mainframe-live`, valid manifest/source-map/database-map hashes and document
   count. Compare these with producer receipts and direct DB/source evidence.
4. Run `MindGraphOperationsTests.testRealProducerConsumerBoundary` through the
   actual Core function using all five explicit settings below. Capture a new
   receipt; a missing-settings skip is not PASS. Append the real producer and
   executable provenance to the bounded receipt.
5. Exercise the actual authoritative tool catalog, schema and server dispatch
   for knowledge, projects and operations. Scope is required; unknown, invalid and
   `both` fail. Use the real Streamable HTTP client with a disposable three-scope
   daemon, distinct DB paths, and fail-closed startup/request checks. Confirm an
   empty query response still carries validated stored authority. Mutate only an
   owned control DB to demonstrate that a changed binding after startup fails.
6. Run relevant MainFrame producer/configuration/contract/tool-map checks, focused
   Conduit operations tests, the repository-native product gate, the full Swift
   suite, release build, strict/deep signature verification, changed-surface
   checks and `git diff --check`. Record actual pass/fail/skip counts, warnings and
   any missing ignored live-manifest apparatus. Inspect hosted CI separately;
   zero executed steps are infrastructure non-execution, not candidate evidence.
7. Verify compiler blobs remain `843bc359108c2f5b792bfa76bb10ae2e062813d1`
   (source) and `14aebc36150a304b8e72578a646bea35852f728b` (tests). Run focused
   compiler tests and unchanged #103 structural-collision / #104 reason-order
   probes. Confirm no implicit ContextSet membership, expansion/delivery,
   manufactured verification, or task/runtime/provider mutation.
8. Recheck custody: exact heads/trees, compiler and tracked bytes unchanged;
   fixtures/DBs outside candidate trees; temporary daemons stopped; shared
   operator install/configuration and unrelated worktrees preserved. Attribute
   concurrent changes explicitly rather than claiming unchanged global state.

Required integration settings:

```text
CONDUIT_MINDGRAPH_QUALIFICATION_BINARY
CONDUIT_MINDGRAPH_QUALIFICATION_HOME
CONDUIT_MINDGRAPH_QUALIFICATION_RECEIPT
CONDUIT_MINDGRAPH_QUALIFICATION_OPERATIONS_QUESTION
CONDUIT_MINDGRAPH_QUALIFICATION_OPERATIONS_PATH
```

## Required discriminators

| Selected DB / result | Required observation |
| --- | --- |
| Valid operations with hits | Stored operations binding plus expected namespace/document/source paths; compatible nominations only |
| Valid operations with lexical no hits | Success with zero nominations and independently validated operations binding |
| Valid operations with explicitly empty result budget | Zero nominations; DB identity remains present and validated |
| Projects selected as operations, with hits | Explicit rejection, no admitted text, no fallback |
| Projects selected as operations, with no hits | Explicit rejection despite zero rows |
| Valid schema but unidentified empty DB | Explicit rejection; no query-time identity backfill |
| Wrong stored index/trust/lifecycle/source map | Explicit rejection, including zero-row queries |
| Missing DB / failed real producer | Explicit failure, no target creation/substitution or incompatible nominations |

Keep knowledge/projects positives, warnings, citation partitions, freshness and
UNKNOWN state. Reproduce #43 cross-scope receipt, DB/config substitution,
unavailable manifest, producer failure, duplicate/alias/path-collision controls.
Do not patch both sides to make a failing boundary green. Stop and classify a
material failure. Query envelopes authorize index selection only.

## Original failing discriminator

`pr110-no-row-discriminator.swift` is the original qualification source, unchanged
at SHA-256 `bd8aeadd5d73f559b7a129ed8c426974e30eaea25198dbece2479ee647744d7d`.
Compile with `-parse-as-library` and link actual Core objects, using the original
fixed inputs and its explicit environment settings. Preserve the original #110
head and engine pin for a baseline replay, then mechanically rerun the same
source against the successor Core/engine with owned DBs. Inspect the complete
paired payload receipt in both runs.

Its historical assertions require both incompatible queries to succeed with
zero rows and then report BLOCK (exit 1). On the repaired boundary those queries
must fail, so the unchanged historical program reports its apparatus
INCONCLUSIVE (exit 2). That exit is not an independent PASS or a repaired-candidate
failure. Keep the assertions and verdict intact; separately adjudicate actual
payload rejection under the required discriminator table above.

## Limits and terminal receipt

Preserve Conduit #110 BLOCK comment `5913161920`, MainFrame #43, and #106 as
history. The prior whole-workspace Evidence Room README prerequisite failure is
not repaired or erased. Live whole-workspace corpus readiness and operator
installed engine equivalence remain UNKNOWN. Preserve the predecessor D-060
number collision for later combined reconciliation.

Index authority is local producer authority, not authentication against a
malicious writer replacing both data and binding. It does not establish source
verification, retrieval quality, freshness, filesystem observation/expansion,
final Context Compiler composition, Supervisor delivery, autonomous routing, or
merge/release authority. Do not run the final composition experiment.

Post a complete independent receipt on the consumer successor and cross-link the
producer/engine successors, historical #110/#43, and Conduit #58/#60. Use explicit
BLOCK or INCONCLUSIVE for missing or failed required evidence; only a fully
supported bounded result can authorize a later operations promotion decision.
