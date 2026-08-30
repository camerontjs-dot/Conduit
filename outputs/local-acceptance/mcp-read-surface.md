# Local MCP read-surface receipt

Plan provenance: PR #5, `docs/LOCAL_ACCEPTANCE_AND_CONTROL_PLANE_TEST_PLAN.md`, blob `dcd1cfdc4f93aa6039585a4abfb48d2c8034e026`.

This receipt covers the bounded read-only Session API surface on the actual
installed app. The app was built from the focused transport-fix object below;
the acceptance branch carries evidence only and does not merge that fix into
the research branch.

## Test context

- Test date/time: 2026-08-30T00:57:59Z
- Conduit SHA: `82b9574b89a4c90f78136032e5a4139eff7c8475` (installed build)
- Acceptance branch: `research/control-plane-local-acceptance-20260829`
- Acceptance branch tip while recording: `b0b3019ed74f3d2fb06aa91767e54d9543e83051`
- Installed-app/build identity: `dist/Conduit.app`; ad-hoc arm64 build;
  executable SHA-256
  `f36a70658b2a2e57c0502669e488a95b72939a43c57895a9112ccb18551d4d26`
- Machine/environment: macOS 26.5.2 (25F84), arm64; loopback listener
  `127.0.0.1:8750`; writes remained disabled
- Provider/runtime: Conduit Session API; authenticated raw-socket probe
- Preconditions: existing local app and token; the credential was read inside
  the probe process only. No token value, project slug/title, task UUID/title,
  transcript, or tunnel identifier was emitted or stored.

## L2.1 — Catalog

Test ID: L2.1

Action: sent `initialize` and `tools/list` with the exact local credential.

Expected: the protected endpoint responds and advertises a stable catalog with
explicit read-only annotations and no implicit write entitlement.

Observed: both responses were HTTP 200. The catalog contained 11 tools: six
with `readOnlyHint: true` and five advertised state-changing tools with
`readOnlyHint: false`. The catalog names were the six read surfaces
(`conduit_list_projects`, `conduit_list_sessions`, `conduit_list_adapters`,
`conduit_session_status`, `conduit_session_events`, and
`conduit_query_mindgraph`) plus five lifecycle/write surfaces. Catalog metadata
does not grant the writes; the local gate still refuses them while disabled.

Result: PASS

Evidence: sanitized installed-app MCP response metadata; no response payload
containing private project/task data was retained.

Negative findings: this proves catalog exposure and annotation shape only; it
does not prove that any lifecycle write succeeds.

Follow-up: repeat catalog checks after any contract/catalog change.

## L2.2 — Project index

Test ID: L2.2

Action: called `conduit_list_projects` with no mutation arguments.

Expected: a bounded read of the configured local project index.

Observed: HTTP 200 in 0.001 seconds; 42 rows returned. Sanitized state counts
were active 8, paused 23, planned 3, shipped 1, and suspended 2. The row
fields were `slug`, `state`, and `title`; values were deliberately not saved.

Result: PASS

Evidence: count/state metadata only.

Negative findings: no project was created, edited, opened, or otherwise
mutated.

Follow-up: project contents and inaccessible-path behavior remain outside this
read-surface probe.

## L2.3 — Session index

Test ID: L2.3

Action: called `conduit_list_sessions` with `limit: 1`.

Expected: bounded pagination and explicit indication when the result is
truncated.

Observed: HTTP 200 in 0.001 seconds; one row returned from a reported total of
73 with `has_more: true`. The observed row was `lifecycle: detached` and
`runtime_state: detached`. Task IDs, titles, project names, and agent names
were not retained.

Result: PASS

Evidence: sanitized pagination and state metadata.

Negative findings: this is an index observation, not proof of task completion
or provider progress. Existing detached history was not reconciled or changed.

Follow-up: status/events for a task require a task ID and were not expanded
into private history during this read-only pass.

## L2.4 — Adapter declaration index

Test ID: L2.4

Action: called `conduit_list_adapters`.

Expected: the declared local adapter surface is readable while distinguishing
declaration from live health.

Observed: HTTP 200 in 0.002 seconds; seven adapter rows. Sanitized backend
counts were ACP 2, app-server 1, HTTP-server 1, PTY 1, and structured-CLI 2.
The returned row schema included declaration/status fields such as backend,
launch, resume, structured, and surface.

Result: PASS

Evidence: count/backend/schema metadata only.

Negative findings: this endpoint explicitly declares, rather than health-checks,
provider availability. No provider task or runtime was started.

Follow-up: run the full provider matrix only when a controlled write-gate
fixture is available.

## L2.5 — MindGraph retrieval boundary

Test ID: L2.5

Action: called `conduit_query_mindgraph` separately for `knowledge` and
`projects` with the harmless question `Conduit local acceptance baseline`.

Expected: scope is required, both indexes remain separate, and results are
returned as nominations with trust/citation metadata rather than proof.

Observed: each scope returned HTTP 200 in about 3.5 seconds with exit code 0,
eight ranked results, zero `not_citable` results, and the explicit trust label
`nomination only`. Knowledge citation counts were citable 5, unverified 3,
not-citable 0; projects were citable 8, unverified 0, not-citable 0. The
authority text stated that retrieval nominations are not evidence that a claim
holds.

Result: PASS

Evidence: scope/count/citation/trust metadata only; matched passages and paths
were not retained.

Negative findings: retrieval remains epistemically downstream of source
inspection; no task was created from a planner or retrieval result.

Follow-up: preserve the two scopes and trust labels in future tunnel/read
surface checks.

## Scope boundary

OBSERVED: the actual local app exposed a responsive, bounded read surface for
catalog, projects, sessions, adapters, and both MindGraph scopes while writes
were disabled.

INFERRED: the read surface is suitable for further observation and reconciliation
probes, subject to the documented nomination/observation limits.

UNKNOWN: hosted ChatGPT tunnel reachability, write entitlement, task creation,
provider turns, approval/interrupt observation, tmux/PTY lifecycle,
persistence/restart, GUI termination, and macOS permission boundaries remain
untested or blocked.
