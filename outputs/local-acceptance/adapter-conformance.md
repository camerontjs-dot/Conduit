# Provider adapter conformance receipt

Plan provenance: PR #5, `docs/LOCAL_ACCEPTANCE_AND_CONTROL_PLANE_TEST_PLAN.md`, blob `dcd1cfdc4f93aa6039585a4abfb48d2c8034e026`.

This matrix separates installed-binary evidence from provider authentication,
task lifecycle, and answer-verification evidence. No provider credentials were
extracted and no provider task was started.

## Test context

- Test date/time: 2026-08-30T01:07:43Z
- Conduit SHA: `2c0f27c0008cb2cf8873685f909b385651ab63c9` (acceptance source)
- Branch: `research/control-plane-local-acceptance-20260829`
- Installed-app/build identity: fixed `dist/Conduit.app` was running for the
  read-only checks; no adapter runtime was created
- Machine/environment: macOS 26.5.2 (25F84), arm64; writes disabled
- Provider/runtime: installed CLI binaries and the declared Conduit adapter
  catalog
- Preconditions: version probes used only `--version`/`-V`; output was reduced
  to one version line and presence/exit metadata.

## Installed provider inventory

| Lane | Installed version | Binary probe | Authentication | Task/lifecycle lane |
| --- | --- | --- | --- | --- |
| Codex app-server | `codex-cli 0.145.0` | PASS (exit 0) | UNTESTED | BLOCKED by disabled write gate |
| Claude stream JSON | `2.1.235 (Claude Code)` | PASS (exit 0) | UNTESTED | BLOCKED by disabled write gate |
| Grok ACP | `grok 1.0.13 (5e9a58528b76) [stable]` | PASS (exit 0) | UNTESTED | BLOCKED by disabled write gate |
| OpenCode HTTP/SSE | `1.18.15` | PASS (exit 0) | UNTESTED | BLOCKED by disabled write gate |
| Antigravity stream JSON (`agy`) | `1.1.22` | PASS (exit 0) | UNTESTED | BLOCKED by disabled write gate |
| Gemini ACP | `0.46.0` | PASS (exit 0) | UNKNOWN (no credential inspection) | BLOCKED by disabled write gate |
| Shell / PTY (`/bin/zsh`) | `zsh 5.9 (arm64-apple-darwin25.0)` | PASS (exit 0) | not applicable | BLOCKED for Conduit task lane |
| Ollama local service | `0.32.14` | PASS (exit 0) | local inventory reachable | BLOCKED for worker lane; planner is separate |

The tmux prerequisite was present at `tmux 3.6b`; no Conduit tmux session was
created for this matrix.

The connected `conduit_list_adapters` read surface concurrently reported seven
declared rows with backend counts ACP 2, app-server 1, HTTP-server 1, PTY 1,
and structured-CLI 2. This is a declaration, not a health check.

## Common conformance lanes

For every installed provider above, the following lanes are BLOCKED or
UNTESTED in this run because Session API writes remained disabled and the
computer-control session could not safely toggle the write setting:

- availability/authentication beyond binary/version presence;
- task creation and runtime-attempt identity;
- provider thread/session identity;
- initial-objective delivery and duplicate-delivery behavior;
- exact `CONDUIT_ADAPTER_READY` answer attribution;
- second-turn continuity;
- approval/input-required state;
- interrupt request versus observed cancellation;
- resume/reconnect and duplicate-worker detection.

No provider completion claim was made from an agent process, quiet PTY, or
version output. No provider was called merely to produce a ceremonial result.

## Preserved negative boundary

The existing Session API catalog is readable and advertises the adapter/write
surfaces, but the local gate rejects writes before dispatch. Therefore these
installed providers are not counted as passing adapter acceptance. This is a
machine-bound blocker, not evidence that any provider is unavailable.

## Scope boundary

OBSERVED: all listed provider binaries are present at the versions above, and
the declared adapter catalog is readable through the connected read surface.

INFERRED: the machine has the prerequisites to begin adapter conformance once a
controlled write fixture exists, subject to each provider's independent auth.

UNKNOWN: provider authentication, task/runtime identity, objective delivery,
structured answer filtering, approvals, interrupts, reconnect, and fallback
behavior remain untested.
