# Lexical context candidates

`ContextLexicalSourceAdapter` composes existing Find with the exact-file source
adapter for #58/#60 Phase A. It is an additive dependent Core slice on frozen
#140 (`6541d27aa4c303442afcc263c73fa12a5ae40f24`, tree
`c3a58f5b609aff1cfe2e090a2618046033c50d96`). Find, the source reader, #108's
compiler and the snapshot store remain unchanged.

The caller supplies one cached `MainframeContentIndex`, a local file root and exact
query bytes. Discovery invokes `MainframeTextSearch`; it does not build an
index, scan files, call a semantic provider, infer objective paths or choose
sources. Index declarations are input evidence, not filesystem authority.
Remote-host file URLs are refused rather than labeling a local-path read with
an unobserved remote authority.

```swift
let adapter = ContextLexicalSourceAdapter()
let nominations = try adapter.discover(
    index: suppliedIndex, root: selectedRoot, query: "launch handoff"
)
// An operator or authorized caller chooses exact IDs from this batch.
let selection = try nominations.select([
    ContextLexicalSelectionItem(nominationID: chosenID, lineRange: 4...8)
])
let observed = try adapter.expand(
    batch: nominations, selection: selection,
    root: selectedRoot, query: "launch handoff",
    requiredRequests: [
        ContextFileSourceRequest(relativePath: "AGENTS.md", origin: .requiredContract)
    ],
    observedAt: Date()
)
let set = try observed.makeContextSet(id: "review", objective: "Review launch handoff")
```

Discovery rejects unsupported limits, unsafe or duplicate byte-identical paths,
inconsistent names, text-byte counts and aggregate counts. Markdown headings
and frontmatter are reparsed from cached text rather than accepted from a
supplied projection. Path-derived navigation hints are rebuilt; they are not
lifecycle-record authority. UTF-8 path and query spellings remain separate even
when Swift considers two Unicode strings canonically equivalent.

Nomination IDs hash structured fields: the cached-input snapshot, declared root,
query, path, cached-text SHA-256, hit kind, line, score and preview. The adapter
uses Find's returned candidates, supplies stable byte ordering for input ties
and orders retained hits structurally. It does not replace Find's matching or
ranking. The matching still uses Foundation's locale-sensitive behavior; no
universal cross-locale retrieval claim is made. The digest is a discriminator
for a subsequent full-source observation, not a Git blob or perpetual freshness.

Each batch has a separate active generation. Selection is explicit; no selection
produces no source observations or delivered entries. Unknown or duplicate IDs
are refused. A selection from another generation, or relabeled root or query,
is refused before reading. Stable IDs alone remain references; selecting them
again creates a new explicit choice in the new batch. Encoded batches and
selection tickets do not conform to `Decodable` and have no public constructors
that rehydrate read authority. Repeating a ticket against its own unchanged
batch may observe again; it is not a durable delivery or replay ledger.

Only selected IDs become exact-file requests. A selected pin becomes an explicit
operator-pin request. Other objective, pin and required-contract requests pass
through the same strict batch. The unchanged reader physically observes bounded
current bytes, requires cached-text digest equality for selections, refuses
links and unsafe paths, and detects its exercised mutations. Search previews
may be trimmed or compacted. Full source or explicitly ranged bytes always
come from the physical read, with separate source and representation digests.
The observation timestamp is caller supplied; later freshness remains unknown.

Observed entries retain filesystem source authority, exact-identity reasons and
their original disposition. Lexical reasons refer to the selected nomination
IDs. Existing compiler deduplication unions those reasons with objective,
explicit-expansion, pin and contract reasons. Pins are preferred before equal
strength deduplication so they remain pinned and mandatory. Unknown destination
budgets and hard-context conflicts use the unchanged compiler's states.

Coverage distinguishes supplied-index truncation, skipped non-text or oversized
records, result clipping and Find's three-content-hit-per-file cap. One extra
Find result exposes the result cap. Matching-line counts expose the existing
per-file cap without supplying candidates. Explorer's excluded components
remain listed. These are bounded cached-text facts, not whole-corpus absence or
exhaustive filesystem discovery. Limits bound representation and work inputs;
they are not measured peak-memory or performance guarantees.

Partial discovery prevents a complete handoff, including an empty partial
search. An unresolved selected or required request also prevents handoff.
Successful observations and failed requests remain inspectable independently;
available rows cannot silently become a complete Context Set. No provider input,
turn, execution or acceptance occurs here.

## Remaining source stages and promotion

This candidate supplies lexical nomination and explicit exact-source expansion.
Authored links/backlinks, Git changes/conflicts/untracked files, artifacts,
qualification receipts, PRs/issues, prior snapshots and task/runtime/lifecycle
records remain adopted source work. It does not satisfy MainFrame's upstream
staged-entry gate or the mounted Context Set lifecycle/UI composition.

Owner fixture evidence covers actual index/search/read/compiler composition and
negative controls. The maintained XCTest suite and public selftest parity keep
those predicates reviewable. Full maintained native, release/package and hosted
gates remain distinct from small standalone evidence. Fresh qualification of
#140 or the exact whole stack, governing acceptance and branch policy are
required before promotion; inherited implementation tests establish no useful
independence. A dependency defect returns as a named successor rather than a
repair to frozen #140, Find or #108. D-075 remains Proposed/T0.

> **Binds:** consideration of the additive lexical adapter in #58/#60 Phase A.
>
> **Tier:** T0, proposed architecture guidance.
>
> **Check:** deterministic tests and owned physical traces check the exercised mechanics; acceptance, mounted behavior and useful independence remain separate.
>
> **Escape:** preserve partial/refused observations and unavailable prerequisites without weakening the source or promotion boundary.
