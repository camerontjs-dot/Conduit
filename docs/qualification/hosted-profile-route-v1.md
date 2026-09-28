# Hosted profile route: scoped metadata before candidate launch

Status: PREPARED_FOR_SCOPED_METADATA_ONLY. This is an offline preparation
companion to frozen #93, not a runtime build, local dispatch, or new experiment.
Supervisor retains dispatch; existing local owner is
`01a0e0a3-3173-70d3-8a1d-f05ee65819c6`.

## Reconciled authority

The concrete bounded setup is already approved. Dedicated-home authentication
success at 2026-09-28T00:58:55Z remains attributed local evidence, receipt
`a00a94659981b393b48392f9af4adcdad080d5ea7000f4096b4a95ce74534753`.
Do not repeat login or approval without new contrary evidence. The earlier
`STOPPED_CAP_EXCEEDED` receipt
`02cf370407acbd7c4ddece41d18a4da8600d906b0ea7e4df301a990dbf3519ea`
was not an authentication failure.

The new returned receipt
`7f5afc2f418234ff9ab02c512c0edd000e6c2656928f87a1d7b6bc088529f688`
reports BLOCKED_BEFORE_PROFILE_OBSERVATION at 2026-09-28T01:28:39Z:
zero App Server starts, metadata requests, threads and turns. Preserve worker
clock 364s against 360s, the separate 18s turn-clock overrun, and final-turn
482509ms duration; do not combine clocks or relabel this as model rejection.
Reported Sol/absent-effort file values are not effective config/read results.
Reported signing results remain mixed, not an accepted signing identity.
The lead inspected private receipt bytes, not this GitHub owner. Nothing here
claims access to the unpushed child, credentials, private logs or machine state.

Frozen source and apparatus remain:
- #89: `89733c67556bbf1fde7e31edffc229e527321815`, tree
  `57f627577c098f95926322cb3171414c5fab986a`, protocol SHA-256
  `f5ceec61c77e541be507a9d4131e475437d80d6833164c78856dfd71b4c0f1cf`;
- #91: `3e557adb98bdf32c7c3e39e2c3d215b24ea1ef4e`;
- #92: `e1c6e41e5a74a53e687b6ed42e3cd3bb858313f7`;
- #93: `845f0368b22d1c8b095d59c8010a5685d2876c57` (this companion's parent).

Selected runtime is still receipt-supplied local child
`60fb71939509ca70dfa67441fdfa50ef11c9e499`, tree
`e5c2360c902183e965d57b65b0060ec1c1a6d4a8`, executable SHA-256
`84bc16f681d340fa6d634f97f47a82f1ecd8e92a8807f613bd21d8bac3c42d07`.
Never build/install this companion or substitute it for that subject.

## Exact published source route and limits

Reviewed at #92, not the private child:
- AppModel.swift blob `a90a8b77efae10cf5a16ae56483e06884a5b518b`:
  `start` passes `descriptor.projectPath` and `descriptor.agent.model` into
  `attachStructuredAdapter`; `setModelSelection` saves `settings.agents[].model`.
- CodexAppServerClient.swift blob `f89df0b48d33b4a7c1ce1212665489d38877f407`:
  stdio launch uses arguments `["app-server"]`, supplied cwd, and no explicit
  Process.environment assignment in that spawn path. No named-profile flag.
- CodexAppServerProtocol.swift blob `d991735a5ac030d20b62f0348ed4d738e26ce2d1`:
  thread/start includes model only when nonempty; turn/start contains threadId
  and input, not effort. The client handshake automatically starts/resumes a
  thread. Therefore calling the Conduit adapter's start is NOT a zero-thread probe.
- #92 renewal recipe only updates the AppModel source-evidence record. It adds
  no model/effort routing. Child source equality still requires local confirmation.

No missing product capability has been demonstrated. The configuration route
under existing setup authorization is to preserve the dedicated home and all
other settings, then bind its effective user-level configuration to:

```toml
model = "gpt-6-luna"
model_reasoning_effort = "max"
```

