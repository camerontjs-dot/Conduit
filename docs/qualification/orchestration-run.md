# OrchestrationRun / Step qualification boundary

Owner: [#56](https://github.com/camerontjs-dot/Conduit/issues/56), adopted by
[#60 Wave 4 Phase A](https://github.com/camerontjs-dot/Conduit/issues/60).
Contract: [durable logical records](../orchestration-run-contract.md).

The candidate is an unmounted Core schema/journal/checkpoint preparation slice.
Freeze its exact base, head and tree before qualification. The fresh qualifier
derives and freezes an oracle from the governing acceptance boundary before
reading source, tests, owner receipts or implementer conclusions. It must not
repair the candidate. A defect returns to a separately identified implementation
successor with the failed evidence preserved.

The bounded claim is logical run and step continuity through explicit storage
and separate-process recovery. Test physically invoked Core code with dedicated
private directories and exact teardown ownership. Required properties:

1. A one-step and a bounded sequential plan retain proposal/plan/run/step identity
   across a fresh process, checkpoint recovery and worker-reference replacement.
2. Task, runtime attempt, provider session/turn, workspace, command, event,
   verification and acceptance identities stay separate. Known/UNKNOWN and
   freshness labels survive serialization. Wrong authority cannot become a
   verification or acceptance record.
3. Exact retries after a lost response return the original logical occurrence.
   Conflicting command/event IDs, stale revisions and foreign step/run references
   refuse before adding a record. A completion report cannot be erased to
   resurrect the step and cannot infer verification or acceptance.
4. Competing real processes cannot commit two distinct commands at the same
   revision. Busy state is bounded; a later healthy read recovers the same
   preserved bytes. Reads must not create writer state or repair evidence.
5. Empty, partial, malformed, unsupported, duplicate, gapped and wrong-predecessor
   history remains unavailable. Preserve both the rejected bytes and the actual
   subprocess result. Distinguish a controlled torn-write fixture from an actual
   process crash and from untested power-loss durability.
6. An immutable checkpoint matches its exact event prefix and projection.
   Missing, substituted, corrupt, wrong-run or conflicting checkpoint identities
   fail. Checkpoint state cannot replace source events or forge acceptance.
7. File-type, private-mode, single-link and opened/named identity constraints
   refuse unavailable storage promptly, including FIFO and symlink negatives.
   Bounds do not become silent truncation, repair or evictions.
8. Existing proposal policy and UI reducer behavior stay intact. Storing a
   proposal or historical reference grants no route, approval, launch or lease.

Run the maintained repository scripts on unchanged source when the local build
slot is available. Report selftests, Python contracts, XCTest, optional skips,
release/package and actually executed hosted steps separately. A full build
cannot substitute for the distinct-process storage and negative controls.

No installed/operator app, home/default state, provider session, account,
credential, model default, entitlement, quota or paid provider call belongs in
this experiment. No mounted API, runtime launch, task/UI lifetime extraction,
provider recovery, live source truth, scheduler or end-to-end journey is claimed.
Hostile same-user custody, power loss and atomic filesystem transactions remain
outside the bounded claim.

The [owner index](orchestration-run-owner.json) is outcome-bearing material for
post-oracle review only. Fresh independence remains a separate gate; inherited
owner context and finite green tests do not satisfy it.
