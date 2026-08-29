# Local Acceptance and Control-Plane Test Plan

Status: planned execution  
Primary repository: `camerontjs-dot/Conduit`  
Related issues: #3, #4

## Purpose

This document defines the local, machine-bound testing required before Conduit is allowed to make stronger claims about:

- provider adapter compatibility;
- runtime persistence and recovery;
- ChatGPT MCP supervision;
- control-plane extraction from the macOS UI;
- local security boundaries;
- approval handling;
- task and turn lifecycle semantics.

This is an execution plan, not a pass claim.

Automated repository tests prove deterministic code paths. They do **not** prove installed CLI authentication, real provider protocol behavior, tmux durability, macOS permission behavior, Secure MCP Tunnel behavior, GUI/runtime independence, or recovery under local faults.

Negative results must be preserved.

---

# 1. Test authority and evidence rules

## 1.1 Pin the exact object under test

Before every local test pass, record:

```bash
git rev-parse HEAD
git status --short
git branch --show-current
```

Also record:

- Conduit app build SHA if testing a packaged app;
- installed provider CLI versions;
- macOS version;
- Xcode / Swift version where relevant;
- tmux version;
- Ollama version if used;
- tunnel-client version if used;
- whether the test is running from source, a locally built app bundle, or an installed app copy.

Do not report a result from one SHA as proving another SHA.

## 1.2 Evidence classes

Each test result should identify itself as one of:

- **OBSERVED**: directly witnessed behavior or captured machine output;
- **INFERRED**: interpretation supported by observed evidence;
- **HYPOTHESIS**: plausible explanation not yet verified;
- **UNKNOWN**: not tested or evidence insufficient.

## 1.3 Required receipt shape

For each material test, record:

```text
Test ID:
Date/time:
Conduit SHA:
Installed-app/build identity:
Machine/environment:
Provider/runtime:
Preconditions:
Action:
Expected:
Observed:
Result: PASS | FAIL | INCONCLUSIVE | BLOCKED
Evidence:
Negative findings:
Follow-up:
```

Where practical, preserve exact commands, structured JSON, event IDs, task IDs, runtime-attempt IDs, timestamps, and relevant logs.

Do not preserve secrets or raw credentials.

---

# 2. Baseline repository verification

These tests establish that the local object matches the deterministic repository baseline before machine-bound testing begins.

## L0.1 Repository state

Run:

```bash
git status --short
git rev-parse HEAD
git log -1 --oneline
```

Acceptance:

- exact SHA recorded;
- worktree state recorded;
- any uncommitted changes disclosed.

## L0.2 Deterministic suites

Run:

```bash
./scripts/test.sh
```

Record:

- self-test count;
- XCTest count;
- failures;
- warnings that remain;
- exact exit status.

Do not turn warnings into a pass claim.

## L0.3 Build

Run:

```bash
./scripts/build-app.sh
```

Record:

- exit status;
- app bundle path;
- signing result;
- executable SHA-256 if practical.

## L0.4 Clean-launch baseline

Launch the built app from a known clean state.

Record:

- launch succeeds/fails;
- MainFrame root selection/restoration behavior;
- task history visibility;
- no unexpected process spawn caused merely by selecting history.

---

# 3. Session API security and transport

These tests belong primarily to issue #3 and must be complete before external write authority is expanded.

## L1.1 Token file mode

Inspect only metadata:

```bash
stat -f '%Sp %OLp %N' ~/.conduit/session-api-token
```

Do not print the token.

Expected target:

- owner read/write only where supported;
- typically mode `0600`.

If an older token exists with broader permissions:

- record current mode;
- determine whether code repairs permissions on startup;
- determine whether token rotation is warranted;
- record rotation without preserving the credential value.

## L1.2 Token creation regression

From a controlled disposable Conduit home if possible:

1. remove only the disposable test token;
2. start the Session API;
3. inspect created file mode;
4. restart;
5. confirm permissions remain correct.

Acceptance:

- token created owner-only;
- restart does not broaden permissions.

## L1.3 Exact bearer parsing

Test:

