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

## Maintained owner execution

The source was frozen at head
`474022628dacd20bb3c5508691648a56463433f6`, tree
`ea7d872105e93788dbdc72b2e876e0a254f5d6ef`, before maintained owner execution.
The completed native runs used the actual Xcode toolchain with an explicit
macOS 13 target and SDK 26.5. All 352 tracked source files and the two exact
dependency checkouts matched the input freeze before and after every gate.

The 20 maintained lexical XCTest methods executed with no failures or skips.
The complete selftest passed 548 checks, the Python repository contract suite
passed 10 tests, and the complete native XCTest suite executed 646 tests with
zero failures and three explicit provider skips. Those skips leave installed
OpenCode authority, persistence and shell correlation qualification **NOT_RUN**.
They are not provider success evidence. Existing compiler warnings remain in
the physical traces.

The first release executable and resource bundles were physically copied and
byte-verified before the unchanged package script ran. Release and package
producers both completed their actual waits with exit zero. The retained raw
executable is SHA-256
`2f9d8a25df4a9e5ad2852caa153c1318a8936f4127a12d83644d3f95a9ee45c1`;
the retained package executable is
`92f30269716a44cf233d617a345f000f36048780a7fe665c4985bec82c702e07`.

A separately frozen, path-only adaptation of the established V7 artifact
protocol passed for these exact artifacts. It compared all 41 section headers
and contents, recomputed 6,637 release and 1,660 package code-page hashes,
verified package plist/resource special slots and actual strict native
signatures, and checked 25 resource files including both resource bundles.
The observed package minimum OS is 13.0 and SDK is 26.5. The comparison masks
only three declared signing header fields before comparing the remaining
pre-signature body. Entire original binaries and signature regions remain
retained. Opaque signature suffix semantics, authenticated publisher identity,
general normalization and source provenance remain unknown.

| Maintained owner receipt | SHA-256 |
| --- | --- |
| Input/source/dependency closure | `b037d0e234a8890f00a6bd71a4dc28ad87c76da961675b881b7f571d8bc72de0` |
| Native oracle | `d8dc0ee716c68bb7c967a5af602a6c8b2d5fd6c401d30b1b5235c919ba00db10` |
| Focused XCTest execution | `7e3f5a51a041637c1f1732b21142c1848f81096b5da68e66a93e97a784bb2e64` |
| Complete selftest | `ae4b73eb73ef5638d035a5dba990190da9652f08d11f29a45f5e65c883e81b85` |
| Python contracts | `c088e612c4238501b9301f6efe0fb8dbcc474d2d192c8b8e2304fd7e635070fc` |
| Complete XCTest execution | `2a16eb9cebf10762639ad54ff1ef88ca3d20b0d6e2b896b88b840005c18515ff` |
| Release producer | `4b2a5ae8eb641c6228e49007a279b593295189304af7ff99db9dd93233028a4d` |
| First release byte custody | `cc833ccea369e2788b017b8e86fe7b5911b9d190177b0388b61024c0fe82b6a6` |
| Package producer | `2389bdd25eca9a31b790656f7e106657403f544295f6819b7c791ff5288603a7` |
| Complete package byte custody | `b788c1779ccbc471e1af780ceed2d67447c5dc8e2332c01fc52d04788e94508e` |
| Artifact oracle | `366271c31e80904bd771a5b4c432bcc1a156a213bfe1eb3f530c446c360d4f9d` |
| Artifact execution | `128fdc4d181e66394d20b5a9a9b41aae1bb19e28cafe15fe9ec0910439f5fc9d` |
| Bounded artifact result | `e97a22047a6fdc4ecf85a420d24ad15b1d311b0110c7c1897271cf61d17c1d73` |
| Native owner terminal | `e59047f3ce9e85350340958bdc49a1968c0bd158cdaf75e9363aee0871e86fe9` |

The first dependency-input copy refused borrowed Git alternates before test
execution. Its failure is retained; the successor copied exact bare objects
and made independent, no-hardlink checkouts with unchanged package pins and
verified canonical commit/tree/blob closure. A first inverse path-adaptation
preparation failure is also retained separately from artifact execution. Neither
failure was converted into a source/test pass. Complete source bytes, a Git
bundle, both original app artifacts and post-run test binaries are retained.
Per-test launch binary hashes and exhaustive fixture descendant/socket teardown
were not observed. Candidate-owned caches and temporary paths do not establish
complete installed-profile isolation.

## Pending acceptance

This is inherited implementer owner evidence and ordinary source-exposed
review. Fresh independent qualification remains **NOT_RUN**. Dependency or
exact whole-stack acceptance, governing review and branch policy are required
before promotion. Hosted CI is a separate first-publication gate; no hosted
execution or retry is claimed by these local receipts.

No app mount, MainFrame staged-entry composition, delivery, provider turn,
acceptance, operator mutation, installation, release or merge is established.
The source slice is reviewable owner work. The currently adopted source stage
and whole Context Compiler programme remain incomplete.
