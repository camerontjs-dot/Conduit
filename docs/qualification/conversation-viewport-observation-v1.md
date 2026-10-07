# Conversation viewport observation: qualification contract v1

Owner: #49. Programme coordination: #60. Class: standard engineering awaiting
independent mounted qualification. This contract does not grant merge authority.
The exact candidate head/tree and ordinary receipts belong in the PR's freeze
comment. Pin that immutable subject before qualification; do not use moving main.

## Bounded capability

The latest rendered answer document in the active runtime Conversation carries
an AppKit-backed probe. `ConversationViewportProbeView.sampleObservation()` samples
its current enclosing scroll clip and owning window on demand. The returned
`ThreadSeenObservation` is an ephemeral snapshot, not a cached live state. There
is deliberately no automatic consumer, persistence, timer or cursor advancement.
A future consumer must sample again; retaining a prior snapshot does not make it
current evidence.

The measured proxy is the final one-point strip inside the answer document's
layout bounds. The whole strip must be inside both the document's visible rect
and the enclosing clip view's visible bounds. No empty conversation-footer marker
or follow-latest setting establishes visibility. Missing/pending layout, missing
current source, wrong task and a stale rendered revision fail closed. Application,
key-window, visibility and AppKit occlusion flags are read from the actual owner.
Only a Conversation observation with all required flags and the exact latest
revision supplies the facts the existing pure seen-authority rule requires.

This does not establish gaze, reading, comprehension, provider completion,
waiting, response obligation or pixel-level absence of another window over the
tail. AppKit's `.visible` occlusion flag is a window-level fact. No seen cursor,
rail badge/count, provider/task authority or source log is changed by this slice.
Thinking-only/empty answers and retired-history views are not positively observed.

## Qualification independence and custody

Use a fresh verifier who did not implement this candidate. Derive expectations
from this contract and the operator's requirement before inspecting implementation
reasoning or owner outcomes. Record the actual separation; do not claim a clean
room merely because another terminal or model is used. Freeze the independent
oracle, fixture text, case order, bounded waits and apparatus source before the
first decisive mounted measurement. Owner-generated tests are regression evidence,
not an independent oracle.

Record candidate commit/tree, all consumed source hashes, toolchain/SDK, deployment
target, build identity, exact commands/exits, fixture and apparatus hashes, window
and task identities, output revisions, measured rectangles, raw observations,
process ownership and teardown. Keep the first result for every attempt. Do not
repair the candidate, oracle or apparatus inside the frozen campaign. A defect
requires a separately identified successor; a later run cannot overwrite failure.

Use one native slot, a separate source/build/cache root and a fresh distinct
application identity. Establish state, preferences, process, listener and fixture
ownership before instantiating application objects. Do not bootstrap the ordinary
Conduit app against operator state. Use synthetic output and no provider account,
network turn, tunnel, production installation or write-enabled operator endpoint.
Do not reassign HOME/CODEX_HOME as an assumed isolation mechanism.

If the exact real Conversation view cannot be mounted safely with the available
fixture seams, record `APPARATUS_BLOCKED`; do not patch its AppModel, borrow the
operator app or silently compose #123 into this candidate. A separately mounted
probe-only demonstration is supplementary and cannot replace the real Conversation
positive control. A composition has a new source identity and its own evidence.

## One bounded local campaign

1. **Source preflight.** Reverify the PR freeze, exact checkout and source hashes;
   ensure the allowed apparatus can mount the real Conversation view without
   operator-state access. Capture the independent oracle/apparatus freeze and
   native-slot claim. Identity or isolation failures stop dependent steps.
2. **Focused deterministic checks.** Run viewport geometry, revision identity,
   unseen-output and pure seen-authority tests. Include empty/nonfinite rectangles,
   exact edges, partial intersections and same-length same-event-ID text changes.
3. **Maintained native suite.** Run the repository's self-tests, Python script
   contracts and full XCTest suite. Report actual totals, explicit optional skips,
   exits and any incomplete/failed execution, not an inferred green result.
4. **macOS 13 build boundary.** Compile/build the actual UI for deployment target
   macOS 13 with a recorded compatible toolchain; inspect the resulting target and
   package/signature. A newer-host build does not establish macOS 13 runtime use.
5. **Mounted positive.** Display the latest synthetic output in the real Conversation
   ScrollView, with the app active and its owning window key, visible and AppKit
   occlusion-visible. Obtain the sample from that mounted document's actual probe,
   not injected geometry/window flags. Require a non-nil observation and exact
   latest revision. Cover cached and split-answer document paths, plus text growth
   and a new latest event. Save the actual rectangles and window/source facts.
6. **Mounted negatives.** With the relevant source facts independently confirmed,
   scroll the latest tail away; select Raw; deactivate the app; make the owning
   window non-key; hide it; fully occlude it; change output while retaining a stale
   probe/revision; and switch to a different task. No case may supply an authorized
   seen observation for the old/wrong revision. Verify each negative condition
   actually occurred, rather than changing a test boolean. Partial clipping must
   not count as full-tail visibility. Reappearance/revision changes require a fresh
   sample; an earlier positive may not be replayed as current evidence.
7. **Noninterference.** Check text selection/copy, scrolling and navigation, existing
   Conversation/Raw switching, source/runtime authority and protected state. Confirm
   there is no cursor file/write, rail badge/count, provider action or persistence
   caused by sampling. Compare the defined protected inventory before and after;
   do not expand that into an unsupported whole-machine noninterference claim.
8. **Postflight and teardown.** Rehash frozen source, close only owned windows and
   processes, verify owned listeners/processes are gone, preserve artifacts, release
   the native slot, and publish a bounded disposition to the PR/#49 with a #60 link.

## Disposition

`SUPPORTED_WITH_BOUNDS` requires all mandatory gates and real negative controls.
A reproduced false-positive visibility or revision/task mismatch is a product
failure. Missing mounted access, an invalid fixture, unconfirmed occlusion or an
unavailable deployment target is an apparatus/environment gap, not a pass. Retain
`NOT_RUN` for dependent checks that did not execute. Do not start seen-cursor
persistence until this mounted observation slice has a recorded bounded disposition.