- exact valid bearer token;
- wrong token;
- empty bearer token;
- valid token embedded inside a longer string;
- duplicate Authorization headers if supported by the harness;
- lowercase/uppercase scheme handling according to the implemented contract.

Acceptance:

- only the exact valid credential authenticates;
- substring containment must not authenticate.

## L1.4 Unauthenticated health boundary

Check:

- `/healthz`;
- `/readyz`;
- MCP endpoint without auth.

Acceptance:

- health behavior matches declared policy;
- protected MCP calls reject unauthenticated callers;
- health does not leak task/session/project data.

## L1.5 Request size bounds

Exercise:

- normal small MCP request;
- oversized headers;
- oversized body;
- malformed Content-Length;
- body shorter than Content-Length;
- body longer than declared Content-Length where possible.

Acceptance:

- bounded refusal;
- no crash;
- no unbounded memory growth;
- no silent truncation interpreted as valid JSON.

## L1.6 Slow/incomplete client

Open a local connection that:

- sends headers very slowly;
- never completes the body;
- stalls before authentication.

Acceptance:

- request/read deadline closes the connection;
- other clients remain serviceable;
- Conduit does not hang the main actor.

## L1.7 Concurrent local clients

Run multiple concurrent read requests.

Then, if writes are locally enabled in a controlled test:

- concurrent status/event calls;
- one interrupt request;
- one send/create attempt.

Acceptance:

- no head-of-line blocking from one stalled peer;
- bounded concurrency;
- no response cross-talk;
- no caller identity leakage across requests.

## L1.8 Caller identity / principal behavior

Record current behavior of `initialize.clientInfo`.

Test at least two logical clients if possible.

Acceptance for current implementation:

- document exactly whether identity is per listener, per connection, or per request;
- preserve any cross-client collision.

Future control-plane target:

- security principal derives from authenticated capability/credential context, not only self-declared client metadata.

---

# 4. MCP catalogue and read-only ChatGPT supervision

These tests establish what the current ChatGPT Pro-compatible read path can reliably do.

## L2.1 Tool discovery

Through the real tunnel path, record `tools/list`.

Verify:

- complete expected catalogue;
- descriptions present;
- required arguments described;
- write publication does not imply write authorization;
- local write gate still blocks mutations when disabled.

## L2.2 List projects

Test:

- normal MainFrame root;
- no root;
- invalid/stale root;
- project rename if practical.

Acceptance:

- output is source-derived;
- no shadow project registry claim;
- stale/unavailable state is explicit.

## L2.3 List sessions pagination

Exercise:

- default page;
- small limit;
- next cursor;
- final page;
- invalid/stale cursor if supported;
- >40 sessions if local state permits or via controlled fixtures.

Acceptance:

- stable ordering;
- total/returned/has_more reconcile;
- no silent truncation.

## L2.4 Session status after app restart

For an existing task with durable history:

1. read status;
2. quit/relaunch app;
3. read status again.

Acceptance:

- durable conversation/task history remains available as designed;
- missing data is reported honestly;
- no empty-history falsehood caused only by cold in-memory caches.

## L2.5 Session event cursor

Exercise:

- initial page;
- next cursor;
- no-new-events poll;
- event arrival after cursor;
- small limits;
- invalid cursor;
- truncation fields.

Acceptance:

- no duplicate or skipped events under documented semantics;
- authority/source labels preserved;
- cursor advances deterministically.

## L2.6 Supervisory snapshot

For structured and PTY-backed tasks, verify fields including:

- thread id and source;
- runtime attempt id;
- observed_at;
- provider progress;
- input state;
- checkpoint;
- last output state.

Acceptance:

- PTY quietness is never presented as provider completion;
- structured completion remains provider observation, not task verification.

## L2.7 MindGraph query trust partition

Test known citable, unverified, and not-citable results if safe fixtures exist.

Acceptance:

- not-citable material is partitioned;
- counts reconcile;
- ranking is not silently rewritten;
- no caller has to parse warning prose to discover the trust class.

---

# 5. Provider adapter conformance matrix

Run every currently enabled provider through the strongest practical native boundary.

Record the exact installed version for every provider.

Suggested matrix:

