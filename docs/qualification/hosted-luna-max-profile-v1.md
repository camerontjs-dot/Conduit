# Hosted supervision: Luna Max pre-run binding v1

Status: PREPARED_PROFILE_REQUEST_ONLY. This companion neither grants local setup
nor changes the frozen #89 protocol, fixture bytes, scoring or trial budgets.
Primary owner: #89/#9 GitHub-side hosted-supervision owner. Local preparation
stays with worker `01a0e0a3-3173-70d3-8a1d-f05ee65819c6` and the Supervisor.
Do not start a duplicate preparation worker or a ChatGPT Work task.

## Decision and reviewed authority

The frozen protocol at #89 `89733c67556bbf1fde7e31edffc229e527321815`
(blob `b90f169e59efa391702218df3d642ea56ff74941`, SHA-256
`f5ceec61c77e541be507a9d4131e475437d80d6833164c78856dfd71b4c0f1cf`)
requires a model/profile binding before execution but does not prescribe Sol.
Gate 4 requires the same build/provider/profile, fixtures and objectives across
L/F/F/L. No trial has been reported. Selecting the operator's requested Luna Max
before the first smoke is therefore a parameter binding, not a Sol-vs-Luna study.
No protocol or fixture replacement is justified. Do not revise the frozen files.

Reviewed #91 remains `3e557adb98bdf32c7c3e39e2c3d215b24ea1ef4e` and #92 kit
remains `e1c6e41e5a74a53e687b6ed42e3cd3bb858313f7`. #92's source-renewal guard
changes only the AppModel source-review record after exact startup-delta checks;
it does not implement a model/effort route. Preserve the kit, failed #91 and
all prior receipts. Do not rerun renewal or the full build merely for a profile
preference change.

Selected later setup subject, supplied by the local return, not read remotely:

- child: `60fb71939509ca70dfa67441fdfa50ef11c9e499`;
- tree: `e5c2360c902183e965d57b65b0060ec1c1a6d4a8`;
- executable SHA-256: `84bc16f681d340fa6d634f97f47a82f1ecd8e92a8807f613bd21d8bac3c42d07`.

The child is unpushed. A recorded build/test pass is not a launched runtime or
hosted qualification. This companion's parent is #89, not the private child;
never build/install this companion as though it were the selected runtime.

The operator-supplied latest read-only preflight digest is
`9ddf8d39b339cb0b3e6d07cd2e7e5283c2a2287f9ba9fe7d5b52abf9ad35bd11`.
Its safe return reports READY_FOR_OPERATOR_SETUP_REQUEST only, no candidate
listener/process, writes off, five unchanged fixtures with no results, and
unknown auth/connection. This is reported provenance; neither private receipt
bytes nor the local child were inspected in this source pass. Do not carry the
older observation of #91 listening at 18750 forward as current liveness.

## Requested profile, not an observed capability

Requested native model is `gpt-6-luna`, reasoning effort is literal `max`.
This interpretation uses the GPT-6 context and the official Luna model page,
which documents that model ID and `max`; it is not evidence of this account's
Codex entitlement. It is not a model called `gpt-6-luna-max`, a Pro reasoning
mode request, or an instruction to select the highest available effort.

Official references checked for this packet:
- https://developers.openai.com/api/docs/models/gpt-6-luna
- https://developers.openai.com/codex/app-server (Models / model/list)
- https://developers.openai.com/codex/config-reference (model_reasoning_effort)

The App Server reference explicitly makes model/effort availability dependent
on the installed client and account. Require an exact advertised model and
literal max option from that surface; API documentation alone is insufficient.

Source inspected at #92: `CodexAppServerClient.swift` blob
`f89df0b48d33b4a7c1ce1212665489d38877f407` starts stdio app-server with no
`--profile` argument; `CodexAppServerProtocol.swift` blob
`d991735a5ac030d20b62f0348ed4d738e26ce2d1` sends an optional model in thread/start
but no effort in turn/start. Thus merely creating a named TOML profile does not
prove it is selected. Inspect the effective configuration under the actual
candidate invocation, dedicated Codex home, fixture cwd, managed/project settings,
and any Conduit model override. These proposed values are not applied here:

```toml
model = "gpt-6-luna"
model_reasoning_effort = "max"
```

Do not assume inherited configuration, a display label, or successful login
proves effective max or successful generation. Before the smoke require supported
metadata and effective readback; during the separately authorized smoke preserve
actual provider/thread/turn model and effort evidence. Missing runtime telemetry
stays UNKNOWN; no worker-written self-description substitutes for provider data.

## Invariants and resource boundary

