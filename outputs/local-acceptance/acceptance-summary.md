# Conduit local acceptance summary

Plan provenance: PR #5, `docs/LOCAL_ACCEPTANCE_AND_CONTROL_PLANE_TEST_PLAN.md`, blob `dcd1cfdc4f93aa6039585a4abfb48d2c8034e026`.

Contract context: draft PR #6, `docs/CONTROL_PLANE_CONTRACT_V1.md`, blob `11abf723410b875bbb3a33a962641fe03b43b0a9`. The contract was read for context only; this run did not alter implementation to conform to it.

## Live identities

- GitHub repository: `camerontjs-dot/Conduit`
- Starting GitHub `main` SHA: `2c0f27c0008cb2cf8873685f909b385651ab63c9`
- Local starting product SHA: `90282eebbf48d996d7580f9404cc6f7ef0aaf2f2`
- Local reconciliation: clean product worktree, 20 commits behind; fast-forwarded
  normally to the GitHub `main` SHA without touching the separately dirty outer
  coordination repository.
- Acceptance branch: `research/control-plane-local-acceptance-20260829`
- Acceptance branch tip before this summary commit:
  `d86acfc88ccea755ae3bf7958a6de5e54fb911de`
- Focused fix branch: `fix/session-api-security-transport-20260829`
- Focused fix head: `ab99ac25ac45ec28a683f6abbe09002d9649ff18`
- Acceptance PR: [#7](https://github.com/camerontjs-dot/Conduit/pull/7)
- Focused fix PR: [#8](https://github.com/camerontjs-dot/Conduit/pull/8)

## Machine and build

- macOS 26.5.2 (25F84), arm64
- Xcode 26.6 (17F113), Swift 6.3.3
- Installed app: ad-hoc arm64 `dist/Conduit.app`, bundle identifier
  `dev.camerontjs.conduit`
- Fixed-build executable SHA-256:
  `f36a70658b2a2e57c0502669e488a95b72939a43c57895a9112ccb18551d4d26`
- Absolute-path `codesign --verify --deep --strict`: PASS
- Session API: `127.0.0.1:8750`; writes remained disabled

## Provider versions

Codex `codex-cli 0.145.0`; Claude `2.1.235`; Grok `1.0.13`; OpenCode
`1.18.15`; Antigravity (`agy`) `1.1.22`; Gemini `0.46.0`; Ollama `0.32.14`;
zsh `5.9`; tmux `3.6b`; tunnel-client `0.0.11+8d55683eeef80bc5e360d95abf4692454fafc615`.

## Outcome counts

The headline counts use one outcome row per material non-provider receipt
section and intentionally retain both original failures and fixed-build
results. Provider sublanes are reported separately so installed binaries are
not mistaken for adapter acceptance.

| Scope | PASS | FAIL | INCONCLUSIVE | BLOCKED | UNTESTED |
| --- | ---: | ---: | ---: | ---: | ---: |
| Non-provider material outcome rows | 25 | 4 | 2 | 7 | 3 |
| Provider binary/version probes (8 lanes) | 8 | 0 | 0 | 0 | 0 |
| Provider authentication beyond presence (6 structured lanes) | 0 | 0 | 0 | 0 | 6 |
| Provider task/turn/lifecycle lanes (8 installed/runtime lanes) | 0 | 0 | 0 | 8 | 0 |

These are evidence classifications, not a readiness score. The original
Session API failures remain in the count even though the focused fix now passes
its regression probes.

## Material observations

### Session API security and transport

OBSERVED on `main`: token mode was 0644; valid tokens embedded in a longer
value were accepted; one incomplete request blocked independent health work;
ambiguous framing returned a valid ping; oversized inputs reset connections.

OBSERVED on the fixed installed build: token mode 0600 with symlink refusal;
only exact/mixed-case Bearer credentials authenticated; malformed/overfull/
transfer/declared-oversize framing was rejected; oversized headers returned 413;
incomplete requests returned bounded 408 without blocking health; eight parallel
ping responses kept their IDs; a ninth saturated connection returned 503 and
the listener recovered after release.

The focused fix is isolated in PR #8 with regression tests and before/after
receipt; no architecture change was made.

### Read surface and tunnel

OBSERVED: the installed app exposed 11 MCP tools (six read-only annotations,
five state-changing advertisements) and returned bounded projects, sessions,
adapters, and separate MindGraph scopes. The actual Secure MCP Tunnel path
returned the same read surface plus status/events metadata while the configured
tunnel daemon was active. A synthetic connected create request was refused with
`Write tools are disabled` and did not produce a task ID.

OBSERVED: connected status/events for an existing detached PTY task preserved
observation metadata (`lifecycle: detached`, `turn.state: ambiguous`,
`provider_progress: unavailable`, `capture_closed`) rather than claiming
completion. The task was not created by this run and its identifiers/content
were not retained.

### Providers and planner

OBSERVED: all listed provider binaries are installed at the versions above.
This proves presence only. Provider authentication, task creation, runtime and
provider-thread identity, objective delivery, second-turn continuity,
approval, interrupt cancellation, reconnect, and fallback behavior were not
exercised because the local write gate stayed disabled.

OBSERVED: local Ollama inventory exited successfully, reported 10 rows, and
contained the declared `qwen3.5:9b` model; no model was loaded at the inventory
check. Deterministic planner tests (12 tests, 0 failures) enforce bounded
labelled context, malformed-proposal refusal, execution-intent refusal, stale
approval invalidation, and no launch before a matching approval. The planner
source targets loopback Ollama with `keep_alive: 0` and has no tool/MCP/task
interface; a live generation/unload observation was not performed.

### Lifecycle, persistence, approvals, and macOS boundaries

OBSERVED: tmux and PTY prerequisites are installed. An existing detached task
was readable through the connected path with recoverable/reconcile metadata.

BLOCKED: controlled detached creation, leave/reconnect, startup prompt
delivery, external exit, quietness, persistence/restart, duplicate-worker
detection, provider GUI-kill survival, tmux GUI-kill comparison, approval
restart, microphone/speech/screenshot permission, security-scoped access,
attachments, and inaccessible-path workflows. The app itself launched and its
listener smoke-tested; that does not answer worker/provider survival. The
computer-control session could not safely operate the relevant write/permission
switches, and no private data or OS permission was changed.

## Fixes

1. Session API transport/security hardening (PR #8):
   `f68f1b4`, `68b4cc9`, `0be92dd`, and `82b9574` narrow the token, bearer,
   framing, deadline, concurrency, and saturation defects. Regression evidence
   is in `session-api-security-fix.md`; the fixed app passed the focused probes
   and the full deterministic suite.
2. Acceptance-only receipts: this branch adds no product semantics. It adds
   sanitized, provenance-bearing local evidence for the baseline, read surface,
   planner, provider inventory, tunnel, and lifecycle blockers.

No consequential fix was merged by this run.

## Control-plane implications

OBSERVED: bounded local transport, explicit read/write annotations,
proposal-only planner semantics, and a connected read/reconciliation path are
demonstrable. Existing detached observations remain explicitly ambiguous where
provider progress is unavailable.

INFERRED: the current evidence supports keeping execution authority and
completion verification distinct from read-only observation. It does not select
a daemon, XPC service, helper, or other runtime-hosting architecture.

UNKNOWN: durable initial-objective delivery versus strict two-phase
create/start; task/runtime-attempt/provider-thread identity across startup;
approval and interrupt cancellation; persistence/reconnect; GUI-kill survival;
duplicate runtime creation; provider fallback; and account-level write
authorization. No contract decision was changed on the basis of absent evidence.

## Receipt index

- [local-environment.md](local-environment.md)
- [session-api-security.md](session-api-security.md)
- [mcp-read-surface.md](mcp-read-surface.md)
- [adapter-conformance.md](adapter-conformance.md)
- [orchestrate-ollama.md](orchestrate-ollama.md)
- [chatgpt-tunnel.md](chatgpt-tunnel.md)
- [lifecycle-persistence-boundaries.md](lifecycle-persistence-boundaries.md)
- Fixed-build receipt in [PR #8](https://github.com/camerontjs-dot/Conduit/pull/8)

## Privacy and verification boundary

No API key, bearer token, tunnel identifier, private prompt, MainFrame corpus
content, project/task identifier, transcript, or raw tunnel log was committed.
The deterministic suite does not prove provider success; an agent claim is not
task verification; a provider response is not completion; an interrupt request
is not observed cancellation; and quiet PTY output is not completion.
