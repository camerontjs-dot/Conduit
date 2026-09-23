# Provider Conformance Qualification

## Profile

- structural_type: verification
- lifecycle_scope: project
- owner_surface: docs/qualification/
- authority: live provider receipts for observations; exact source declarations for adapter intent
- privacy: public-safe, with qualification-owned provider IDs and process IDs
- volatility: active
- source_of_truth: false
- update_rule: append a new receipt and review the matrix against it
- verification: python3 scripts/provider-conformance.py validate --input docs/qualification/provider-conformance-v1.json
- do_not_use_for: account credentials, existing conversations, adapter health, release promotion, or universal compatibility

## Purpose and boundary

The versioned JSON matrix records bounded observations for the installed
runtime versions in the paired receipt. It does not claim that every adapter
is reachable or that one provider's lifecycle contract transfers to another.
The live Conduit adapter catalog was unavailable during this run, so direct
provider probes are not Conduit adapter integration tests.

supported and unsupported require direct evidence for the tested interface.
unknown means the needed operation or authority was not established.
unavailable means a stated prerequisite blocked the probe. In particular, an
empty Codex thread was refused on resume; this does not establish how a thread
with a completed turn resumes.

No active provider turn was started. Closing OpenCode's SSE observer left its
host healthy, while closing Codex App Server stdio ended that host; neither
observation establishes whether an active provider task would continue. Their
release-supervision cells therefore remain `unknown`.

## Read first

- AGENTS.md
- DECISIONS.md entries D-038, D-040, D-047, D-055, and D-056
- Sources/ConduitCore/LifecyclePreflightPlanner.swift
- docs/qualification/provider-conformance.schema.json

## Procedure and outputs

From the Conduit repository root:

~~~bash
python3 scripts/provider-conformance.py inventory --output /tmp/provider-inventory.json
python3 scripts/provider-conformance.py probe --output /tmp/provider-probe.json
python3 scripts/provider-conformance.py validate --input docs/qualification/provider-conformance-v1.json
~~~

Choose a new output filename for each inventory or probe run; the command
refuses to overwrite an existing receipt.

inventory reads CLI versions and advertised interfaces and records only
sanitized authentication state. probe uses temporary homes and directories,
creates no provider prompt, never lists existing sessions, and verifies
cleanup of the qualification-owned session, process, or tmux socket. Do not
run it with credentials copied into the temporary homes. The committed probe
receipt belongs in a new timestamped evidence file when rerun; do not overwrite
the previous receipt.

## Update discipline

Update the matrix only after reviewing the new raw receipt. Keep the tested
runtime version, interface, authority, observation time, identity, procedure,
and evidence pointer attached to the affected provider. A later probe does not
rewrite an older result. Do not change adapter or lifecycle semantics as a
side effect of maintaining this qualification.

## Privacy and provenance

The procedure does not inspect existing provider conversations or reuse their
session IDs. It records no credential values, account names, or private
conversation content. Direct provider observations are evidence about the
exact installed build and exercised interface only; MainFrame summaries and
source declarations remain separate from that evidence.
