# Exact-file Context Compiler source owner receipt

This candidate advances #58/#60 Phase A C-A-SOURCES with physically observed
file candidates for explicit objective, selected, pinned and required-contract
references. It reuses the merged #108 compiler and snapshot representation.
It supplies no mounted app behavior or provider input. D-072 is Proposed/T0.

The adapter observes bounded regular UTF-8 files under an explicit root through
descriptor-anchored reads. It preserves full-source SHA-256 and represented
excerpt bytes separately, explicit reasons, hard pins and unknown later
freshness. Unsafe paths, links, changed/replaced/deleted files, malformed ranges
and byte-limit failures remain visible. Any unresolved request prevents a
complete Context Set handoff; the available subset cannot silently pass.

## Exact source and scope

- Base: `d10ec1c90c835e8b210a4e27e7333fd8e436bd7a`, tree
  `d76aa2957d69b86b3eb2f7b17cbd5d5abfdea010`.
- Tested source: `92e4b6fca9574aa1af82589322c7d465f3c80e26`, tree
  `e31d099ef483eed62584ba34ad4fb518b12349ed`.
- This report and [candidate manifest](issue58-context-exact-file-candidate.json)
  are a subsequent metadata-only commit. The publication receipt and PR carry
  its exact final head/tree; source hashes remain bound to the tested commit.
- Main subsequently moved to `7512943469f2f2c65b268fe9db542c6a46908fbf`, tree
  `e95d4b114034717b7dc8d68212a5b2cec85e303b`, through docs-only #139. Direct Git
  comparison confirmed all 244 source/test/script/Package objects unchanged.
  The original candidate was not rebased or repaired.

The unchanged compiler, compiler tests, snapshot store/tests, AgentContext,
Explorer source and Package files are hashed in the manifest. No parallel
Context Set authority was added. Frozen #132 remains a separate lifecycle
candidate. The source-stage inventory in [Exact-file context candidates](../context-exact-file-sources.md)
keeps lexical/Git/link/artifact/receipt/PR/issue/prior-snapshot and record adapters
visible as adopted actionable work. MainFrame staged-entry consumption retains
its upstream gate. This slice does not complete Phase A or the whole compiler.

## Physically executed owner gates

The owner had inherited implementation context. These results are bounded
owner evidence; none is independent acceptance.

| Gate | Observed result | Receipt SHA-256 |
| --- | --- | --- |
| Legacy supplied-reference gap with changed owned file bytes | GAP_DEMONSTRATED; no exact-byte identity in the reference-only path | `fa880a8421c12e92531580eb368c7cb69ecbead1ebb26a16cb03f716cb1ec4da` |
| Standalone native physical pressure v3 | 57/57 OWNER_PASS_BOUNDED; explicit macOS 13 target | `96ed65545291bdfa504b7150ffb2793927a9e210130d68210dd1f02b741cf6dd` |
| Focused maintained XCTest | 23 tests, zero failures | `728b48479208d36b6ef1d41846ae8fded7c3adbc68a90345bf99f0e9afb78e34` |
| Maintained public Core selftest | 502 checks, zero failures | `2aa6179558ace4c5317ebc4a28f0683191db371d7c7a14d867ebdfeb2717c9ad` |
| Provider-conformance Python contracts | 10 tests; no provider invoked | `1628db9199f14787c7fccc55e2c25eed394b3cef35c3bc6304e4b7acd2741221` |
| Full maintained native XCTest v5 | 626 tests, three optional installed-fixture skips, zero failures | `21b320568966d81dfe483ae56bfa5e9f7618f1608f7147192861233c54ec0253` |
| Native release and uninstalled app package | Build, resource copy and strict ad hoc signature passed | `d34c6cc3297831c7a8c224dd2cb3225dfa2a2456ef76d3eea66788b527f3040c` |
| Bounded package identity v7 | 41 equal sections; all 8,214 declared CodeDirectory page hashes recomputed; exact Info/Resources hashes, 25 resources and native strict signatures | `4423c223275ab149d6af51b8773a5b0b6374685662298bf1d8a69829a2dcee7c` |

The signed app executable SHA-256 is
`71d32abc667bcad95ffc35bdd1e1ce198fb09e3632d6f68254f34c1cc97d578a`.
The linker-signed release executable SHA-256 is
`ab91770e5c1abc049cfa5f6e047f2d7d95ccc5c6fd5e7fcc1e04b27db0cfba30`.
The package has minimum macOS 13.0 and SDK 26.5. It was neither installed nor
launched. Physical pressure includes same-length in-place changes, truncation,
delete/replacement, ancestor/root changes, link substitution, failed-read budget
debits, exact ranges, collision controls, reason union and descriptor teardown.

## Preserved failures and apparatus deviations

The first standalone driver failed compilation because it read a nonexistent
manifest-entry member. Its source/error bytes remain preserved; a named driver
successor used the actual API without changing the acceptance boundary.
The v2 and v3 source/protocol/result identities remain distinct.

Native attempt v1 failed DNS before tests. v2 failed because an existing public
cache had incomplete unrelated ancestry. A named selected-commit shallow
mirror successor contains the exact unchanged dependency pins, complete selected
tree/blob closure and copied object hashes. Canonical GitHub Git-data commit/tree
and the exact `1.8.2` tag were checked; this establishes no full-history claim.
The old mirrors and failed config remain preserved. Package files were not
changed, and frozen #132's cache was read only. Transport/ref-resolution differs
from an ordinary online dependency clone; dependency source identity does not.

The maintained wrapper v3 failed at `sandbox_apply` before suites. Its named
apparatus successor ran the same three suites directly with SwiftPM sandbox
disabled. Full XCTest v4 physically failed an owned Unix socket bind with
`EPERM` plus its consequent unwaited expectation. Under the scoped unsandboxed
v5 retry, the same 626 tests passed with no source or oracle changes. Treating
v4 as an environment restriction is an inference supported by that exact retry;
both native failure traces remain evidence. Provider opt-ins were absent.

Package verifier v6 failed raw whole-file equality: bundle signing changed the
executable. That comparison remains FALSE and both original artifacts are
preserved. Before execution, v7 froze the established bounded Mach-O/CodeDirectory
protocol with these exact inputs. It allows only three declared signing fields
and the signature region to differ, checks all section/body bytes and page
hashes, verifies Info/Resources and native signatures, and confirms originals
unchanged. Opaque signature suffix bytes remain exact evidence with semantics
UNKNOWN. This is not a general normalization, publisher-authentication, source
provenance or tamper-authenticity claim. No signature stripping or package repair
was performed. The [manifest](issue58-context-exact-file-candidate.json) retains
every negative receipt and the dependency and package protocol identities.

## Disposition

OWNER_PASS_BOUNDED for this exact Core adapter and its physically executed
native/package boundaries. Fresh independent qualification is NOT_RUN pending
private-source transfer/launch authority. Hosted CI is NOT_RUN at metadata freeze
and will be reported from actual candidate runs on the PR. Mounted product
composition, other adopted source stages, runtime delivery, source authenticity,
permanent freshness and installed-app behavior remain separate or UNKNOWN.
The Draft is not authorized to merge from these owner checks alone.

> **Binds:** interpretation of these exact owner receipts and candidate identities.
>
> **Tier:** T0, advisory evidence boundary.
>
> **Check:** source/native/package receipts establish their executed behavior; they do not enforce independence or governing acceptance.
>
> **Escape:** pending gates stay NOT_RUN while other adopted source work continues.
