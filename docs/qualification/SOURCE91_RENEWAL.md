# PR #91 source-evidence renewal and hosted-preparation handoff

Status: **PREPARED / ASSEMBLY_PENDING**, not a full wrapper or hosted PASS.
Owners: GitHub-side hosted-supervision implementation owner; local preparation
remains with worker `01a0e0a3-3173-70d3-8a1d-f05ee65819c6` under #89/#87.
This is a separate direct-child preparation kit. Do not advance #91 or #89.

## Reviewed subjects and failure interpretation

- Runtime #91: `3e557adb98bdf32c7c3e39e2c3d215b24ea1ef4e`, tree
  `0db031cf92ddda575073eb471473ed7fe4750731`.
- Runtime parent/operator source: `61349887dcf5d562ee3bfd96acfd443e63191c3f`.
- Apparatus #89: `89733c67556bbf1fde7e31edffc229e527321815`, tree
  `57f627577c098f95926322cb3171414c5fab986a`; remains a separate checkout.
- Preparation: [#89 receipt](https://github.com/camerontjs-dot/Conduit/pull/89#issuecomment-5852077197)
  and [#87 receipt](https://github.com/camerontjs-dot/Conduit/issues/87#issuecomment-5852057834).

The two failing positive tests are
`test_committed_matrix_has_explicit_states_for_every_runtime_capability` and
`test_unknown_is_preserved_as_a_bounded_result`. Both call `validate_matrix`,
which hashes **current checkout bytes** for every local artifact. The
`CONDUIT-API-SCOPE` entry is `source_test`; it pins parent AppModel bytes, not
an immutable provider run. #91 changes AppModel startup, so both assertions
correctly reject its stale current-source binding. The failure is neither an
observed provider regression nor evidence that historical receipts were damaged.

`test.sh` uses `set -e`; its Python failure prevents the subsequent XCTest
command. Moreover `test.sh --filter SessionAPIReadinessTests` would still only
run filtered XCTest after Python passes. Neither that command nor the reported
4/4 focused XCTest result constitutes an unfiltered full-suite pass.

The seven-file #91 diff changes AppModel only in `syncSessionAPI`: resolve the
reserved port before token/admission setup, inject it, and display it. It does
not change provider scope, prompt delivery, lifecycle, verification or acceptance
logic. No provider implementation repair is justified by this failure.

## Guarded renewal, not an automatic hash refresh

`renew-source91-evidence.py` checks the exact base/candidate AppModel and original
matrix Git blobs, independently checks the old SHA-256, and compares the whole
candidate with a single exact reviewed startup replacement in the base file.
Changing any other AppModel byte, including a provider guard or no-resend rule,
refuses renewal even if a new candidate hash is supplied in edited guard code.

The proposed matrix changes only `CONDUIT-API-SCOPE`. The source observation gets
a new date, authority, procedure, source identity and explicit limitations. The
prior complete source record is preserved in a new receipt. Provider outcomes,
native runtime receipts and their hashes, source/test validators, and all other
matrix bytes are unchanged. The existing `validate-matrix` must accept the
proposed document before `--apply` writes anything. No test-time hash update or
skip/waiver path is added.

This kit itself does not contain the assembled matrix update. Its synthetic
controls qualify the guard logic, not successful assembly against private full
source, full repository validation, current Codex health, or hosted dispatch.
Do not call this commit the final runtime candidate. The mechanical child must
be committed and requalified. Keep the preserved #91 failure unchanged.

## One local handoff to the existing preparation worker

1. Fetch the exact kit SHA in the PR receipt and its ancestor objects. Use a new
   preparation worktree/owned branch, never the running candidate checkout. Verify
   the kit is a direct child of #91 with exactly the three preparation files.
   Recheck live ownership/instructions before any write.
2. In that clean checkout, with `KIT` set to the **exact reviewed kit SHA**:

   ```sh
   PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests -p 'test_source91_evidence.py' -v
   PYTHONDONTWRITEBYTECODE=1 python3 scripts/renew-source91-evidence.py --expected-head "$KIT"
   PYTHONDONTWRITEBYTECODE=1 python3 scripts/renew-source91-evidence.py --expected-head "$KIT" --apply
   git diff --check
   git diff -- docs/qualification/provider-conformance-v1.json
   ```

   The only generated files must be that matrix and
   `docs/qualification/source91-renewal-receipt.json`. Inspect and commit both on
   this successor branch. Record the new child SHA/tree; do not amend the kit,
   #91, #89 or old receipts. A guard failure stops assembly, not permission to
   edit expected pins. The script never commits, fetches, launches or connects.
3. From a fresh clean checkout of the **assembled child**, run unfiltered
   `./scripts/test.sh`, then `./scripts/build-app.sh` and strict codesign. Preserve
   all failures and report tests actually reached. Re-run #89's exact 18-test
   helper suite separately. Do not use `verify-installed.sh` against the operator.
4. Recheck current candidate/operator PIDs, executable hashes, start identities,
   listener ownership, task inventories and state separation. Historical PIDs
   53618/35525 are observations, not current targets. Build outside both app paths.
   Do not replace a running binary. Any later candidate-only transition requires
   fresh exact ownership/no-active-work checks and its own receipt; unknown
   ownership blocks it. Operator app/listener/tunnel remain untouched.
5. Reuse the five prepared fixture projects (`hs-smoke`, `hs-pilot-l1`,
   `hs-pilot-f1`, `hs-pilot-f2`, `hs-pilot-l2`) after verifying their existing
   input/AGENTS/README hashes, nonces and absence of `result.json`. Do not regenerate
   them. Preserve manifest SHA-256
   `0a86408b6eb0bc01023e26a9e8be2eda6dcbccd27973efeba6417bc8f1a9c0c9`;
   append a successor readiness manifest, never overwrite the predecessor.
6. Return one preparation receipt on this successor PR, linked to #89/#87,
   listing assembly/full-wrapper/build results, actual identities and remaining
   gates. Stop at PREPARED or concrete BLOCKED. Do not execute the hosted trial,
   modify connections, handle credentials, enable a write gate, merge or release.

## #89 compatibility and launch-manifest obligations

The #91 catalogue remains blob `d21b716a6ab8fbe5f3a48e366646adaeb28d063f`:
18 tools with queued initial objectives owned by Conduit. `queued` and
`delivered` mean **no resend**. Missing/lost responses do not authorize retries;
create idempotency does not establish send idempotency. #91 does not incorporate
#46/#47/#82/#84/#86/#90. Generic provider discovery/adoption remains OpenCode-only.
The #89 follow-ups occur after terminal output; they do not qualify active-turn
queueing, native approvals, restart safety or higher concurrency.

Compare source, raw candidate `tools/list`, approved connection metadata and
model-visible names/descriptions/schemas/annotations separately. Count equality
is insufficient. Missing export fields remain UNKNOWN, not fabricated matching
JSON. Missing required controls or conflicting no-resend semantics block writes.
Current catalogue equality and all hosted trial measurements remain unproven.

The successor manifest must bind the assembled runtime SHA/tree/binary, #89
SHA and three file hashes, qualified port/state/ownership receipts, exact
qualification connection-to-endpoint identity, provider executable/version,
configured versus actually observed model/effort/profile/auth status, fixture
identities and allowed paths, write-gate observations, budgets, query policies,
measurement boundaries and cleanup scope. No token values. Missing evidence
blocks the affected readiness claim. Preserve L/F/F/L and at most one active
qualification turn; no pilot runs belong in preparation.

## Bundle the owner-only actions, do not repeat setup

After source/local checks, the remaining operator decision points are normal
Codex login/consent/MFA in the **existing dedicated Codex home**, consent for the
**separate** qualification ChatGPT connection, and the explicit candidate-only
Mac write-gate approval once provider/connection preflights are ready. Do not
ask the operator to reinstall Conduit, recreate fixtures or alter operator 8750.
Configured `gpt-6-sol` is not authenticated model availability.

A separately authorized computer-use assistant can navigate/open the correct
candidate UI, stage the qualification connection/tunnel setup
`conduit-hosted-qualification-20260926` against candidate 18750, compare metadata
and collect non-secret diagnostics. Account login/consent/MFA and the explicit
write-gate decision remain with the operator. This handoff authorizes none of
those connection, credential or permission changes in the current source turn.
The later hosted supervisor, not local HTTP, owns the decisive smoke/pilot.
