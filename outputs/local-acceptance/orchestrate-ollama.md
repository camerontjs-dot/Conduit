# Orchestrate / Ollama planner boundary receipt

Plan provenance: PR #5, `docs/LOCAL_ACCEPTANCE_AND_CONTROL_PLANE_TEST_PLAN.md`, blob `dcd1cfdc4f93aa6039585a4abfb48d2c8034e026`.

This receipt tests the existing planner boundary without turning planner output
into execution authority. No planner request was sent from the UI because the
current computer-control session could not safely operate the required
project-selection controls, and no task was created merely to obtain a model
response.

## Test context

- Test date/time: 2026-08-30T01:00:23Z (CLI/static checks); focused planner
  XCTest at 2026-08-29T21:00:16Z
- Conduit SHA: `2c0f27c0008cb2cf8873685f909b385651ab63c9` for the acceptance
  source branch; installed app used elsewhere in this run was the fixed build
  identified in `mcp-read-surface.md`
- Branch: `research/control-plane-local-acceptance-20260829`
- Machine/environment: macOS 26.5.2 (25F84), arm64; local Ollama endpoint is
  configured at `127.0.0.1:11434`
- Provider/runtime: Ollama local service and Conduit `LocalOllamaPlanner`
- Preconditions: no planner task, worker, approval, or provider turn was live

## L7.1 — Local Ollama availability

Test ID: L7.1

Action: ran `ollama --version`, `ollama list`, and `ollama ps`; only exit
status/header/row-count metadata was retained.

Expected: the configured local service is reachable without requiring a remote
fallback; model inventory remains local and bounded.

Observed: `ollama --version` returned `0.32.14` with exit 0. `ollama list`
returned exit 0 with 10 model rows and included the declared `qwen3.5:9b`
planner model (boolean presence check only). `ollama ps` returned exit 0 with
zero currently loaded rows. Other model names were deliberately not saved.

Result: PASS for local service/inventory availability; UNTESTED for a planner
generation turn.

Evidence: sanitized command metadata; no model output or credentials.

Negative findings: an inventory command is not proof that the configured
planner model can generate a valid response.

Follow-up: run one deterministic planner request only with a controlled,
synthetic project selection and record the visible response separately from
proposal validation.

## L7.2 — Planner boundary and proposal validation

Test ID: L7.2

Action: ran the focused `OrchestrationProposalTests` target with the Xcode
developer directory selected explicitly.

Expected: bounded context, trust/citation labels, malformed proposal refusal,
execution-intent refusal, stale approval invalidation, and no launch before a
matching approval are deterministic.

Observed: 12 tests executed with 0 failures. The tests cover separate
`knowledge`/`projects` context scopes, token-budget rejection, required labels,
declared JSON-envelope-only decoding, project/scope/execution-intent refusal,
approval-token invalidation, and reducer refusal to record a launch before
matching approval. The fixture planner returns a proposal without starting a
provider.

Result: PASS

Evidence: `OrchestrationProposalTests` XCTest output; source contract in
`OrchestrationPlanner.swift`, `OrchestrationProposal.swift`, and
`OrchestrationPolicy.swift`.

Negative findings: fixture and policy tests do not prove a live Ollama turn or
provider authentication.

Follow-up: retain planner output as a proposal/review artifact only.

## L7.3 — Loopback/no-fallback and unload declaration

Test ID: L7.3

Action: inspected the installed-source planner path and the Orchestrate view.

Expected: planner access is local-only, has no tool/MCP/task authority, uses a
bounded request, and requests model release without stopping the shared Ollama
daemon.

Observed: `LocalOllamaPlanner` targets only
`http://127.0.0.1:11434/api/generate`, sets a 45-second timeout, `stream: false`,
`think: false`, `keep_alive: 0`, and a 256-token prediction cap. The planner
protocol has no filesystem, shell, MCP, task, permission, or approval method.
The UI labels the backend as local Ollama, states that it unloads its model
after each response, and keeps the worker-launch control disabled. This is
source/UI evidence, not a live request observation.

Result: PASS for declared boundary; INCONCLUSIVE for runtime unload behavior.

Evidence: source inspection; no planner output was captured.

Negative findings: `keep_alive: 0` and the UI statement do not prove that an
actual model was unloaded on this machine during this run.

Follow-up: observe `ollama ps` before/after a synthetic planner request when a
safe UI path is available; do not stop or reconfigure the shared service.

## L7.4 — No task creation from planner output

Test ID: L7.4

Action: checked the reducer/policy path and the run boundary without enabling
Session API writes or invoking a provider.

Expected: planner output alone never creates or launches a worker.

Observed: source and focused tests require an explicit matching approval before
the reducer records a launch; the Orchestrate view's “Start one worker” control
is disabled. No task, runtime, prompt, approval, or provider process was
created by this run.

Result: PASS for deterministic local boundary; UNTESTED for a live UI
interaction sequence.

Evidence: `OrchestrationProposalTests`; source/UI inspection; Session API
write gate remained disabled.

Negative findings: no live planner response was available to test the complete
visible-text-to-review sequence.

Follow-up: preserve the explicit approval boundary in any future integration
work.

## Scope boundary

OBSERVED: the local Ollama service is installed and reachable for inventory;
the source/UI contract is loopback-only and proposal-only; deterministic tests
enforce bounded labelled context and approval-gated launch semantics.

INFERRED: planner output is not execution authority and does not provide an
unintended remote fallback in the current implementation path.

UNKNOWN: live generation/authentication, observed unload after a response, and
end-to-end UI interaction remain untested.