| Provider | Preferred host | Required tests |
| --- | --- | --- |
| Codex | app-server | create, send, answer, completion, approval, interrupt, resume |
| Grok | ACP stdio | create, send, answer, completion, interrupt, fallback |
| OpenCode | HTTP + SSE | server lease, create, send, answer attribution, completion |
| Claude | stream-json | send, answer attribution, approval/input state, completion |
| Antigravity | stream-json | send, answer attribution, completion |
| Gemini CLI | ACP with API key | eligibility, send, answer, completion, fallback |
| Shell | PTY | prompt delivery, output projection, exit, interrupt |

For each provider run the following.

## L3.1 Availability and version

Record:

- executable path;
- version;
- authentication usable/unavailable;
- declared Conduit backend;
- selected model where observable and relevant.

Do not extract subscription credentials.

## L3.2 Session/task creation

Create exactly one task.

Record:

- task ID;
- runtime attempt ID;
- provider thread/session ID where supported;
- lifecycle sequence;
- whether the process starts once.

Acceptance:

- no duplicate runtime;
- identity remains stable.

## L3.3 Initial objective delivery

This is a critical current-semantic test.

Create a task with a unique harmless objective string.

Observe whether:

- objective is delivered immediately;
- runtime is still starting;
- `objective_delivered` is true/false;
- objective arrives later without another call;
- objective is permanently lost unless a second send occurs.

Preserve the exact result.

This test informs issue #4's decision between durable initial intent and strict two-phase start.

## L3.4 Structured answer attribution

Use a deterministic prompt such as:

```
Reply with exactly CONDUIT_ADAPTER_READY
```

Verify:

- operator prompt is not included as agent answer;
- private reasoning/thought chunks are excluded;
- snapshots/deltas do not duplicate output;
- repeated completion events do not duplicate the final answer;
- exactly one logical answer is surfaced.

## L3.5 Multi-turn continuity

Send at least two turns in the same task.

Acceptance:

- same provider session/thread when expected;
- no accidental new task/runtime;
- second answer maps to second prompt;
- first answer is not replayed as new output.

## L3.6 Approval/input-required state

Where a provider can safely trigger a benign approval:

- cause an approval request;
- observe Conduit status/events;
- do not auto-approve through an unauthorized surface.

Acceptance:

- pending approval visible;
- approval is distinct from generic inactivity;
- external observation does not itself grant approval authority.

If a safe approval cannot be triggered, mark BLOCKED/UNKNOWN.

## L3.7 Interrupt semantics

During an active turn:

1. request interrupt;
2. capture Conduit's durable interrupt-request event;
3. observe provider behavior;
4. determine whether cancellation is independently observed.

Acceptance:

- request acknowledgement is not called proof of provider interruption;
- later provider completion/failure/cancellation remains separate.

## L3.8 Resume/reconnect

Create a task, record thread/session identity, close/relaunch the relevant surface, then reconnect.

Acceptance:

- same task identity;
- same provider thread where supported;
- no duplicate provider session unless explicitly restarted;
- persisted/live thread-id source reported honestly.

## L3.9 Fallback behavior

Where the structured host can be safely made unavailable:

- verify Conduit falls back only according to declared policy;
- record whether Raw/PT Y fallback remains usable;
- ensure fallback does not silently claim structured completion semantics.

---

# 6. tmux and PTY lifecycle

## L4.1 Detached creation

Create a durable PTY/tmux task.

Verify:

- tmux session created detached;
- task/project/agent binding metadata present;
- app selection alone does not create or attach another runtime.

## L4.2 Explicit leave/detach

Leave the runtime through Conduit.

Acceptance:

- terminal detaches deterministically;
- task remains reconnectable where designed;
- admission capacity behavior matches explicit lifecycle rules.

## L4.3 Reconnect

Reconnect once.

Acceptance:

- same tmux session;
- same task identity;
- one attach only;
- no duplicate process.

## L4.4 External tmux exit

Kill or exit the tmux-hosted agent/process outside the normal Conduit close path.

Observe:

- task runtime state;
- admission/live-task accounting;
- reconnect/reconcile behavior.

Preserve whether capacity remains held until explicit Conduit lifecycle action, as currently designed.