Do not append duplicate keys or edit a credentials file. This document performs
no write. A named profile alone is not selected by the reviewed invocation.
Conduit's candidate-only `AgentProfile.model` must be observed as nil/empty
(CLI default) or exactly `gpt-6-luna`, not Sol. The latter is an explicit
thread-start model override; neither choice injects an effort override.

For a later authorized candidate launch, the candidate executable itself must
receive the existing isolated HOME/state environment and existing dedicated
CODEX_HOME. Set no CONDUIT_CODEX_UNIX=1. Its stdio child must actually inherit
that context. Launching a probe with a different home, cwd, wrapper, `-c`,
`--model`, or `--profile` proves only that probe. Ordinary app-name launching
is not evidence of the exact executable/environment and can target another app.

Current official documentation supports user/project/managed config layering,
model_reasoning_effort, and cwd-scoped config/read. Installed version semantics
and native literal `max` advertisement still require readback. Do not infer them
from API model pages or an absent parameter. Metadata predicts configuration;
actual thread/turn model and effort evidence belongs to the later frozen smoke.
No worker self-description substitutes for provider metadata. The current adapter
retains thread identity but does not expose all handshake profile fields through
its effect mapper, so retain scoped provider-native evidence where available.
Do not inject new thread/start calls just to fill that evidence gap.

## Next local packet: one bounded metadata check, not another setup loop

Under the existing approval, the Supervisor can assign the same owner a bounded
return with a single monotonic deadline measured from dispatch/context entry,
not from the end of prerequisites. Retain the earlier 360s cap, reserve cleanup
and receipt time inside it, and stop before launch if too little remains.
Do not rerun full tests/build/assembly. Reuse existing fixture/source/hash checks;
only recheck mutable or contradictory facts.

1. Record exact candidate path and binary hash, plus exact resolved CLI executable
   and hash. For mixed signing, capture commands, absolute targets, exit codes,
   stdout and stderr separately:
   `codesign --verify --deep --strict --verbose=2 "$APP"`,
   `codesign --verify --strict --verbose=2 "$EXE"`, and
   `codesign --display --verbose=4 "$APP"`.
   Distinguish bundle integrity, executable integrity, display metadata/CDHash
   and signer identity. A successful display is not validation; stderr is not
   automatically failure. Preserve expected ad-hoc signing: lack of a Team ID
   does not itself imply invalid bytes. Do not re-sign, rebuild, remove quarantine
   or install. A real signature conflict blocks candidate launch, not necessarily
   an independently authorized metadata probe of the separately verified CLI.
2. Never attach to, reuse or signal either unknown-owner App Server. A fresh
   owned stdio probe uses no existing socket/session and creates no thread.
   Unknown unrelated owners are not a global veto. If an actual shared-home lock,
   writable-state conflict or ownership ambiguity affects the NEW probe, name
   that resource and stop; do not bypass locks. Track only its new PID/start
   identity, pipes and observed exit. No generic pkill or process-group cleanup.
3. First obtain metadata without configuration overrides, in the existing
   dedicated home and `hs-smoke` cwd, using the exact CLI:
   argv `["app-server"]`. The allowlisted protocol is initialize, then initialized
   after its response, then model/list pagination, then config/read. Not the
   Conduit start helper. Example wire shapes (placeholders resolved locally):

```json
{"id":1,"method":"initialize","params":{"clientInfo":{"name":"conduit","title":"Conduit","version":"1.0"}}}
{"method":"initialized","params":{}}
{"id":2,"method":"model/list","params":{"limit":100,"includeHidden":true}}
{"id":3,"method":"config/read","params":{"includeLayers":false,"cwd":"<exact hs-smoke cwd>"}}
```

   Send sequentially with the initialize response barrier; follow actual
   nextCursor with fresh IDs, at most ten model pages. If installed schema differs,
   preserve unsupported/UNKNOWN, do not silently strip cwd or add override flags.
   Project config/read to model/model_reasoning_effort BEFORE retaining output;
   do not dump credentials, all layers, environment or account responses.
   Preserve separate provider/usage/tier observations required by #93, without
   inventing defaults. Startup may write ordinary CLI cache/log metadata: zero
   thread requests is not a claim of byte-inert CLI startup.
