# Session API security hardening receipt

Plan provenance: PR #5, `docs/LOCAL_ACCEPTANCE_AND_CONTROL_PLANE_TEST_PLAN.md` at blob `dcd1cfdc4f93aa6039585a4abfb48d2c8034e026`.

This receipt records a focused L1 transport/security repair, not general
control-plane readiness. The preserved pre-fix observations are in
[PR #7](https://github.com/camerontjs-dot/Conduit/pull/7), including the
original 0644 token mode, bearer-suffix acceptance, and head-of-line blocking.

All authenticated probes read the existing local credential inside the probe
process only. No token value, authorization header, tunnel identifier, project
name, task history, or transcript was printed or saved.

## Fixed object under test

- Base: `2c0f27c0008cb2cf8873685f909b385651ab63c9` (`main`)
- Product change: `82b9574b89a4c90f78136032e5a4139eff7c8475`
- Branch: `fix/session-api-security-transport-20260829`
- Included focused commits: `f68f1b4`, `68b4cc9`, `0be92dd`, `82b9574`
- Installed app/build identity: ad-hoc-signed `dist/Conduit.app`; executable
  SHA-256 `f36a70658b2a2e57c0502669e488a95b72939a43c57895a9112ccb18551d4d26`
- Machine/environment: macOS 26.5.2 (25F84), arm64; Swift 6.3.3
- Provider/runtime: built Conduit app, IPv4 loopback Session API enabled;
  writes remained disabled throughout

## Deterministic regression gate

Test ID: L0.2/L0.3-FIX
Date/time: 2026-08-30T00:20:25Z
Conduit SHA: `82b9574b89a4c90f78136032e5a4139eff7c8475`
Branch: `fix/session-api-security-transport-20260829`
Installed-app/build identity: as above
Machine/environment: as above
Provider/runtime: local build and unit/self-test targets
Preconditions: clean product worktree at the fixed object.
Action: ran `scripts/test.sh` and `scripts/build-app.sh`; verified the app
signature with `codesign --verify --deep --strict`.
Expected: deterministic suite and production build pass.
Observed: `scripts/test.sh` exited 0 with 432 self-test assertions and 276
XCTest cases, 0 failures. The pre-existing three warning classes produced 72
warning lines. `scripts/build-app.sh` exited 0; code-sign verification passed.
Result: PASS
Evidence: command exit statuses and executable digest above.
Negative findings: no warning was reclassified as a test failure; no runtime
or Session API write was created.
Follow-up: address the existing warnings separately; they are outside this
transport fix.

## L1.1 — token-file permission creation and repair

Test ID: L1.1-FIX
Date/time: 2026-08-30T00:20:25Z
Conduit SHA: `82b9574b89a4c90f78136032e5a4139eff7c8475`
Branch: `fix/session-api-security-transport-20260829`
Installed-app/build identity: as above
Machine/environment: as above
Provider/runtime: built Session API listener
Preconditions: existing local token file; synthetic temporary files for unit
coverage; token contents never emitted.
Action: launched the fixed app, inspected mode metadata only, and ran the
token creation/repair/symlink-refusal unit test.
Expected: regular token file is owner read/write only; symlinks are refused.
Observed: installed token mode was `0600`. Unit coverage passed for new-file
creation, repair from `0644`, and refusal of a synthetic symbolic link.
Result: PASS
Evidence: metadata-only mode inspection and
`SessionAPITransportSecurityTests.testTokenCreationAndExistingFileRepairAreOwnerOnly`.
Negative findings: no token was printed, copied, rotated, or committed.
Follow-up: rotation policy remains an operator decision and was not changed.

## L1.3 — exact bearer parsing

Test ID: L1.3-FIX
Date/time: 2026-08-30T00:20:25Z
Conduit SHA: `82b9574b89a4c90f78136032e5a4139eff7c8475`
Branch: `fix/session-api-security-transport-20260829`
Installed-app/build identity: as above
Machine/environment: as above
Provider/runtime: local HTTP Session API; harmless JSON-RPC `ping`
Preconditions: listener enabled; writes disabled.
Action: sent exact, mixed-case-scheme, suffix-extended, second-credential,
and duplicate-authorization values without recording credential material.
Expected: only one exact bearer value authenticates; scheme matching remains
case-insensitive.
Observed: exact and mixed-case-scheme requests returned HTTP 200. Suffix,
second-credential, and duplicate-authorization requests returned HTTP 401.
Result: PASS
Evidence: installed-app raw-socket probe plus
`SessionAPITransportSecurityTests.testExactBearerAuthorizationRejectsExtendedAndDuplicateCredentials`.
Negative findings: no Session API write, task, prompt, interrupt, or approval
was exercised.
Follow-up: enabled-write caller-principal isolation remains blocked by the
local write gate and is not implied by this result.

## L1.5 — framing and request bounds

Test ID: L1.5-FIX
Date/time: 2026-08-30T00:21:01Z
Conduit SHA: `82b9574b89a4c90f78136032e5a4139eff7c8475`
Branch: `fix/session-api-security-transport-20260829`
Installed-app/build identity: as above
Machine/environment: as above
Provider/runtime: local HTTP Session API; harmless `ping`
Preconditions: listener enabled; all inputs synthetic and bounded.
Action: sent malformed content length, overfull framing, transfer encoding,
a 17 KiB header, and a declared 1,048,577-byte body without sending that body.
Expected: malformed or ambiguous framing is refused; oversized input is
bounded without listener loss.
Observed: malformed content length, overfull framing, transfer encoding, and
declared oversized body each returned HTTP 400. The oversized header returned
HTTP 413. Health remained HTTP 200 after the probes.
Result: PASS
Evidence: sanitized installed-app raw-socket probes; unit coverage for bounded
single content length parsing.
Negative findings: this does not establish behavior for every HTTP extension;
chunked transfer encoding is deliberately rejected rather than supported.
Follow-up: keep any future HTTP feature work behind dedicated conformance
tests.

## L1.6/L1.7 — stalled and concurrent clients

Test ID: L1.6-L1.7-FIX
Date/time: 2026-08-30T00:21:01Z
Conduit SHA: `82b9574b89a4c90f78136032e5a4139eff7c8475`
Branch: `fix/session-api-security-transport-20260829`
Installed-app/build identity: as above
Machine/environment: as above
Provider/runtime: local HTTP Session API; harmless `ping`
Preconditions: one synthetic incomplete request and eight independent,
authenticated read-only pings.
Action: withheld a declared request body while requesting `/healthz` from a
second client; then sent eight concurrent pings with distinct IDs.
Expected: a stalled connection does not block independent health work, reaches
a bounded timeout, and concurrent callers do not cross-talk.
Observed: health returned HTTP 200 during the stalled request; the stalled
request returned HTTP 408 after 2.0 seconds. All eight pings returned HTTP
200 with matching IDs.
Result: PASS
Evidence: sanitized installed-app raw-socket and parallel-client probes.
Negative findings: this proves transport servicing only, not write-principal
isolation or provider completion semantics.
Follow-up: exercise write-principal isolation only with an explicitly enabled,
controlled write-gate setup.

## L1.5/L1.6 — bounded saturation refusal

Test ID: L1.5-L1.6-CAPACITY-FIX
Date/time: 2026-08-30T00:21:01Z
Conduit SHA: `82b9574b89a4c90f78136032e5a4139eff7c8475`
Branch: `fix/session-api-security-transport-20260829`
Installed-app/build identity: as above
Machine/environment: as above
Provider/runtime: local HTTP Session API
Preconditions: eight synthetic incomplete sockets held inside the configured
connection bound; no task or provider process involved.
Action: requested `/healthz` as a ninth client, repeated the condition five
times, then closed the held sockets and retried health.
Expected: overload is bounded and explicit; listener recovers after release.
Observed: the ninth request returned HTTP 503 in the final probe and in all
five repetition probes. After releasing the held sockets, health returned HTTP
200.
Result: PASS
Evidence: installed-app synthetic-socket receipt.
Negative findings: during hardening, earlier candidate commits sometimes
reset the over-capacity client instead of delivering 503. That failure was
preserved and led to the final bounded-input drain in `82b9574`; it is not
counted as a passing result.
Follow-up: retain saturation behavior in a future dedicated listener
integration target if the test target is expanded to include the app module.

## Scope boundary

OBSERVED: the listed L1 transport failures on `main` are repaired by the
fixed object above.

INFERRED: bounded loopback transport lowers risk for future control-plane
work, but does not establish durable task ownership, objective delivery,
provider lifecycle, approval recovery, or GUI-kill behavior.

UNKNOWN: enabled-write caller isolation, all provider adapter conformance,
tmux/PTY lifecycle, persistence/restart, macOS permission boundaries, Ollama
planner boundaries, and real hosted tunnel acceptance were not exercised by
this receipt.