## L4.5 Malformed/legacy binding

If safe fixtures can simulate:

- tmux session without task binding;
- malformed task binding;
- stale project path.

Acceptance:

- legacy session appears as discovered/adoptable only where intended;
- malformed binding is not silently adopted.

## L4.6 PTY prompt-delivery readiness

Exercise startup where terminal emits initial redraw/output.

Verify:

- queued prompt waits for bounded quiescence or cap;
- prompt is delivered once;
- quietness does not generate a completion claim.

---

# 7. Conversation and persistence

## L5.1 Prompt persistence

Send a known harmless prompt.

Quit/relaunch.

Acceptance:

- exact native submission remains in conversation history;
- source label intact.

## L5.2 Derived-from-Raw persistence

Produce harmless terminal output.

Acceptance:

- bounded rendered projection retained;
- labelled Derived from Raw;
- not attributed as a verified assistant answer.

## L5.3 History-unavailable distinction

Test if possible with a controlled missing/corrupt history fixture.

Acceptance:

- marked expected-but-missing history is called unavailable;
- absence is not presented as a complete empty thread.

## L5.4 Artifact references

Attach a harmless file/path.

Verify:

- path/reference behavior matches contract;
- file body is not silently copied merely because it was attached;
- event export does not disclose file contents.

## L5.5 Restart during active task

Quit or terminate the app while a task is active.

Observe:

- provider runtime fate;
- persisted task/runtime metadata;
- conversation log consistency;
- recovery markers.

Do not yet interpret runtime death as an architectural failure. This is baseline evidence for the control-plane extraction.

---

# 8. macOS installed-app acceptance

Run against the actual installed/built app bundle, not only `swift run`.

## L6.1 MainFrame security-scoped access

Test:

- initial selection;
- relaunch persistence;
- invalidated access;
- recovery through folder picker;
- slow/unavailable root.

Acceptance:

- no indefinite UI freeze;
- explicit recovery state;
- no silent switch to an unintended path.

## L6.2 Microphone and speech

Test:

- permission not granted;
- permission granted;
- on-device speech behavior;
- edit before send.

Acceptance:

- transcription never auto-submits;
- denial is explicit;
- normal task operation still works without microphone permission.

## L6.3 Screenshot / screen capture

Test:

- permission denied;
- permission granted;
- capture cancellation;
- successful harmless capture.

Acceptance:

- failure is bounded;
- no unexpected upload;
- resulting attachment is a local reference.

## L6.4 File/folder attachments

Test:

- file;
- directory;
- inaccessible path;
- removed path after attachment.

Acceptance:

- errors explicit;
- no hidden upload;
- path handling deterministic.

## L6.5 Relaunch/navigation persistence

Record:

- selected task;
- selected surface;
- project filter;
- active runtime relationship.

Acceptance should be based on the currently documented behavior, not future desired behavior.

Any missing persistence should be recorded rather than silently "fixed" during testing.

---

# 9. Ollama/local planner

## L7.1 Planner reachability

Verify the configured loopback Ollama planner:

- reachable/unreachable;
- configured model present/absent;
- no remote fallback unless explicitly designed.

## L7.2 Context packet validation

Exercise:

- valid bounded context packet;
- missing project;
- unlabelled entry;
- over-budget packet;
- not-citable entry.

Acceptance:

- invalid packet rejected before planning;
- labels retained.

## L7.3 Proposal decoding

Test:

- valid JSON-only proposal;
- valid fenced JSON;
- prose with embedded JSON;
- malformed JSON;
- wrong schema version;
- unsafe/multi-worker proposal.

Acceptance:

- arbitrary prose is not scraped into executable-looking authority;
- invalid proposal remains non-executable.

## L7.4 Model residency/unload

Observe before and after a planning request:

- model residency;
- unload request;
- other loaded models/services.

Acceptance:

- Conduit unloads only its intended model according to current contract;
- shared Ollama service is not stopped/reconfigured.

---

# 10. Admission, resource, and idempotency behavior

## L8.1 Caller identity required

Attempt write before initialize/current identity establishment.

Expected:

- refused with structured caller-identity error.

## L8.2 Unknown project/agent validation

