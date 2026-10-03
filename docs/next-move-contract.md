# Next Move candidate contract

`NextMoveCandidate` is a derived, editable proposal in `ConduitCore`. The owner
authority is [#56](https://github.com/camerontjs-dot/Conduit/issues/56#issuecomment-5781072151),
adopted into [#60](https://github.com/camerontjs-dot/Conduit/issues/60#issuecomment-5781073008).
This stage implements the schema and deterministic fixtures. It does not generate
live suggestions or connect the composer, a provider, a route or a worker.

The candidate records a kind (`prompt`, `inspect`, `verify`, `handoff`,
`orchestrate`, `wait`), editable text, a reason, consulted sources/rules, support,
obligations, generation time and input-state identity. Its existing
`AgentContextItem` and `ContextInclusionReason` values retain source locator,
revision, freshness and authority labels. A consulted MindGraph nomination stays
a nomination. Inclusion and support do not establish source truth, model
eligibility, capability or objective acceptance.

The input identity separates project, task, supervisory snapshot, Context
Manifest and repository identity. The snapshot identifier is caller supplied.
This type does not create authoritative supervisory state or inspect current
state. The caller must supply a current identity to `assess`; the eventual live
feed must derive it from qualified owners. Equal identifiers are not a proof of
their authority. Optional absent context/repository fields are not a claim that
those dependencies are satisfied; required missing evidence belongs in explicit
obligations.

Assessment produces `reviewable`, `unknown`, `blocked`, `stale` or `invalid`,
with all reasons, support and obligations retained. Unsupported schema, malformed
target/explanation and duplicate source/obligation identities are invalid.
Changed state or explicitly stale sources mark the suggestion stale. Missing
current state, missing snapshot/source revisions, unknown source freshness,
unknown support or unknown obligations remain UNKNOWN. Missing or blocked
obligations prevent review readiness and retain independent UNKNOWNs. Generation
time never substitutes for a current-state identity or refreshes evidence.

`reviewable` means ready for operator review. It grants no approval, route,
writer lease, message delivery, task creation or launch. Same-thread prompt and
verification text may become an editable composer draft in a later integration.
Handoff/orchestration requires the existing `OrchestrationProposal`; inspection
or verification may also stage one when they imply new work. A staged proposal
must match the project and then pass normal proposal/policy/routing gates. The
existing policy can refuse a reviewable candidate's staged proposal. No API in
this contract executes either representation.

Editing produces a new revision while preserving the original derivation and
generation time. Canonical encoding sorts object keys, preserves array order
and uses an explicit millisecond date representation. The caller supplies the
time; there is no clock or random identity default. Revision identity hashes
these structured bytes. Encoding failure yields no identity. Decoding rejects
unknown candidate fields, including attempted auto-send or authority grants,
and requires explicit support/obligation data. This is a typed representation
boundary, not an execution sandbox or general-purpose JSON security parser.

Portable tests cover roundtrip/revision identity, changed state axes, missing
and UNKNOWN evidence, malformed/duplicate identities, nomination labels,
new-work staging and existing policy refusal. Owner pressure controls must
retain raw input/output/exit bytes and process-level replay. These checks do not
establish independent qualification, mounted product integration, suggestion
usefulness, provider entitlement or a completed supervisory journey.

The next product stages are separately bounded: deterministic generation from
explicit obligations/rules, editable UI with explanations, qualified live state
and manifest feeds, and normal policy/launch composition. Optional model phrasing,
ranking and operator-history preferences are later conditional work under #56.
