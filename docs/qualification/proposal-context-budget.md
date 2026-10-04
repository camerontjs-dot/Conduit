# Proposal context budget refusal

This candidate repairs arithmetic at the existing `OrchestrationContextPacket`
validation boundary. It is part of the proposal/context contract tracked by
[#4](https://github.com/camerontjs-dot/Conduit/issues/4) and
[#56](https://github.com/camerontjs-dot/Conduit/issues/56).

## Source finding and change

At base `b53c38ed303b2a6e7fb4de8936c04ed56da891ed` (tree
`3308565e9fbc35f8541911cea9a38b4e1b251260`), the public `tokenEstimate`
accessor adds caller-supplied `Int` values with ordinary addition. The validation
method calls that accessor. Individually decodable, labelled counts
`[Int.max, 1]` therefore exceed the representable sum before validation can
return a reason. This is a source-derived finding. A native reproduction on the
base is **NOT_RUN** in the GitHub preparation environment.

The successor uses checked addition and emits an explicit validation reason for
an unrepresentable total. The public `Int` presentation accessor retains its
type and exact representable results; on arithmetic overflow or underflow it
returns `Int.max`. That fallback is not a valid total or an admission decision.
`validationReasons(maximumTokens:)` independently rejects the invalid total,
including when the maximum budget is itself `Int.max`.

Source entries are not rewritten, dropped or normalized. Negative entries
continue to fail the existing entry-label validation even when their summed
value fits the budget. An invalid prefix cannot become valid because a later
negative or positive term would correct its mathematical sum. An empty packet
with a negative budget continues to produce the existing over-budget refusal.
Ordinary nonnegative totals and exact budget boundaries are unchanged.

No proposal, approval-token, routing, provider, model, task or launch authority
changes. The existing Orchestrate Start button remains disabled. This repair
does not supply an MCP proposal-preparation endpoint or make a context packet
independently verified.

## Local verification packet

The candidate has eight `OrchestrationContextBudgetTests` XCTest methods and
eight matching checks registered before the maintained SelfTest summary:

| Case | Required observation |
| --- | --- |
| `Int.max + 1`, maximum budget `Int.max` | Explicit range refusal; no process trap; policy needs revision |
| Codable round-trip of `[1, Int.max]` | Counts and packet identity retained; same refusal |
| `[Int.max - 1, 1]` | Exact `Int.max` total remains valid at that budget; lower budget refuses |
| `[-1, 2]` | Representable total stays `1`; negative source entry still refuses |
| `[Int.min, -1]` and reversed order | Explicit range and negative-entry refusals; source unchanged |
| Overflow/underflow followed by an arithmetic correction | Invalid range and entry remain visible; no cancellation into validity |
| Empty packet, budget `-1` | Existing over-budget refusal |
| Empty/zero packet and ordinary `40 + 30` | Existing zero and exact-boundary behavior |

On a verified exact checkout with the established owned native build/cache
apparatus, run `./scripts/test.sh --filter OrchestrationContextBudgetTests` and
then the applicable maintained full native gate. The first command also runs
the maintained SelfTest and Python contracts. Keep the actual argv, command
working directory, build/cache roots, process wait/exit and full logs. No provider
fixture, app launch or operator state is needed for the focused Core cases.

If a base crash reproduction is useful, use a separately identified probe and
separate process against the exact base; retain its failure before testing the
successor. Never patch the frozen base to obtain a green comparison. The source-
exposed regression suite is owner development evidence, not a fresh independent
oracle. Freeze any independent test plan before exposing this document or the
candidate source to its author.

## Current evidence

GitHub preparation verified the three edited originals by base64 decoding and
Git blob SHA, checked the bounded diff, and checked that all new SelfTest calls
precede the summary. Swift/XCTest/SelfTest execution, native base crash
reproduction, release build and fresh independent qualification are **NOT_RUN**.
The candidate stays Draft until its applicable gates are satisfied.