Attempt invalid create.

Acceptance:

- validation rejects before capacity/create budget is consumed.

## L8.3 Live-task capacity

Create up to the configured ceiling using harmless workers.

Acceptance:

- ceiling reached deterministically;
- next create refused as capacity, not falsely as success;
- machine remains stable.

Stop if resource pressure becomes unsafe.

## L8.4 Create rate

Exercise only if safe and without spawning uncontrolled workloads.

Acceptance:

- create churn eventually hits rate control;
- failed provisioning returns capacity reservation.

## L8.5 Prompt queue

Send controlled prompts up to configured per-task/global queue limits.

Acceptance:

- queue limit is enforced;
- no silent loss;
- structured refusal includes reason.

## L8.6 Idempotent create

Repeat identical create with same idempotency key.

Acceptance:

- original task returned;
- no duplicate runtime.

Then reuse the same key with different request content.

Expected:

- explicit refusal.

## L8.7 Resource circuit breaker

Where safe, test unknown/stale sensor paths through controlled fixtures or instrumentation rather than intentionally exhausting the machine.

Acceptance:

- required unknown/stale metric fails closed;
- unmeasured metric is not fabricated as zero.

---

# 11. ChatGPT Secure MCP Tunnel end-to-end

This must use the real hosted/tunnel path, not only localhost curl.

## L9.1 Tunnel startup

Record:

- tunnel profile/config identity without secrets;
- local endpoint;
- readiness result;
- Session API version;
- app write-gate state.

## L9.2 Read path from ChatGPT

From the real ChatGPT seat, exercise:

- list projects;
- list sessions;
- session status;
- session events;
- adapter list;
- MindGraph query.

Acceptance:

- results match local state;
- no private Raw transcript export;
- no secret/token exposure.

## L9.3 Write entitlement observation

On the current account/surface, record exactly what ChatGPT exposes and permits.

Do not assume.

Acceptance:

- actual product behavior captured;
- blocked write capability remains blocked;
- no attempt to disguise mutation as a read operation.

## L9.4 Reconnect after app restart

Restart Conduit while tunnel/client configuration remains.

Observe:

- endpoint recovery;
- tool discovery behavior;
- stale client catalogue behavior;
- read continuity.

---

# 12. Control-plane extraction baseline experiments

These tests should be run **before** and **after** issue #4 extraction work.

The pre-extraction result may fail. That failure is useful baseline evidence.

## L10.1 GUI termination during active structured task

1. create one Codex or other structured task;
2. record task ID/runtime-attempt/provider thread ID;
3. send a harmless long-enough turn;
4. terminate Conduit.app;
5. observe provider process/thread;
6. relaunch Conduit;
7. inspect task/status/events;
8. attempt explicit reconnect/resume.

Record:

- whether worker survives;
- whether provider thread survives;
- whether runtime ownership is lost;
- whether duplicate runtime is created;
- whether task history remains coherent.

## L10.2 GUI termination during PTY/tmux task

Repeat using tmux-backed PTY.

Record:

- tmux survival;
- task binding;
- reconnect behavior;
- duplicate attach/process behavior.

## L10.3 GUI termination with pending approval

Where safely reproducible:

1. reach pending approval;
2. terminate UI;
3. relaunch;
4. inspect approval/task state.

Acceptance target for future control plane:

- pending approval remains identifiable;
- no auto-approval;
- no silent disappearance presented as success.

## L10.4 GUI termination during queued initial objective

If the current create/objective race can be reproduced:

- create task;
- terminate GUI before initial objective delivery;
- observe whether objective is lost.

This is direct evidence for the new initial-intent contract.

## L10.5 GUI restart duplicate protection

After relaunch, intentionally invoke reconnect/resume once.

Acceptance target:

- same task/runtime where appropriate;
- no duplicate worker.

If current behavior fails, preserve exact duplicate identities and process evidence.

---

# 13. Fault and recovery matrix

Run controlled versions of these cases as the architecture evolves.