4. A native catalogue lacking exact Luna or literal max blocks this requested
   route; no downgrade, API-key fallback or paid route. If supported but the
   effective config is still Sol/missing effort, preserve that baseline. The
   already-approved candidate-only setup may then change just the two non-secret
   configuration keys and nonconflicting candidate model selection, with before/
   after receipts and another bounded readback assigned by the Supervisor. This
   metadata-only packet does NOT silently perform that write or extend its clock.
   Authentication success is not revoked by model or config observations.
5. Close only the owned probe and observe its exit within the deadline. Return
   source-vs-local equality, configuration scope, native model/max availability,
   effective readback, signing distinctions and exact outstanding setup gates.
   Config evidence applies to the checked cwd only. Before final manifest freeze,
   account for all five fixture cwd layers; a config/read at another cwd is not
   evidence that a differently launched process was observed there.

No candidate launch, connection/gate changes or hosted objectives in this packet.
The subsequent Supervisor-owned setup must observe the actual child environment,
listener, isolation, qualification connection, complete catalogue and write gate.
Preserve operator 8750/app/tunnel. Queued/delivered means no resend. Preserve one
smoke <=3 turns and conditional L/F/F/L <=12 more: <=5 fresh tasks, <=15 turns,
one active, 180s observation/turn, 60s smoke teardown, no delegation.

## Portable tooling added here

`tools/hosted-profile-route-v1/check_route.py` consumes redacted JSON on stdin.
It checks scoped invocation equality, rejects probe-only overrides, correlates
metadata IDs/order/pagination/cwd, requires native Luna/max plus effective config,
and never grants runtime/authentication/hosted readiness. It makes no network,
process, credential or configuration calls. It supplements, not replaces, #93.

Schema and synthetic example: `test_route.py:fixture`. Paths are represented by
SHA-256 of canonical UTF-8 paths; scope digests cover only allowlisted non-secret
launch/config metadata, never credential values. `config_context_sha256` binds
relevant config provenance, not only the two displayed settings. Collectors must
actually measure these inputs, not copy the planned values into observed fields.
The initialize projection's `initialized_notification_sent` is collector evidence,
not a server response field. config/read uses real cwd on wire; the redacted
record uses cwd_sha256. Redacted responses intentionally omit unrelated fields.
The checker cannot verify the truth/freshness of supplied declarations or private
hashes, detect a lying collector, establish billing, or prove candidate launch.

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tools/hosted-profile-route-v1 -p test_route.py -v
python3 tools/hosted-profile-route-v1/check_route.py < redacted-route.json
```

## References and evidence boundaries

- Frozen source: https://github.com/camerontjs-dot/Conduit/tree/e1c6e41e5a74a53e687b6ed42e3cd3bb858313f7
- Frozen protocol: https://github.com/camerontjs-dot/Conduit/blob/89733c67556bbf1fde7e31edffc229e527321815/docs/qualification/hosted-supervisor-v1.md
- App Server / model/list: https://developers.openai.com/codex/app-server
- Config: https://developers.openai.com/codex/config-basic and https://developers.openai.com/codex/config-reference
- Upstream ConfigReadParams/Response and ThreadStartResponse/TurnStartParams: https://github.com/openai/codex/tree/main/codex-rs/app-server-protocol/schema/typescript/v2
- Signing: https://developer.apple.com/library/archive/technotes/tn2206/_index.html

Upstream main/docs were consulted as current interface guidance, not as a pinned
copy of the installed CLI. The exact installed schema, private child equality,
actual inherited environment, signing readback and native config/model responses
are the remaining unavailable local inputs. No runtime repair is warranted until
a specific supported-route failure is observed. Local-only child publication is
not authorized here. Changelog N/A: offline preparation, no product behavior.
