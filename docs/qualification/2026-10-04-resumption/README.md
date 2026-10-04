# 2026-10-04 local qualification handoff

This is a dated, exact-input handoff. [Issue #60](https://github.com/camerontjs-dot/Conduit/issues/60) owns the live programme plan. This packet does not replace the pause review, earlier qualification packets, frozen failures, or owner receipts.

## Objective and working split

ChatGPT owns ordinary source implementation, source review, successors, tests, pull requests and GitHub reconciliation. The local coordinator owns recovery of existing local artifacts and macOS execution against exact candidates. Return a demonstrated source defect to ChatGPT with the smallest reproducer and raw evidence. Keep the failed candidate frozen; a repair has a different identity.

The next critical sequence is fresh qualification of **#123, then unchanged #128**. These are separate branches from the same earlier main. Passing #123 does not put its owned-root/port implementation into #128. Exact #128's offline Core/native-client checks may proceed after the #123 apparatus gate; a mounted AppModel/HTTP journey containing both changes needs a separately identified composition candidate.

## Packet contents and authority

| File | Audience | Purpose |
| --- | --- | --- |
| `candidate-lock.json` | Coordinator and executor | Exact frozen inputs and scope; current #128 descriptor precedence |
| `developer-candidates.json` | Coordinator and executor | Exact #150–#153 heads, focused suites and remaining native gates |
| `allocation-snapshot.md` / `.json` | Programme coordinator | All 157 published rows and the 44-PR baseline, with the four-publication amendment |
| `prefreeze/contract.md` | Fresh oracle author | Outcome contract without implementation or prior result details |
| `prefreeze/aperture.json` | Coordinator | Mechanical file allowlist and forbidden information classes |
| `postfreeze/recovery-manifest.json` | Source-exposed coordinator | Published local apparatus locators/hashes; explicit missing custody |
| `postfreeze/developer-pressure.md` | Source-exposed reviewer after oracle freeze | Two unexecuted source-review vectors; no independent-oracle claim |
| `postfreeze/context-and-retrieval/` | Source-exposed reviewer after oracle freeze | 28 prepared retrieval/UI/card/corpus cases and exact producer/kit comparison |
| `postfreeze/control-and-routing/` | Source-exposed reviewer after oracle freeze | 26 prepared control/routing/action-receipt cases and actual offline conformance validation |
| `postfreeze/portable-preflight-validation.json` | Coordinator and reviewer | Actual 16-test Linux preflight result, source hashes and preserved capture limitation |
| `receipt-template.json` | Coordinator and reviewer | Required return fields; all unexecuted work starts `NOT_RUN` |
| `local-agent-prompt.md` | Local coordinator | Bounded assignment and stop conditions |

The source preflight is `scripts/qualification/verify_frozen_source.py`, with portable tests in `Tests/test_frozen_source.py`. It checks the supplied checkout's source identity only. It does not qualify process/cache isolation, a binary, a toolchain, a provider account, an oracle, or the product. The complete portable test entry is `python3 -m unittest discover -s Tests -p 'test_frozen_source.py'` from the handoff checkout.

The preflight requires POSIX, Python 3.9+ and Git SHA-1 objects. It compares raw tracked working bytes and Git executable modes, with stable per-file reads and before/after Git checks. It does not normalize filters/EOLs or cover ignored artifacts, full permissions, ownership or extended attributes. Select and record the real Git executable; its hash is an observation, not authentication. The final portable run passed 16 tests without skips; only the invalid-UTF-8 filename fixture may explicitly skip on a filesystem returning `EILSEQ` or `EINVAL` for its creation.

Example invocation, with actual paths selected and recorded by the local coordinator:

```sh
python3 /path/to/handoff/scripts/qualification/verify_frozen_source.py \
  --candidate 123 --repo /path/to/disposable-candidate \
  --git /absolute/path/to/selected/git \
  --lock /path/to/handoff/docs/qualification/2026-10-04-resumption/candidate-lock.json \
  --output /path/to/evidence/source-before.json
```

Use a new receipt path on every invocation. The lock and receipt must remain outside the inspected checkout. The script also accepts the exact locked IDs 128 and 150–153; it does not interpret a branch name as a frozen identity.

The four new source PRs have zero-step hosted CI failures in the recorded post-push read. The connector did not expose their failure annotations, so the cause remains unknown in this packet. No hosted Swift, native or package result is inferred from those runs. Successful exact-head CI for #123/#128 remains separate historical/current-run evidence in their lock entries.

## Recover before replacing

Earlier checkpoints report prepared and recovered #123/#128 packets and source inventories. The published receipts do not identify every enclosing local directory, driver source, wrapper or invocation. Recover the existing artifacts through the local pause review and raw-material index. Match their recorded hashes and distinguish original files from reconstructed copies. The recovery manifest gives known locators; `UNKNOWN` is not a wildcard.

Recover the original actual-app/client harness, fixture source, real-Xcode wrapper, raw result/log files, process waits, teardown, source inventory and information-aperture receipt. A matching result-file hash alone does not identify the command that produced it. Do not recreate a successful owner receipt from aggregate counts.

If a file is absent, report the exact missing object and the affected gate. A replacement apparatus must have a new identity, explicit deviations and its own pre-result freeze. Preserve the existing failure and unavailable-custody records. There is no need to change product source merely to repair a missing apparatus locator.

## Fresh-oracle boundary

The coordinator may read this whole packet. That makes the coordinator source-exposed, not fresh. Recover and inspect an earlier frozen independent packet first; reuse it only when its exact identity, pre-result freeze and allowed exposure are reconstructable.

For a new oracle, expose only the `prefreeze/aperture.json` allowlist in a restricted workspace/tool context. Do not give the fresh author this README, the full issue/PR history, implementation, committed tests, owner receipts, the recovery index, source-pressure vectors, this chat, or local pause-review contents. A new thread by itself does not enforce this boundary.

The provided contract is a coordinator-prepared extract of published behavior. It is not a fresh oracle or a validated executable. The fresh author independently chooses discriminating cases, expected results and completeness criteria. If a native harness needs public interface declarations absent from the allowed contract, the coordinator must supply a separately frozen declaration-only supplement and update the aperture before authoring; do not permit the implementation tree as a convenience. Record exactly what was exposed. If this cannot be enforced, label the work source-exposed qualification and leave the independent gate open.

Freeze oracle, fixtures, harness, wrapper, input manifest and expected outcomes before decisive execution. Freeze both candidate plans before their author sees either implementation or result. If #128's oracle is authored later, use an author whose restricted context remains unexposed; an author who saw #123's broad source may already have seen shared #128 code. Record each SHA-256, the candidate identity and the environment contract. Do not revise expected outcomes after reading a result and count the repaired oracle as the original independent comparison. Subsequent source-exposed developer pressure remains a separate evidence class.

## Local execution sequence

1. Recheck live #60 and both PR heads against the lock. A moved branch is a discrepancy to reconcile, not permission to substitute a new subject. Recover the local packets and verify their actual bytes. Carry forward their governing package, attempt, observation/time and remaining-budget limits. Resumption or a new apparatus identity does not reset those bounds. Missing applicable limits are a preparation blocker for dependent execution.
2. Confirm one native testing slot is available. Record protected operator app/process/state/cache baselines without dumping secrets. Select explicit owned checkouts, evidence roots, fixture roots, ports, build/cache roots and tool executables. `HOME`, `CODEX_HOME` and operator stores keep their existing meanings. A new directory does not establish process or cache separation.
3. Run source preflight with an external lock and a new receipt path. Inspect its completed receipt; a missing, failed or timed-out Git command is not a clean checkout. Recheck source before and after native work. Declare output/cache paths before execution, including any script-owned `.build`/`dist` paths inside a disposable checkout. Inventory generated and ignored artifacts separately; the source preflight does not certify those bytes. Do not relax source checks to conceal unexpected generated source files.
4. Execute #123's frozen independent apparatus first, including actual-app refusal/readiness and isolation controls. Resolve an apparatus failure in a new apparatus identity; preserve any observed product failure for a source successor. Stop dependent execution when the required isolation claim is unsupported.
5. After the prerequisite passes, execute exact #128's frozen offline Core/native-client protocol and durable-reconstruction cases. Do not start its uncomposed AppModel against operator state or assume it accepts #123 environment variables. Full status/events HTTP agreement remains a later composition gate.
6. Replay owner regressions and run the separate post-freeze developer pressure with their own labels. Do not force an ambiguous policy case to pass by changing the frozen contract. A counterexample must identify raw input, actual output, violated authority and scope.
7. Compile and test the new ChatGPT source candidates listed in the final #60 handoff as separate exact candidates when the owned toolchain/apparatus is available. These are ordinary developer/native checks, not fresh qualification of #123/#128 and not integrated product acceptance. Return compilation or runtime defects to ChatGPT; do not quietly repair the tested subjects.
8. Preserve raw streams, exact exit statuses and actual process waits. Inventory first release/package bytes before any second build or normalization. Teardown only owned resources, verify residuals and compare the protected baseline. Publish sanitized receipts and immutable artifact references to the owning issues; keep private machine evidence under its local authority.

No repository script should be executed merely because its filename looks appropriate: inspect its exact configuration and how it selects toolchain, cache and outputs. Preserve a rejected or zero-step command as such. Do not rerun a command to manufacture a receipt for an earlier unobserved execution.

## Independent local custody work

Recovery can proceed while the native slot is occupied, without editing source. Return exact portable source/design bundles or immutable Git references for local D079 authored links, D080 Next Move, E7 filename/handoff work, D081 command custody, the shared Git/E8 design and target-four catalogue/artifact successor. Include parent, commit/tree or staged-tree identity, source inventory, frozen oracle and original failed/passing artifacts. This makes subsequent ChatGPT review and source work possible.

Do not redo the completed #76 byte-localization step: its recorded 26 differing prefix bytes, including 18 outside masks, are already a result. The unresolved task is the cause and a separately identified artifact/apparatus successor. Do not duplicate the eight-blob/23-input shared-Git design from prose. Do not treat D079/D080 owner passes or E7 positive controls as missing independent, package or mounted acceptance.

## Disposition and return boundary

Use `PASS_BOUNDED`, `PRODUCT_FAIL`, `APPARATUS_FAIL`, `BLOCKED`, `INCONCLUSIVE`, `CONTAMINATED` or `NOT_RUN` per gate. A pass names the exact supported property; it does not imply merge readiness. A build, first release/package, signature, fresh oracle, mounted journey and install are distinct gates.

Return the receipt template plus raw-artifact manifest, exact candidate/apparatus identities, deviations, counterexamples, owned teardown and the smallest next action. Continue dependency-independent recovery and ordinary checks when a different lane blocks. Stop before a source repair, unprepared composition, missing authority, or a change to a frozen oracle. No production installation/release, account changes, higher-capacity experiment or real provider turn is part of this packet.

The previous external CLI qualifier launch was rejected because private-source transfer lacked explicit authorization. That launch remains unrun. This packet prepares an operator-run local task; it neither retries that launch nor grants a new source-transfer route. Use only the local session's authorized access. If the same source-access boundary is encountered, return its precise blocked disposition.
