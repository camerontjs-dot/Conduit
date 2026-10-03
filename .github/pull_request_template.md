## Problem and resulting behavior
<!-- Concrete trigger, previous behavior and resulting behavior. -->

## Scope and authority
<!-- Owning issue/plan; protected behavior; consequential action authority. -->

## Candidate and verification
<!-- Substantial changes: exact base/head/tree and source/build actually tested. -->
<!-- Actual commands/results/receipts, not a checked box for a suggested command. -->

- Native/Core: `./scripts/test.sh` (selftest, Python contracts, XCTest).
- Package, when applicable: `./scripts/build-app.sh` and its signature result.
- Hosted CI: exact candidate/tree, executed steps and result.
- Machine-bound qualification: exact source/build, owned environment and receipt.
- NOT_RUN, skips, failures and remaining UNKNOWNs:

<!-- Documentation-only work may use source/reference, diff and leak checks. -->
<!-- Installed verification requires separate authorized apparatus; AGENTS.md. -->

## Negative evidence and disposition
<!-- Preserved failed attempts, predecessor/successor lineage and bounded claim. -->

## Security & Leak Prevention Checklist
- [ ] No hardcoded local machine paths
- [ ] No live API keys, tokens, or credentials in diff
- [ ] `.env` and local caches remain ignored
