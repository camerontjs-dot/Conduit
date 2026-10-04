# Context delta identity comparison

Owner: [Context Compiler #58](https://github.com/camerontjs-dot/Conduit/issues/58);
programme row C-D-DELTA in [#60](https://github.com/camerontjs-dot/Conduit/issues/60).

## Problem and scope

The existing differ groups items by stable item ID, then compares a public
delimiter-separated fingerprint. Caller-supplied source references and revisions
can contain that delimiter. For the same item ID, these two distinct identities
both produce the fragment `a|b|c`:

| Source reference | Revision |
| --- | --- |
| `a|b` | `c` |
| `a` | `b|c` |

With otherwise identical identity fields, the previous differ reports no
change. The new differ compares kind, authority, source reference, revision,
line range and freshness separately, so it reports one changed item.

The public `identityFingerprint` property keeps its representation for
compatibility with callers. It is a legacy display representation and cannot
establish a unique source identity. Stable item ID matching and sorted result
order remain unchanged. Title, token estimate and pin changes remain excluded
from source identity changes. Absent and empty revisions keep their existing
equivalence.

This is a bounded repair to an existing comparison. It adds no source authority,
new Context Set store, retrieval policy, automatic admission, or UI caller.
Duplicate stable IDs remain a separate source-review pressure case; this change
does not choose a new duplicate policy.

## Candidate basis and evidence limits

The parent is maintained Conduit main
`b53c38ed303b2a6e7fb4de8936c04ed56da891ed`, tree
`3308565e9fbc35f8541911cea9a38b4e1b251260`.
The original `Sources/ConduitCore/AgentContext.swift` Git blob is
`2761cd4d8d2808ad22ca6e7991b29001b502dc3a`.
Its bytes were checked against that identity before editing.

Six authored XCTest methods and matching self-test checks cover the collision,
each existing identity field, unchanged presentation exclusions, absent/empty
revision compatibility, stable-ID addition/removal and deterministic ordering.
These are implementation-aware regression checks, not independent acceptance.

No Swift compiler or macOS runtime is available in the authoring environment.
Compilation, XCTest, self-test execution, full maintained native tests and
mounted handoff behavior are **NOT_RUN**. Source inspection and a portable
calculation establish the delimiter collision; they are not a native red/green
execution claim.

## Local verification

On the frozen published candidate, use the established owned native test
environment and preserve actual commands, process waits and first results:

1. Run `swift test --filter AgentContextIdentityDiffTests`.
2. Run `swift run conduit-selftest`, including the registered identity checks.
3. Run the maintained `scripts/test.sh` gate on the same exact candidate.
4. After explicit composition with the Context UI source stack, verify that a
   retained snapshot and proposed handoff containing the collision report a
   changed item without changing context membership or sending a prompt.

The current source is separate from the frozen #140/#148 adapter stack and
local authored-link candidate. Later composition must name its own head/tree
and applicable qualification. A failing frozen candidate returns its receipt
for a successor; it is not repaired during qualification.
