# MindGraph repair 88: assembly and qualification

Status: implementation kit; integration assembly pending. Not a qualified or
fully assembled app candidate.

Owner: #88. Context lane: #58. Producer: camerontjs-dot/MindGraph#28.
The failed #86 head remains `ece4a68cfc41cc89a81341991e8a58dc3bd12c83`.
Its receipt remains authoritative for that object:
https://github.com/camerontjs-dot/Conduit/pull/86#issuecomment-5851516748

## What is present

- `MindGraphExpansionBinding.swift`: independent exp2 request/response identity
  validation. The original query alias must match the selected route before
  any expansion process is invoked. Returned handle, stored index identifier,
  document, chunk, path, namespace and known hash must match the locator.
- Core regression vectors generated from the producer's canonical format,
  including Unicode, same-trust collisions, malformed identity, missing fields,
  contradictory responses and output allowlisting.
- Regression tests against the authoritative `ConduitSessionToolCatalog`, not
  the unused server-local definitions.
- SelfTest parity checks and an opt-in populated AppModel inspection test.
- `tools/repair88/assemble.py`: the complete remaining integration edits with
  exact input blob guards. These edits are authored, but not applied in this kit.

## What assembly changes

The assembler modifies exactly seven existing files:

1. `Sources/Conduit/AppModel.swift`: supplies an explicit query scope alias,
   validates the original expansion request before process launch, checks the
   raw producer response independently before returning text, and adds a
   debug-only isolated-home acceptance seam.
2. `Sources/ConduitCore/ConduitSessionToolCatalog.swift`: publishes expansion
   once with a matching schema/read-only annotations and corrects the query
   description to the compact contract.
3. `Sources/ConduitSelfTest/main.swift`: invokes the new parity checks.
4. `Package.swift`: registers the app test target.
5. `docs/qualification/provider-conformance-v1.json`: refreshes only the
   AppModel artifact digest after verifying the provider inventory/adoption
   functions and their OpenCode guards remain byte-identical.
6. `CHANGELOG.md`: updates only the Unreleased repair section.
7. `DECISIONS.md`: appends the D-058 repair addendum without rewriting history.

A conformance pin is not refreshed merely because a test failed. The supporting
provider-scope code must remain unchanged, the final source digest is computed
once at assembly, and the existing conformance tests still run normally. No
check or expected state is removed.

## Why this is an assembly kit

The available repository connector supports complete-file writes, not an
in-place patch operation. The remaining large AppModel edit could not be
safely materialized here. Rather than silently truncate or reconstruct the
whole private file, this kit carries guarded transformations against its exact
known blob. The same approach covers the related catalog and evidence pin.

The kit head is not the final executable candidate. New catalog/app tests are
expected to be incomplete until assembly. Do not report a qualification PASS
for the kit or conceal that distinction in a receipt.

## Local assembly, then freeze

Use an isolated clean checkout of the exact kit head recorded in the PR. Keep
logs outside the worktree and inspect repository instructions first.

```sh
python tools/repair88/assemble.py --expected-head "$KIT_SHA"
python tools/repair88/assemble.py --expected-head "$KIT_SHA" --write
```

The dry run computes all postimages without writing. The write run requires the
same clean input and computes the same postimages before writing. Any missing,
duplicate or altered source anchor fails closed. Do not bypass a guard or
change the script locally to obtain a desired output.

Compare dry-run/write file hashes and the seven-file diff. Commit and push the
mechanical result only to the successor branch, then record its exact commit
and tree. Assemble the paired MindGraph kit in the same way. Qualification uses
fresh detached checkouts of those two committed child identities.

If assembly fails, preserve the result and return it to the implementation
lane. If later testing fails, do not repair the frozen child during the run.

## Developer evidence from this pass

The proposed production binding helper and its ten XCTest cases were copied
into a minimal SwiftPM package and executed on Linux/Swift 6.2.1: 10 passed.
This tests the helper's Foundation-based parsing and validation only, not
ConduitCore as a whole, AppKit, the Session API, or the built app.

Tested helper Git blob:
`c03a2181a4b14ea16f24565cf8366c8c5e76e10c`

Tested helper SHA-256:
`5854d46c035d14966d36050b70def55d8518fb7de3092eaef785501b6832d07c`

The producer helper separately passed 29 Python regression cases. Six
standard-library tests of the consumer assembly guards passed, including
preserving previous changelog releases and refusing ambiguous anchors. Python
syntax compilation passed. The assembler has not run against the complete
predecessor checkout here.

A dedicated read-only hosted build attempt, run 36285609887 on auxiliary branch
`work/repair-88-build-20260927`, failed with zero executed steps and produced no
source artifact. That branch is build support only, not a product dependency or
part of this repair PR. It must not be merged as product code.

No full Conduit product gate, real producer transport test, installed-app run,
or independent qualification was executed in this pass.

## Populated-context acceptance

The new opt-in debug app test uses actual AppModel context candidates and
selection, the production Context IDE bundle and handoff renderers, a nonempty
prepared prompt, and one recorded task. A deliberate context-selection change
must alter the captured state before the test restores the baseline. Repeated
successful inspection and malformed expansion must then leave it unchanged.

The fixture tool lives in the paired MindGraph kit:

```sh
python tools/prepare_repair88_fixture.py "$NEW_NONEXISTING_HOME"
```

After resolving the candidate Python environment and building dependencies,
run the app test from the assembled Conduit checkout with the isolated home:

```sh
HOME="$NEW_NONEXISTING_HOME" \
CFFIXED_USER_HOME="$NEW_NONEXISTING_HOME" \
CONDUIT_QUALIFICATION_HOME="$NEW_NONEXISTING_HOME" \
CONDUIT_REPAIR88_APP_TESTS=1 \
./scripts/test.sh --filter MindGraphPopulatedInspectionTests
```

The seam refuses a home mismatch or missing fixture marker before initializing
AppModel. It is not an MCP command and is absent in release builds. Do not
weaken that guard to run in the operator's normal home.

This is a populated model/recorded-task test. It does not establish non-admission
for a live provider's delivery queue or actual token state. Local qualification
must independently exercise a controlled populated worker/handoff at the
strongest safe installed boundary. Preserve any remaining gap instead of
turning the model test into a broader claim.

## Required local gates

- Real producer CLI and single/shared MCP controls, including registered scope
  aliases that differ from stored index names.
- Original knowledge/projects collision and same-trust/different-index collision.
- Defective producer responses challenged independently through Conduit.
- Published live tools/list discovery before using expansion; read-only metadata
  and availability with write authorization off.
- Full `./scripts/test.sh`, including provider-conformance, then app build.
  Direct Swift test success does not replace this gate.
- Exact compact previews, default query compatibility and raw-output containment.
- Rich same-handle human inspection and populated context non-admission.

exp1 must be requeried. Missing index identity fails closed. exp2 is a logical
source locator, not authenticated storage, a permission grant, verified truth,
or writer-byte custody. No merge, release, ranking change or experiments
MindGraph #25-#27 are authorized by this kit.
