# Codex metadata: hosted diagnostic custody successor

Frozen Draft #136's hosted run executed the product checks successfully but
preserved no `codex-metadata-owner` artifact. The upload step warned that no
files matched `.build/codex-metadata-owner-*/`; the artifact API returned only
the test log, build log and packaged app. The missing native receipt/wire
archive is a custody FAIL, despite the green run.

Predecessor head `087fc7a8c472ed1af18c60fa62b962d712b2f660`, tree
`d2ca458590a106971e6aca5f66fa3a7350d98a6b`, remains unchanged. Run
`37124302410` / job `111206400678` checked out synthetic commit
`3b14a895224c28506d06c92152275ce3202c0a9d`, whose tree equals that candidate.
Its decoded job log has SHA-256
`5518aae21cfb7b3102cc8dca2be3cc3350caf88f7f8a8190e195b21b39a55dda`.
All 15 actual job steps succeeded; stdout records 476 selftests, 616 reported
XCTest cases with three explicit provider skips and zero failures, 18 fake
native scenarios, and release/package execution. Those component results do
not establish archive custody.

This separately identified successor enables hidden-file inclusion for only
the existing exact owned fixture wildcard. The
[upstream v4 action input](https://github.com/actions/upload-artifact/blob/v4/action.yml)
defaults hidden-file inclusion to false. Missing files now fail this upload
step. Other artifacts and paths are unchanged; the workflow does not upload
other `.build` directories, caches, credentials or environment files.

The reviewed local producer inventory contains 54 files: the compiled native
harness, owner receipt and synthetic scenario/wire/termination records. It
invokes no real provider. The 248 tested Sources, Tests and scripts files are
unchanged from source head `20d02b09c14d4cb075632d56284192ea59b67c24`, tree
`149127567afddd04ee6605a924b3e1f3abfd3e3d`. The
[previous owner receipt](receipts/codex-metadata-discovery-owner-20261003-v1.json)
retains its bounded local checks and negative lineage.

The [prospective custody record](receipts/codex-metadata-hosted-custody-successor-20261003-v1.json)
does not claim a PASS. The successor's exact-head hosted run must execute the
native fixture and upload an actual matching archive. Its downloaded digest,
file inventory, owner receipt, 18 scenario records, 17 wire logs and 17
termination records must be checked before claiming hosted custody supported.
The no-host case creates no process or teardown file. The final identity and
disposition are reconciled on the successor PR and #53/#49.

D070 stays Proposed / T0. This workflow repair changes no maintained product
behavior; CHANGELOG is N/A. Independent qualification, real-provider field
support, mounted #87 AppModel/HTTP behavior and general #114/#128 RPC authority
remain separate. No merge, installation or release is authorized by this
receipt.
