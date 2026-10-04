# Source-exposed control and routing packet

This packet covers five published plan rows in three groups only:
`4/approvals-errors-tools-artifacts`, `4/read-proposals-context`,
`4/adapter-conformance`, `P-AUTHORITY`, and `I-RECEIPTS`. It is not a whole-
programme source audit or independent qualification.

## Publication files

| File | Purpose |
| --- | --- |
| `contract-review.md` | Existing coverage, work completed and exact next boundaries |
| `contract-matrix.json` | Twenty-six source-exposed cases, required receipt fields and source anchors |
| `source-inventory.json` | Eighteen exact source-file references and Git blob identities |
| `portable-conformance-receipt.json` | Actual unmodified maintained offline validator result plus 29 verified source/artifact identities |
| `conformance-shape-review.json` | Compact 91-cell / 182-outcome retained matrix census and claim limits |

Keep cached source, API responses, issue comments, encoded file downloads and
the scratch generator out of the publication packet.

## Completed ChatGPT work

The source audit identified and implemented one independent bounded repair:
[Draft #151](https://github.com/camerontjs-dot/Conduit/pull/151), commit
`0ef7979f16ade58fc1146125b808876096510935`, tree
`4a35035c040b1dd097e579edf04c195ba0c9e119`. Proposal context integer overflow
and underflow now produce explicit validation refusal. Eight XCTest and eight
matching SelfTest controls await the local native gate.

The existing provider-conformance matrix was checked with the maintained
offline validator against all 29 referenced exact-main artifacts. It returned
`valid: true`, no errors, exit 0. This validates retained matrix structure and
reference custody; current installed-provider behavior and native qualification
remain NOT_RUN. Optional JSON-schema package imports were unavailable before
that run; no package, source, schema or historical result was modified.

## Boundaries now identified

Typed provider approval/tool/error history must consume the accepted provider-
turn and recovered local D081 command identities before serial canonical-history
composition. Route selection and logical run records already exist in #122 and
#138; their declared facts do not supply live approval, lease or entitlement.
Actual action receipts must stay with the existing event, journal or written
artifact that owns each effect.

Hosted read-only proposal preparation has its own explicit adoption gate in
[#4's preparation note](https://github.com/camerontjs-dot/Conduit/issues/4#issuecomment-5482776441)
and [#9](https://github.com/camerontjs-dot/Conduit/issues/9): prove the actual
hosted path permits a strictly read-only computation and demonstrate unchanged
task/runtime/event/project state. It is not an extra endpoint to add to frozen
#146's 18-tool catalogue. The contract matrix prepares that experiment without
claiming it ran or authorizing a hosted write.

All cases are source-exposed. An independent oracle author must not receive
this packet before freezing their oracle. It can then be used as separately
labelled source-exposed pressure. No frozen candidate was changed by this audit.
