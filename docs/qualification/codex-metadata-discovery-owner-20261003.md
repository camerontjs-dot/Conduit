# Codex metadata discovery: owner evidence

The #53 Slice 2 candidate can list and read allowlisted Codex session metadata
through an existing ready Conduit app-server host. Observation does not start a
host, resume a thread, send input, adopt a writer or consume an execution slot.
Real-provider external-thread acceptance remains UNKNOWN.

The [machine receipt](receipts/codex-metadata-discovery-owner-20261003-v1.json)
has SHA-256
`883453550b203e485badb2c6c1ba2d10b4204689e55f9b0702c067b38a3490eb`.
It records exact source identities, test counts, source inventories and hashes
of the retained physical owner evidence. The governing surfaces are #53 Slice
2, #49 and #60. D070 remains Proposed / T0.

## Tested source and preserved lineage

The base is `d10ec1c90c835e8b210a4e27e7333fd8e436bd7a`, tree
`d76aa2957d69b86b3eb2f7b17cbd5d5abfdea010`. The latest tested source is
`20d02b09c14d4cb075632d56284192ea59b67c24`, tree
`149127567afddd04ee6605a924b3e1f3abfd3e3d`. A later receipt-only commit must
preserve every tested Sources, Tests and scripts byte; its final identity is
recorded separately on the PR and #53.

Two source predecessors remain in the branch history:

- `c54f76037a82fb93122950ba8db412fd8e8fba6b` passed the focused metadata
  tests, then failed three existing catalog description assertions. The
  successor restored the required safety wording without changing those tests.
- `a3aa0126f915b576a4a33b2ce3946e94e30f228d` passed the component/native
  checks, then failed a separately frozen host-identity discriminator. An
  unloaded external thread inherited the answering host as its canonical
  worker host. The latest successor retains the query host as observation
  provenance and leaves worker-host identity UNKNOWN unless exact loaded-list
  membership supplies that fact.

The original exact-main namespace regression also reproduced a driving-thread
effect from a metadata reply. Its first fixture inspected a delivery batch too
early and is preserved as APPARATUS_INVALID. The corrected frozen oracle and
fixture reproduced the defect on exact main and passed unchanged on the latest
successor. The first host-identity failure stopped downstream pressure; its
unchanged oracle passed on the separately identified successor.

## Observed owner checks

`scripts/test.sh` physically ran 476 selftests, 10 Python contract tests and
616 reported XCTest cases with zero failures. Three real-provider opt-in cases
were explicitly skipped; 613 cases ran without that skip. Thirteen new metadata
XCTest methods and matching selftest checks cover exact identity, allowlisting,
bounded pagination and namespace separation.

The maintained Codex client also passed 18 actual native stdio scenarios against
owned fake app-server processes. These cover healthy/external metadata, unknown
and shortened identities, duplicate IDs, cursor cycles, page limits, malformed
metadata, malformed loaded lists, unexpected turn content, wrong/stale reads,
RPC errors, wrong envelopes, expiry, cancellation, host stop and pending-request
capacity. Normal observation cases preserved the driving thread, turn,
approval, error and output effects. The host-stop case deliberately stopped its
own fake host and tested refusal. All 17 fake provider PIDs were observed gone;
the no-host case created none.

Fake setup creates synthetic thread/turn state solely to pressure the real
client's boundary. It invokes no model. Observation-phase wire receipts contain
only metadata reads, plus one fake rate-limit read used to show that metadata
expiry does not cancel a driving request.

The release package built successfully. Strict deep signature verification,
macOS 13.0 minimum, 23 sprite asset byte comparisons, icon comparison and the
SwiftTerm shader resource check passed. The compiled release selftest passed
476 checks. The package was neither installed nor launched.

The observed machine runs macOS 27.0. The installed Swift 6.3.3 toolchain
defaults standalone compilation to macOS 28.0, so native fixture compilations
explicitly target macOS 13.0. The initial SwiftPM sandbox refusal is preserved
as a pre-test apparatus limit; subsequent scoped owner execution was approved.

## Authority and remaining gates

Installed Codex 0.154.0 generated schemas supplied protocol authority for
`thread/list`, `thread/loaded/list` and `thread/read`. Listing uses
`useStateDbOnly: true`; reads use `includeTurns: false`. Preview, title, rollout
path and turns are withheld. Configured or latest persisted model metadata
does not establish per-turn execution or entitlement. Provider-loaded status
is scoped to the answering host and observation time.

The `conduit.observation.v1/` request namespace prevents observation replies,
errors, late/duplicate deliveries and namespace-misusing requests from entering
the driving mapper. This bounded change does not qualify the separate generic
RPC authority lineage in #114/#128.

Native compilation connects the bounded asynchronous metadata path through
AppModel and the existing Session API callback. Mounted behavior is an
inference from source, not an executed HTTP journey. Listener exposure, write
gates, authentication, model defaults and provider routes retain their existing
boundaries; #47 is not implicitly adopted.

Fresh independent qualification requires an authorized unexposed context.
The source-exposed owner checks do not supply it, and private-source external
CLI permission remains unavailable. Real-provider external-thread list/read
acceptance and the mounted #87-isolated AppModel/HTTP journey remain separate
gates. Hosted CI must be recorded against the exact final PR identity. No
merge, installation, production release, provider support or whole-programme
acceptance follows from this owner receipt.
