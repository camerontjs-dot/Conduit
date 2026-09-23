# Slice 10 provider conformance

`provider-conformance-v1.json` is the versioned result. Its schema requires all
13 capabilities for all seven target runtimes and records separate provider
and Conduit outcomes. The provider outcome records what the native runtime
interface showed. The Conduit outcome records what the adapter and Conduit
lifecycle boundary support, with direct runtime receipts and source/tests
listed separately. `supported`, `unsupported`, `unknown`, and
`unavailable` are distinct states. A method name or CLI flag is not
sufficient evidence for `supported`.

The result is bounded to the installed versions and interfaces named in each
runtime entry. It is implementation and local-probe evidence, not independent
terminal qualification. Do not use it as a universal provider compatibility
claim.

## Rerun

Run from the Conduit repository root. Each command writes a JSON receipt under
`docs/qualification/receipts/` and prints its path.

```sh
python3 scripts/provider-conformance.py inventory
python3 scripts/provider-conformance.py opencode
python3 scripts/provider-conformance.py codex
python3 scripts/provider-conformance.py grok
python3 scripts/provider-conformance.py gemini
python3 scripts/provider-conformance.py shell
python3 scripts/provider-conformance.py validate --receipt <receipt-path>
python3 scripts/provider-conformance.py validate-matrix --matrix docs/qualification/provider-conformance-v1.json
```

`inventory` records executable and app versions, safe readiness indicators,
and interface flags. Credential values are never written. `opencode`, `codex`,
and `grok` create one qualification-owned session/turn in a unique temporary
workspace, use exact scoped identities, and clean up only those resources.
The Grok probe verifies exact session deletion. `gemini` performs ACP
initialize only; it does not authenticate or create a session. `shell` creates
one direct PTY with a child process, observes its process group, stops it, and
removes the workspace.

Do not replace an `unknown` result with `unsupported` unless the tested provider
interface explicitly rejects or lacks that capability. Keep provider-host,
session/thread, turn, Conduit task, writer authority, completion, verification,
and acceptance as separate identities and outcomes. A Conduit adoption result
must not be inferred from provider discovery or exact-ID resume.

After rerunning, add new receipts rather than overwriting earlier ones. Update
the matrix with the new runtime versions, procedure IDs, exact identities,
receipt paths and hashes, freshness, and provider-specific limitations. Record
the frozen candidate SHA/tree and hosted CI state in the GitHub #53 receipt and
Draft PR. Independent qualification remains a separate step.