Use the same exact requested/effective profile for the smoke and all four pilot
tasks. Preserve the existing five fixtures, nonces, permitted output and missing-
evidence check. Delegation stays forbidden despite the general subagent preference.
Keep one active test turn, five total tasks, at most three turns per task, 180s
observation per turn, 60s teardown observation, and L/F/F/L order. These are
observation bounds, not a guaranteed server kill or total quota cap. On timeout
follow the frozen stop/cleanup rules; never increase time to rescue Max results.

Use the existing Codex ChatGPT-subscription route within its allowance; do not
switch to API-key billing, paid top-ups, premium service tiers or another backend.
No quota equivalence to Sol is claimed. If local inspection establishes material
extra spend/resource needs, request the concrete decision: approve that named
route/tier/budget change or keep this run blocked. Unknown entitlement or absent
max means BLOCKED_PROFILE_AVAILABILITY, not fallback to Sol or xhigh. An alias
mapping that differs from this requested ID must be reconciled before binding.
Any post-first-trial profile change or protocol/budget change requires a separately
identified successor, with prior attempts preserved and not pooled.

## Portable consistency check

Run this companion separately from the runtime and frozen apparatus:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tools/hosted-profile-v1 -p test_check.py -v
python3 tools/hosted-profile-v1/check.py tools/hosted-profile-v1/request.json
# Only after separately authorized local observation, against redacted snapshots:
python3 tools/hosted-profile-v1/check.py tools/hosted-profile-v1/request.json --observation /path/to/redacted-observation.json
```

The second command validates the prospective packet only. It MUST NOT require
inventing observations to pass. The third accepts a separately authored redacted
`hosted-luna-profile-observation-v1` object with these explicit fields:

- `runtime_subject`: exact child/tree/binary pins from request.json;
- `source`: `effective_config_readback`; `observed_at_utc`: timezone-aware stamp;
- `cli_sha256`, `invocation_scope_sha256`, `model_catalog_sha256`,
  `effective_config_sha256`: identities of the retained non-secret observations;
- `model_catalog`: complete model/list projection with `data` and explicit
  terminal `nextCursor: null`; preserve original pages/hashes privately when
  pagination needs consolidation. Do not turn a partial page into a complete one;
- `effective_profile`: `model`, `reasoning_effort`, `provider_id`, `usage_route`,
  `service_tier`, `conduit_model_override`. Unknown values are not defaults.
  Null override means absence was observed. `default`/`standard` tier means
  non-premium behavior was established, not guessed from missing config.

The checker compares supplied declarations only. It cannot authenticate a
capture, verify the referenced private file hashes, inspect CLI/candidate bytes,
prove billing/authentication, evaluate freshness, or grant consent. Every output,
including success, reports execution_authorized=false and
ready_for_hosted_qualification=false. Full #89 catalogue, isolation, consent and
runtime gates remain separate. It writes no files and makes no network/process
calls. No real observation fixture is bundled; positive tests are synthetic.

## One next-owner packet, not repeated setup

Next owner is the Supervisor coordinating the existing preparation worker.
The next local requirement is an explicit operator setup authorization, followed
by non-secret resolution of exact model/max support and the effective profile
in the existing dedicated home. If login is necessary, the operator completes
normal login/MFA/consent. Keep credentials and raw account responses local.

After that separate authorization, an assistant may stage candidate-only profile
configuration, verify existing fixture/app identities, and launch the exact child
at an available reserved loopback port (18750 preferred, ownership rechecked).
An absent candidate needs a fresh controlled launch, not a stop of a historical
PID. Preserve operator 8750/app/tunnel and its settings. No rebuild/retest is
required solely for this companion; source/build drift needs its own reason and
new identity before qualification.

A separately authorized computer-use assistant may prepare the named qualification
connection/tunnel `conduit-hosted-qualification-20260926`, but connection consent
and candidate-only write-gate approval remain operator decisions. Do not repoint
the operator connection or script around the gate. If current tooling cannot
prove effective max without product changes, return that exact gap to the GitHub
owner; do not patch the private child opportunistically.

Append a new readiness/launch manifest, preserving predecessors. Bind #89's
commit and all three hashes, selected child/tree/binary, this companion's exact
commit/hashes, requested and observed profile plus evidence limits, existing
fixture hashes, actual listener/process/state isolation, connection identity and
catalogue comparisons, resource decision, consent/write-gate observations,
measurement policy and cleanup scope. Preserve queued/delivered = no resend;
create idempotency is not send idempotency. Local HTTP is not hosted evidence.

Stop preparation before hosted catalogue/smoke/pilot execution. Remote source
review of the private mechanical child remains unavailable until separately
authorized publication; this packet does not push it. No source repair or new
study is justified solely by the model preference.
