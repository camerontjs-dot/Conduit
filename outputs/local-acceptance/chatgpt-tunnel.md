# ChatGPT Secure MCP Tunnel receipt

Plan provenance: PR #5, `docs/LOCAL_ACCEPTANCE_AND_CONTROL_PLANE_TEST_PLAN.md`, blob `dcd1cfdc4f93aa6039585a4abfb48d2c8034e026`.

This is an actual connected-path probe. It starts the configured
`tunnel-client` profile, uses the real MainFrame Conduit connector tools, and
stops the client after the bounded checks. It is not a localhost-only
substitute. No tunnel identifier, API key, bearer value, project/task value,
or transcript was written to this receipt.

## Test context

- Test date/time: 2026-08-30T01:06:19Z
- Conduit SHA: `82b9574b89a4c90f78136032e5a4139eff7c8475` (installed fixed app)
- Branch carrying receipt: `research/control-plane-local-acceptance-20260829`
- Installed-app/build identity: `dist/Conduit.app`; executable SHA-256
  `f36a70658b2a2e57c0502669e488a95b72939a43c57895a9112ccb18551d4d26`
- Machine/environment: macOS 26.5.2 (25F84), arm64; local Session API on
  `127.0.0.1:8750`
- Tunnel runtime: `tunnel-client` 0.0.11+8d55683eeef80bc5e360d95abf4692454fafc615;
  profile name `conduit`; profile contents were not read into the receipt
- Preconditions: Conduit running with writes disabled; existing configured
  tunnel profile and owner-only local credential files.

## L9.1 — Local tunnel configuration and doctor

Test ID: L9.1

Action: inspected only metadata for the configured tunnel files and ran
`tunnel-client doctor --profile conduit --explain`.

Expected: the configured client/profile is present, credentials are protected,
and doctor completes without exposing secrets.

Observed: `tunnel-client` was present and its version command exited 0.
`doctor --profile conduit --explain` exited 0. The local metadata-only check
reported owner-only mode 0600 for the tunnel ID file, control-plane key,
Session API token, and generated authorization file. The YAML profile existed
with mode 0644; its secret references and values were not read or saved.

Result: PASS for local configuration/permission metadata.

Evidence: sanitized command status and file mode/size metadata.

Negative findings: doctor success alone is not a live tunnel or ChatGPT
connector proof.

Follow-up: retain the profile and key files outside the public repository.

## L9.2 — Actual tunnel daemon health

Test ID: L9.2

Action: started `tunnel-client run --profile conduit` in a bounded PTY, then
queried its loopback admin health endpoints before stopping it.

Expected: the configured daemon remains running and exposes health/readiness
without requiring a local-only MCP substitute.

Observed: the daemon remained alive during the probe. `GET /healthz` on its
configured loopback admin port returned HTTP 200 and `GET /readyz` returned
HTTP 200. The client was stopped cleanly after the connector checks.

Result: PASS

Evidence: sanitized PTY lifetime plus HTTP status/content-type/byte metadata.

Negative findings: startup logs included a non-fatal OAuth discovery warning;
raw logs were not retained because they contained secret-like configuration
references. Health is not proof of hosted tool authorization.

Follow-up: use the connected tool results below for hosted-path evidence.

## L9.3 — Connected read surface

Test ID: L9.3

Action: while the real tunnel daemon was active, called the connected
MainFrame Conduit tools for projects, sessions, adapters, MindGraph (both
scopes), status, and events. The session status/events calls used the first
existing row from the bounded session listing; its identity and content were
not retained.

Expected: the hosted connector reaches the current read surface and preserves
the local observation/nomination boundaries.

Observed: all seven read operations returned without connector errors:

- projects: 42 rows;
- sessions: one-row page from a reported total of 73 with `has_more: true`;
- adapters: seven rows;
- MindGraph `knowledge` and `projects`: eight results each, with the explicit
  `nomination only` trust label and no `not_citable` rows;
- status: a detached PTY task was reported as `durable_state: registered`,
  `provisioning_state: unknown`, `recoverable: true`, and recovery action
  `conduit_reconcile_task` (five bounded status events);
- events: one event from a five-event timeline, cursor state `ok`, lifecycle
  and runtime state `detached`, turn state `ambiguous`, provider thread source
  `unavailable`, observation checkpoint `capture_closed`, and provider
  progress `unavailable`.

Result: PASS for the current connected read surface.

Evidence: connector return status and sanitized counts/state metadata only.

Negative findings: these calls observe existing local state; they do not prove
agent completion, provider progress, or task recovery. Private row values were
not copied into the repository.

Follow-up: retain status/events as observation surfaces, not completion proof.

## L9.4 — Current write entitlement

Test ID: L9.4

Action: through the same connected path, submitted one synthetic
`conduit_create_task` request with a nonexistent agent/project and a stable
test idempotency key. The request was intended only to observe the local gate.

Expected: with Session API writes disabled, the request is refused before task
creation or capacity consumption.

Observed: the connector returned an error with code `INVALID_ARGUMENT`; the
sanitized response contained the exact phrase `Write tools are disabled`, no
task-session identifier, and no project-validation result. This indicates the
local write gate fired before the synthetic arguments were evaluated. No task,
runtime, prompt, approval, or provider process was created.

Result: PASS for refusal; BLOCKED for invalid-project-before-capacity and all
write-path admission semantics while the gate remains disabled.

Evidence: sanitized connector error classification and post-check session
index unchanged at the read-surface level.

Negative findings: this is not a bypass attempt and does not establish write
authorization for the account.

Follow-up: test admission, idempotency, and caller isolation only with an
explicitly enabled, controlled write fixture.

## Preserved precondition failure

Before starting the daemon, the same connected MainFrame Conduit tool calls
returned `UNAVAILABLE`; the underlying sanitized error classes were HTTP 429
and HTTP 404 from `openai.org`. After the configured daemon was running, the
same read calls succeeded. This before/after distinction is retained rather
than collapsed into a generic “tunnel configured” claim.

## Scope boundary

OBSERVED: the configured Secure MCP Tunnel client can run on this machine and,
when active, the real connected path reaches the current projects, sessions,
adapters, status/events, and both MindGraph read surfaces. The current write
gate refuses a synthetic create request before task creation.

INFERRED: the observed 404/429-to-success transition is consistent with the
connector depending on the live tunnel daemon; it does not by itself prove
ChatGPT UI rendering or account-level write entitlement.

UNKNOWN: live provider task creation, initial-objective delivery, approvals,
interrupt cancellation, tmux/PTY recovery, persistence/restart, GUI-kill
reconciliation, and hosted write authorization remain untested or blocked.
