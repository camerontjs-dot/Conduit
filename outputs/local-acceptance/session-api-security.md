# Session API security and transport baseline

Plan provenance: PR #5, `docs/LOCAL_ACCEPTANCE_AND_CONTROL_PLANE_TEST_PLAN.md`, blob `dcd1cfdc4f93aa6039585a4abfb48d2c8034e026`.

All authenticated probes read the existing local credential inside the probe process only. No token value, raw authorization header, tunnel identifier, project name, task history, or transcript was printed or saved.

## L1.1 — Token file mode

Test ID: L1.1
Date/time: 2026-08-29T19:41:12-04:00
Conduit SHA: `2c0f27c0008cb2cf8873685f909b385651ab63c9`
Branch: `research/control-plane-local-acceptance-20260829`
Installed-app/build identity: `dist/Conduit.app`, ad-hoc signed
Machine/environment: macOS 26.5.2 (25F84), arm64
Provider/runtime: built Conduit app; loopback Session API enabled, writes disabled
Preconditions: existing local token file; metadata-only inspection.
Action: inspected token-file mode without printing contents.
Expected: owner read/write only, typically mode 0600.
Observed: mode 0644. Source inspection shows `loadOrCreateToken()` writes atomically but does not set or repair owner-only permissions.
Result: FAIL
Evidence: metadata-only `stat` inspection; source review of `ConduitSessionAPIServer.loadOrCreateToken()`.
Negative findings: token contents were not printed, copied, or committed.
Follow-up: narrow permission creation/repair fix plus disposable-home regression coverage; consider rotation only after the safe terminal disposition is chosen.

## L1.3 — Exact bearer parsing

Test ID: L1.3
Date/time: 2026-08-29T19:43:14-04:00
Conduit SHA: `2c0f27c0008cb2cf8873685f909b385651ab63c9`
Branch: `research/control-plane-local-acceptance-20260829`
Installed-app/build identity: `dist/Conduit.app`, ad-hoc signed
Machine/environment: macOS 26.5.2 (25F84), arm64
Provider/runtime: local HTTP Session API on loopback
Preconditions: listener enabled; write gate disabled; harmless JSON-RPC `ping` only.
Action: sent exact, wrong, empty, mixed-case-scheme, prefix-embedded, suffix-extended, and second-credential bearer values.
Expected: only an exact credential authenticates.
Observed: exact credential returned HTTP 200; wrong and empty returned HTTP 401; a token with an unrelated prefix inside the bearer value returned HTTP 401. However `Bearer <valid-token>-suffix` and `Bearer <valid-token> extra` both returned HTTP 200. Mixed-case bearer scheme also returned HTTP 200.
Result: FAIL
Evidence: sanitized local HTTP probe; original source uses substring containment after an `Authorization:` prefix check.
Negative findings: no credential content was emitted.
Follow-up: parse one authorization credential structurally and compare the bearer value with a constant-time exact comparison; add suffix and second-credential regression cases.

## L1.4 — Unauthenticated health boundary

Test ID: L1.4
Date/time: 2026-08-29T19:43:14-04:00
Conduit SHA: `2c0f27c0008cb2cf8873685f909b385651ab63c9`
Branch: `research/control-plane-local-acceptance-20260829`
Installed-app/build identity: `dist/Conduit.app`, ad-hoc signed
Machine/environment: macOS 26.5.2 (25F84), arm64
Provider/runtime: local HTTP Session API on loopback
Preconditions: listener enabled; no task/session body requested.
Action: requested unauthenticated `/healthz` and unauthenticated MCP `ping`.
Expected: health follows declared policy; MCP rejects unauthenticated requests.
Observed: `/healthz` returned HTTP 200 with `ok`; unauthenticated MCP returned HTTP 401.
Result: PASS
Evidence: sanitized local HTTP probe.
Negative findings: `/readyz` and protected-resource metadata remain to be recorded separately.
Follow-up: preserve this narrow health policy while hardening the protected endpoint.

## L1.5 — Request framing and bounds

