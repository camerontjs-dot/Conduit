# #58 lexical source owner checkpoint

This checkpoint records inherited implementation evidence for D-075. It is an
additive stack on frozen #140 head
`6541d27aa4c303442afcc263c73fa12a5ae40f24`, tree
`c3a58f5b609aff1cfe2e090a2618046033c50d96`. It does not accept or supersede
#140. The unchanged #108 compiler and snapshot store remain their source owners.

The new Core adapter composes actual cached Find with explicit selection and
actual exact-file reads. Source hashes at this checkpoint are:

| File | SHA-256 |
| --- | --- |
| `ContextLexicalSourceAdapter.swift` | `8210d5c04b0830f6b27d4d26c47255d88ce5bd2d03291ace60c6a46a30f7a3cb` |
| `ContextLexicalSourceAdapterTests.swift` | `80103d6178e8e9913ca9870dc75f40cfa06ab6eab3ba477b2ea6c0ba0dd77ab7` |
| `ContextLexicalSourceChecks.swift` | `4b96f66a91f4672d1a3e3c64c2017960a40e458580f5dae7732920175ed28bb5` |

## Observed owner evidence

Predicates were frozen before source edits. The physical baseline invoked
existing index/Find and the #140 reader: cached hits survived a same-length
file change, the old Find result cap supplied no clipping flag, and the exact
reader refused the stale cached digest. These are composition gaps; the
baseline does not claim Find itself is defective.

The revised standalone protocol compiled a small module from the actual
maintained Find, Markdown parser, Explorer, source reader, compiler and lexical
adapter files, with explicit `arm64-apple-macos13.0` target and an observed Xcode
SDK. It typechecked the 20 maintained lexical XCTest methods through the actual
native XCTest Swift overlay. It did **not** execute XCTest.

The same protocol physically ran 46 public-API parity checks and four owned
between-read-pass write, replacement, deletion and link-substitution controls:
50 passed, zero failed. The mutation controls preserve actual failure
projections, interposition counts and cached source digests. Their exercised
observations remain negative; no stable source snapshot is admitted.

The public checks cover actual index/search/read/compiler composition, no
selection, compact preview versus exact bytes, same-length after-index changes,
deletion, missing hard references, pins and reason union, explicit ranges,
unknown/conflicting budgets, stale/foreign selection generations, exact root
and query identity, result/per-file clipping, partial/skipped indexes, malformed
records, unsafe paths, forged headings, Unicode and delimiter identities,
deterministic manifests and local-root-only URL admission. They use owned files
and supplied cached records; they do not access a live corpus or provider.

Three additional native compile controls deliberately attempted to decode
selection, nomination and expansion receipts into active adapter types. Each
was refused for its exact missing `Decodable` conformance. This proves only the
compiler-enforced public import boundary, not a generic authorization or
tamper-authenticity claim.

| Receipt | SHA-256 |
| --- | --- |
| Frozen owner predicates | `fc539fd3011a91225391e79d418048b2f79787a5bbdd312cba37b50da03bb4bf` |
| Physical baseline v2 | `b4ebc3fd3ea92a800885628662394b86aff31d03e46b7d99f083264e90716354` |
| Revised pressure protocol v5 | `8ed71bf7786100f2076c2577056378e3c962f3e6f02251ebf95c9fcafc45a72d` |
| Revised pressure execution v5 | `cc304794b960fec7e8116c0d9e1346e1c710c6e850809b0a4f905c4ea476f564` |
| 50-check result v5 | `86855b2089090d21cd4fd0e9c04e9de4e6465af6a0504331d5e8bcde207f9010` |
| Physical mutation projections v5 | `4cafe91eb42ab4ac6a1d565c9368066df557054cf4016dfde25f14c3f03eced9` |
| Revised receipt-import protocol | `60be5a43ff49f447b4b0b8f3a3ed2bc49a6e6fb90dcbd2d28e0d214f057e5906` |
| Three expected import refusals | `bcdf1c1ff2187cafd714399315fd289aceff23ec9059e65824859f3214f83691` |

Raw machine receipts and fixtures remain in separately authorized local evidence
custody. This public checkpoint carries identities and bounded claims rather
than private machine paths or inventories.

## Preserved failures and environment deviations

The first baseline preparation used an incorrect parser filename and stopped
before compilation. Its named successor used the observed maintained parser
files. The first restoration attempt failed DNS resolution before cloning; a
scoped public clone then restored the exact dependency into a separately named
checkout. Earlier temporary checkouts were absent; their disappearance cause
remains unknown. Historical raw baseline artifacts were still physically
available. Earlier identities are not reused as current checkout availability.

The first standalone XCTest apparatus compiled Core but failed to expose Swift
assertions because it selected only the Objective-C framework. Its first
failure and downstream non-execution are retained. The revised apparatus
typechecked XCTest with the observed Swift overlay and physically ran the
separate parity/pressure driver. It does not replace required maintained XCTest
execution or claim the failed apparatus passed.

An ordinary source review then found that a remote-host file URL could label a
local-path observation. The new lexical boundary now refuses foreign URL hosts;
the unchanged #140 reader is not repaired here. The failed reviewed source
identity and inference are retained without a remote or mounted reproduction
claim. The earlier 49-check result remains evidence for its earlier source,
separate from the revised 50-check source.

## Pending acceptance

Maintained full selftest, native XCTest execution, repository contract suite,
release/package/signing/resource checks and hosted CI are **NOT_RUN** for this
checkpoint. Their queued execution is a separate gate. Fresh independent
qualification is **NOT_RUN**; this inherited owner context is ineligible to
self-qualify useful independence. Dependency or exact whole-stack acceptance,
governing review and branch policy are required before promotion.

No app mount, MainFrame staged-entry composition, delivery, provider turn,
acceptance, operator mutation, installation, release or merge is established.
The source slice is reviewable owner work. The currently adopted source stage
and whole Context Compiler programme remain incomplete.