| Fault | Required observation |
| --- | --- |
| GUI crash | worker fate, logs, recovery, duplication |
| provider crash | task/runtime state, restart policy |
| structured adapter disconnect | fallback/failed state |
| tmux server/session loss | binding/reconcile result |
| tunnel disconnect | local task unaffected |
| slow MCP client | listener remains available |
| invalid token | bounded auth refusal |
| stale caller identity | write refusal/identity behavior |
| app restart | durable history/state projection |
| partial conversation log | explicit unavailable/corrupt handling |
| disk write failure | no fabricated persistence success |
| pending approval + restart | approval remains unresolved |
| interrupt + disconnect | request and observation stay distinct |
| duplicate create retry | idempotency prevents duplicate |
| resource sensor unknown | circuit fails closed |

Every failure case should produce a terminal classification:

- PASS;
- FAIL;
- INCONCLUSIVE;
- BLOCKED.

No test should disappear because the result is inconvenient.

---

# 14. Adapter conformance summary format

At the end of a complete local pass, produce a compact matrix:

| Adapter | Version | Auth | Create | Initial objective | Answer attribution | Completion | Approval | Interrupt | Resume | Fallback | Disposition |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Codex | | | | | | | | | | | |
| Claude | | | | | | | | | | | |
| Grok | | | | | | | | | | | |
| OpenCode | | | | | | | | | | | |
| Antigravity | | | | | | | | | | | |
| Gemini CLI | | | | | | | | | | | |
| Shell | | | | | | | | | | | |

Do not convert unavailable or untested cells into implied passes.

---

# 15. Control-plane readiness gates

The following must be known before Conduit can credibly move execution authority out of the UI.

## Gate A - current runtime behavior known

Required:

- provider adapter matrix;
- tmux/PTY lifecycle;
- app restart behavior;
- tunnel behavior;
- current objective-delivery semantics.

## Gate B - local security boundary acceptable

Required:

- token permission disposition;
- exact auth parsing;
- bounded request handling;
- no listener-wide stall from one slow client;
- no broadened network bind.

## Gate C - persistence semantics known

Required:

- task identity survives relaunch;
- conversation history behavior known;
- provider thread persistence known per adapter;
- pending approval behavior known;
- reconciliation behavior known.

## Gate D - control-plane extraction experiment defined

Required identifiers:

- task ID;
- runtime attempt ID;
- provider thread ID where supported;
- principal/origin;
- turn ID;
- approval ID where applicable.

## Gate E - no hidden equivalence claims

The test programme must continue to distinguish:

- process alive from task successful;
- provider completed from work verified;
- prompt sent from prompt acknowledged;
- interrupt requested from provider interrupted;
- context retrieved from evidence verified;
- UI state from runtime authority.

---

# 16. Recommended execution order

Run in this order to reduce wasted machine-bound work:

1. L0 repository baseline;
2. L1 Session API security/transport;
3. L3 provider adapter versions and basic conformance;
4. L4 tmux/PTY lifecycle;
5. L5 persistence;
6. L6 installed-app macOS features;
7. L7 Ollama planner;
8. L8 admission/idempotency;
9. L9 real ChatGPT tunnel;
10. L10 pre-extraction UI-kill baselines;
11. fault/recovery matrix;
12. produce final adapter and readiness summaries.

If an earlier security or resource test reveals a plausible host-safety risk, stop the higher-risk concurrency/spawn tests and record the blocker.

---

# 17. Durable outputs

Local execution should leave:

- one machine-bound acceptance receipt for issue #3;
- one adapter-conformance matrix;
- one control-plane baseline/restart receipt for issue #4;
- exact negative findings;
- links or paths to non-secret logs/artifacts;
- issue updates for any discovered defects;
- no credentials, raw token values, or private MainFrame corpus content committed to this repository.

Tests that reveal a product defect should create a focused issue rather than silently broadening the implementation session.

---

# 18. What this plan does not authorize

This plan does not authorize:

- recursive autonomous delegation;
- broad external network exposure;
- bypassing ChatGPT entitlement/confirmation controls;
- automatic approval;
- destructive provider actions merely to exercise a code path;
- intentional memory exhaustion or host destabilization;
- publishing private MainFrame state;
- claiming successful work from agent prose;
- implementing the final daemon/process architecture before the baseline evidence is collected.