Test ID: L1.5
Date/time: 2026-08-29T19:44:38-04:00
Conduit SHA: `2c0f27c0008cb2cf8873685f909b385651ab63c9`
Branch: `research/control-plane-local-acceptance-20260829`
Installed-app/build identity: `dist/Conduit.app`, ad-hoc signed
Machine/environment: macOS 26.5.2 (25F84), arm64
Provider/runtime: local HTTP Session API on loopback
Preconditions: listener enabled; harmless authenticated JSON-RPC `ping`; all oversized probes bounded to about 1.1 MiB.
Action: sent malformed `Content-Length`, a declared body longer than bytes delivered, a declared body shorter than bytes delivered, oversized header, and oversized body probes.
Expected: malformed framing is refused; oversized input is bounded without crashing the listener.
Observed: malformed `Content-Length`, shorter-than-declared body, and longer-than-declared body each returned HTTP 200 for the valid ping. Oversized header/body connections were reset; a subsequent health request returned HTTP 200.
Result: FAIL for framing validation; INCONCLUSIVE for exact oversized-refusal status, with bounded connection reset and healthy listener observed.
Evidence: sanitized raw-socket probes; no input exceeded approximately 1.1 MiB.
Negative findings: the listener did not crash in the bounded oversized probes.
Follow-up: enforce valid, unique, bounded content length and exact body framing before JSON parsing; retain a bounded oversized-input regression.

## L1.6 — Slow/incomplete connection

Test ID: L1.6
Date/time: 2026-08-29T19:43:52-04:00
Conduit SHA: `2c0f27c0008cb2cf8873685f909b385651ab63c9`
Branch: `research/control-plane-local-acceptance-20260829`
Installed-app/build identity: `dist/Conduit.app`, ad-hoc signed
Machine/environment: macOS 26.5.2 (25F84), arm64
Provider/runtime: local HTTP Session API on loopback
Preconditions: listener enabled; one synthetic socket only.
Action: sent a request header declaring a body, withheld that body, then issued an unauthenticated health request with a one-second timeout; closed the held socket and retried health.
Expected: stalled request times out while other callers remain serviceable.
Observed: concurrent health request timed out. After closing the held socket, health returned HTTP 200.
Result: FAIL
Evidence: bounded synthetic-socket probe; the original listener has a serial accept/read loop with no read deadline.
Negative findings: the app remained responsive enough to serve health after the held socket closed.
Follow-up: add per-connection deadline and bounded concurrent handling before expanding remote control authority.

## L1.7 — Concurrent local callers

Test ID: L1.7
Date/time: 2026-08-29T19:45:31-04:00
Conduit SHA: `2c0f27c0008cb2cf8873685f909b385651ab63c9`
Branch: `research/control-plane-local-acceptance-20260829`
Installed-app/build identity: `dist/Conduit.app`, ad-hoc signed
Machine/environment: macOS 26.5.2 (25F84), arm64
Provider/runtime: local HTTP Session API on loopback
Preconditions: listener enabled; harmless authenticated `ping` only.
Action: issued eight concurrent requests with distinct JSON-RPC IDs.
Expected: bounded service with no response cross-talk.
Observed: all eight returned HTTP 200 with matching reply IDs; total probe time was 4.2 ms. L1.6 separately proves this is not robust concurrent service under a stalled peer.
Result: PASS for fast-request reply isolation; FAIL for head-of-line resistance by L1.6.
Evidence: sanitized concurrent local probe.
Negative findings: caller-identity isolation for writes was not exercised because the current app write gate remained disabled.
Follow-up: rerun after bounded-concurrency repair and add write-principal isolation coverage.

## L1.8 — Current caller identity scope

Test ID: L1.8
Date/time: 2026-08-29T19:46:00-04:00
Conduit SHA: `2c0f27c0008cb2cf8873685f909b385651ab63c9`
Branch: `research/control-plane-local-acceptance-20260829`
Installed-app/build identity: `dist/Conduit.app`, ad-hoc signed
Machine/environment: macOS 26.5.2 (25F84), arm64
Provider/runtime: local HTTP Session API on loopback
Preconditions: listener enabled; current Session API write gate observed disabled.
Action: inspected listener identity storage and attempted a temporary, non-mutating write-gate test through the built-app settings UI.
Expected: current identity scope documented without launching a runtime.
Observed: the listener stores the most recent `initialize.clientInfo` in listener-global `peerIdentity`/timestamp fields. With each connection closed and no per-request session ID, this is not per-connection identity. The write gate remained disabled; direct UI switch actions were unavailable in the current computer-control session, so no enabled-write probe ran.
Result: INFERRED (source-supported); enabled-write behavior BLOCKED.
Evidence: source inspection plus read-only built-app settings observation.
Negative findings: no write, task creation, prompt, interrupt, approval, or capacity state changed.
Follow-up: add a testable authenticated-principal boundary and verify cross-client isolation when a controlled write-gate test can run.
