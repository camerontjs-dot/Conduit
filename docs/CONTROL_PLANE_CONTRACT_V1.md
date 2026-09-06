# Conduit Control-Plane Contract v1

Status: reconciled Phase A candidate; acceptance occurs when this PR is reviewed and merged  
Programme authority: issue #4  
Machine-bound evidence lineage: issue #3 and PRs #7, #8, #10–#21  
Reconciliation evidence base: `main` at `34555ccd6cd2af6fa763bd730198636e47a0e1e4`

## Purpose

This document defines the first explicit contract for separating Conduit's execution/control-plane semantics from the macOS user interface.

It is intentionally implementation-neutral about process hosting. The control plane may remain in-process while its semantics are extracted. This contract does not select XPC, a helper process, launchd, a daemon, or another host.

The goal is to freeze the semantics that any future host and client must preserve, using the machine-bound evidence now available rather than the assumptions that existed when this contract was first drafted.

---

# 1. Product boundary

Conduit is a local agent execution and governance control plane with a native macOS operator client.

It owns:

- task identity;
- runtime-attempt identity;
- provider adapter leases/process ownership;
- turn lifecycle where the backend exposes one;
- prompt delivery state and delivery ownership;
- provider-thread/session continuity observations;
- interrupt request state;
- approval state;
- admission/capacity/resource policy;
- idempotency;
- supervisory events;
- restart/reconciliation semantics;
- authority-labelled receipts.

Conduit does not own:

- MainFrame project truth;
- GitHub repository truth;
- whether an agent answer is factually correct;
- automatic work verification;
- hidden LLM routing;
- automatic approval;
- recursive delegation;
- provider credentials beyond supported local authentication flows.

The macOS application is a privileged client of this control plane, even while substantial runtime ownership still resides in `AppModel` today.

External orchestration surfaces such as MCP are adapters over the control plane. No external protocol is the internal semantic authority.

---

# 2. Authority separation

The following states are independent.

## 2.1 Task state

A task is the durable identity of an intended unit of work.

Initial v1 states:

```text
proposed
approved
admitted
started
closed
```

A task may outlive multiple runtime attempts.

A task being `closed` does not mean the requested work succeeded.

## 2.2 Runtime-attempt state

A runtime attempt is one concrete provider/process execution attempt for a task.

Initial v1 states:

```text
starting
ready
running
detached
exited
failed
```

A runtime exit is an execution observation, not a work-verification result.

Closing a runtime must distinguish at least:

- `detached`: the runtime continues and is expected to be recoverable;
- `stopped`: the adapter/runtime was stopped and recovery is not established.

A generic `closed: true` is insufficient authority for an orchestrator deciding whether it can continue later.

## 2.3 Turn state

A turn is one admitted prompt/instruction interaction with a structured provider runtime.

Initial v1 states:

```text
queued
delivered
active
awaiting_input
completed
cancelled
failed
ambiguous
```

Provider-reported completion may justify `completed` on the turn axis only when the adapter has not also observed a provider failure for that turn.

A provider failure is `failed`, not completion, even if the provider's raw status vocabulary also contains a terminal or completed-like value.

It does not verify the task's requested outcome.

### PTY limitation

A PTY has no provider-native turn protocol. Output quietness therefore must not produce `completed`.

For PTY work, the turn axis may remain `ambiguous` indefinitely. An orchestrator that requires a terminal structured turn state must not wait on a PTY as though one will eventually appear. PTY work requires another completion/verification mechanism or direct Raw/tmux inspection.

This is a capability boundary, not permission to invent completion.

## 2.4 Approval state

Initial v1 states:

```text
none
requested
approved
denied
expired
```

Approval authority is separate from ordinary send/create authority.

Observing an approval request does not grant permission to resolve it.

## 2.5 Agent claim state

Initial v1 values:

```text
no_claim
claimed_complete
```

This captures only what the agent claims about its work.

It is not verification.

## 2.6 Verification state

Initial v1 values:

```text
unverified
verified
failed
inconclusive
```

Verification may be supplied by deterministic checks, an independent reviewer, or another separately identified verification boundary.

Agent prose alone is insufficient to move this axis from `unverified`.

---

# 3. Non-equivalence rules

The control plane must never silently equate:

- process alive with task healthy;
- process exit with task success;
- provider completion with task verification;
- provider terminal status with successful turn completion when a provider failure was observed;
- agent "done" prose with verified completion;
- interrupt request with observed interruption;
- prompt queued with prompt delivered;
- prompt delivered with provider acknowledged;
- output quietness with provider completion;
- resume requested with resume established;
- a replacement session with continuous history;
- a provider thread id asserted by Conduit with provider-confirmed continuity;
- a stopped structured adapter with a detachable/recoverable runtime;
- retrieved context with verified evidence;
- UI selection with runtime ownership;
- MCP tool publication with authorization.

Where evidence is insufficient, the state remains explicit, ambiguous, or unknown rather than being inferred upward.

---

# 4. Identity and continuity model

The following identifiers and continuity observations are distinct.

## 4.1 task_id

Durable identity for the task.

Must remain stable across:

- GUI restarts;
- runtime restarts;
- reconnect/resume;
- provider thread restoration where supported.

## 4.2 runtime_attempt_id

Identity for one concrete execution attempt.

A new runtime attempt must not overwrite the historical identity of an earlier attempt.

## 4.3 turn_id

Identity for one admitted prompt/instruction interaction where the backend exposes a meaningful turn.

Required for:

- delivery acknowledgement;
- provider progress;
- completion/cancellation/failure;
- approval association;
- interrupt association.

PTY backends do not gain false structured-turn semantics merely to satisfy this model.

## 4.4 provider_thread_id

Native provider thread/session identity where available.

The control plane must record the source/authority of the identity and must not infer continuity from string equality alone.

## 4.5 provider thread provenance

A structured session start has one of four v1 provenance states:

```text
fresh
resumed
restarted
unverified
```

Meaning:

- `fresh`: no resume was requested; the session is new;
- `resumed`: the provider accepted the requested id and continuity is established at the provider-session boundary;
- `restarted`: a resume was requested, the provider refused it, and Conduit is now driving a replacement session without the requested history;
- `unverified`: Conduit presented the session as a resume but the client did not confirm that with the provider, so continuity is unknown.

Only `resumed` claims history continuity.

`history_is_continuous` is therefore three-valued:

- true for `resumed`;
- false for `fresh` and `restarted`;
- unknown for `unverified`.

When a replacement displaces a previous provider thread id, the prior id must remain recoverable as a bounded recovery hint rather than being overwritten by the replacement id.

Provider-thread provenance is observation. It is not work verification and it does not by itself make a closed task recoverable.

## 4.6 approval_id

Identity for one approval request.

## 4.7 event_id

Stable identity for a durable supervisory event.

## 4.8 principal_id

Identity for the authenticated caller/capability principal.

Self-declared client metadata may be retained as descriptive provenance but must not be the sole security authority for future write-capable clients.

---

# 5. Internal command contract

The internal command surface is semantic and independent of MCP tool count or hosted-client entitlement.

Initial v1 command families follow.

## CreateTask

Inputs should include, at minimum:

- project/scope identity;
- agent/profile identity;
- optional objective;
- origin/principal;
- optional idempotency key;
- optional lineage metadata where supported.

Outputs should distinguish:

- admitted/refused;
- created task id;
- runtime attempt id when provisioned;
- initial-objective state;
- whether the caller must resend;
- admission refusal reason.

### Durable create intent is the v1 delivery contract

When `CreateTask(objective)` is accepted, Conduit owns exactly-once eventual initial delivery of that objective unless a terminal delivery failure is recorded.

The caller must be able to branch on at least:

```text
not_attempted
queued
delivered
failed
```

`queued` means Conduit owns delivery. The caller must not resend merely because delivery has not completed at response serialization time.

`failed` means Conduit no longer owns eventual delivery and the response must explain whether caller retry/resend is appropriate.

A duplicate idempotent create must not duplicate objective delivery.

A held objective is a promise. It must reach a durable outcome such as delivered, refused/failed, or abandoned if the runtime disappears or never becomes ready. A held prompt must not remain queued forever after its owning runtime has been dropped.

This decision supersedes the original Candidate A/Candidate B uncertainty in the first draft of this contract. It is evidence-backed by the merged write-enabled PTY and structured-provider behavior and the cross-backend orchestration exercises.

## StartTurn / SendPrompt

Inputs:

- task id;
- text/instruction;
- principal/origin;
- optional context references;
- optional idempotency key if later justified.

Outputs must distinguish:

- queued;
- delivered;
- refused;
- terminal delivery failure.

A structured runtime that is not yet ready may hold an accepted prompt under the same single-owner rule as initial-objective delivery.

## ReconcileTask

Reconciles durable task state against current provider/runtime observations.

Reconciliation must not fabricate work verification or provider-history continuity.

A closed/stopped structured task is not presumed recoverable merely because a provider thread id was persisted.

## RequestInterrupt

Creates a durable interrupt-request event before or with the backend request.

The output acknowledges only the request.

Observed provider cancellation/interruption is a separate event.

## CloseTask

Closes/leaves Conduit's live runtime according to explicit backend semantics.

The result must expose whether the operation detached a recoverable runtime or stopped the structured adapter.

A close does not assert successful work.

## ResolveApproval

Separate capability class.

Inputs must include:

- approval id;
- resolution;
- authorized principal.

## Future AttachContextReference

May bind a typed, bounded context object/reference to a task or turn.

Context attachment is not evidence verification.

---

# 6. Internal query contract

Initial v1 query families follow.

## ListTasks

Supports deterministic ordering and pagination.

## GetTask

Returns current projections for:

- task;
- runtime attempt;
- turn;
- approval;
- agent claim;
- verification;
- provider-thread provenance where applicable;
- close/recoverability semantics where applicable.

These axes must remain separately labelled.

## ListAdapters

Returns declared and observed adapter capabilities separately where possible.

At minimum the query surface should make capability differences discoverable before a caller starts work. In particular, a PTY does not provide a terminal structured turn state.

## GetTaskEventsSince

Cursor-bounded task-scoped supervisory events.

## GetEventsSince

Future global supervisory cursor across tasks.

The global stream should include only bounded supervisory information such as:

- task created;
- runtime starting/ready/failed/exited;
- turn queued/delivered/active/completed/cancelled/failed;
- approval requested/resolved;
- interrupt requested/observed;
- provider-thread continuity/restart observations when material;
- task reconciled/closed.

It must not export:

- private chain-of-thought;
- raw credentials;
- raw PTY transcript bodies;
- arbitrary file contents.

## GetApprovals

Read-only observation of pending/resolved approval state.

## GetControlPlaneHealth

Returns control-plane health/availability without conflating provider account state with task state.

---

# 7. Evidence-backed initial-objective decision

The original contract deferred between:

- Candidate A: durable create intent;
- Candidate B: strict two-phase start.

That uncertainty is now resolved for v1.

## Decision: Candidate A

`CreateTask(objective)` durably records the objective as accepted task intent and Conduit owns exactly-once eventual initial delivery after runtime readiness, unless a terminal failure is recorded.

This does not mean the response must lie about timing. A response may report `queued` while delivery is still pending.

Required observable stages are conceptually:

```text
task_created
objective_queued
objective_delivery_attempted
objective_delivered | objective_delivery_failed | objective_abandoned
```

The exact event vocabulary may evolve, but the ownership distinction may not.

## Evidence basis

The decision is supported within the current implementation by:

- the duplicate-objective failure and repair in PR #10;
- the write-enabled canary in PR #11;
- repeated installed-app verification in PR #12;
- the hold-until-ready implementation and live orchestration evidence in PR #16;
- cross-backend Codex/OpenCode/Shell orchestration in PR #19;
- the held-prompt abandonment repair in PR #20;
- post-merge receipts on `main`, including `8b72bf79ae791d9fedbe2f1bff112a0d975c52ba`, `48365450b095e3de3a472756e03c8f2ed6f55d10`, and `34555ccd6cd2af6fa763bd730198636e47a0e1e4`.

This evidence establishes the bounded v1 ownership rule. It does not establish that every future provider or transport will honor it without adapter-specific conformance testing.

---

# 8. Event model

Control-plane events should be append-only or otherwise reconciliation-safe.

Each durable supervisory event should carry, where applicable:

- schema version;
- event id;
- occurred_at;
- task id;
- runtime attempt id;
- turn id;
- provider thread id/source/provenance;
- approval id;
- principal/origin;
- event kind;
- state;
- authority/source label;
- bounded structured detail;
- redaction/truncation markers where applicable.

Events should describe observations and requests at the narrowest justified authority.

Examples:

- `interrupt_requested`, not `interrupted`, when only the local request was issued;
- `provider_turn_completed`, not `task_verified`;
- `provider_turn_failed`, not a completed turn merely because the raw provider status is terminal;
- `runtime_exited`, not `task_succeeded`;
- `thread_restarted`, not `thread_resumed`, when the provider refused the requested thread.

---

# 9. Capability model

The control-plane contract must permit separate authorization for:

- observe;
- retrieve context;
- create task;
- start/send turn;
- reconcile;
- request interrupt;
- close task;
- resolve approval;
- administer control plane.

A client may possess any subset.

Approval resolution is not implied by ordinary lifecycle write capability.

Tool discovery is not authorization.

A read-only MCP facade may expose observations and command proposals without gaining mutation authority.

---

# 10. MCP adapter rules

MCP is one client adapter, not the control-plane semantic model.

The MCP facade may expose:

- one tool per semantic action;
- a smaller command-envelope surface;
- a read-only subset;
- a write-capable subset when the connected product legitimately supports it.

The choice must preserve:

- per-action authorization;
- confirmation clarity;
- structured refusal;
- idempotency;
- delivery ownership;
- authority labels;
- evidence quality.

Do not change the internal command model merely to satisfy a temporary hosted-tool count or plan entitlement.

Do not disguise mutation as a read operation.

Hosted MCP availability and entitlement are deployment observations. A tunnel failure before Conduit answers is not evidence about Conduit command semantics.

---

# 11. UI client rules

Conduit.app should migrate toward using the same semantic command/query contract as other privileged clients.

The UI may additionally own:

- rendering;
- navigation;
- Raw/debug terminal presentation;
- macOS permission prompts;
- local human approval interaction;
- convenience views for context/files/review/usage.

The UI should not remain the only process or object capable of:

- preserving task identity;
- owning runtime-attempt state;
- reconciling provider threads;
- recording supervisory events.

A GUI restart must eventually be survivable without silently minting a new task/runtime.

Current evidence does not establish that goal for structured providers. Process hosting remains undecided.

---

# 12. Typed context handoff

The existing orchestration context work should evolve into a generic control-plane context contract.

Required properties:

- schema version;
- project/scope identity;
- source/reference identity;
- citation/trust class;
- bounded excerpt/content;
- size/token budget;
- selection provenance.

Trust taxonomy should preserve at least:

- citable;
- unverified;
- not_citable.

Do not collapse `unverified` into a generic unknown state if that loses the retrieval trust boundary.

A context packet being attached to a task means only that the context was supplied.

It does not mean the material is correct or sufficient.

---

# 13. Lineage contract

Before any agent-to-agent delegation feature is accepted, add minimal lineage fields:

- parent_task_id;
- delegated_by;
- origin;
- proposal_id;
- verification_of;
- runtime_attempt_id.

The existing cross-backend orchestration exercise demonstrates that the control plane can carry a provider-grounded value from one backend into another task. It does not by itself authorize recursive delegation or establish worker-result verification.

The first future delegation mode should remain:

- one-hop;
- hard concurrency bounded;
- no child-to-grandchild spawning;
- result returned as observation;
- verification separate.

---

# 14. Approval envelope

A provider-neutral approval object should eventually include:

```text
approval_id
task_id
turn_id
provider
action_class
redacted_summary
options
requested_at
expires_at
state
```

Read access to this object does not imply resolution authority.

No adapter should auto-approve merely to produce smoother orchestration.

---

# 15. Recovery contract

The control plane must define or explicitly leave unknown behavior for:

- GUI restart;
- control-plane host restart;
- provider process exit;
- provider transport disconnect;
- tmux detach/orphan;
- stale/refused provider thread id;
- replacement provider session;
- pending approval at restart;
- interrupt request followed by disconnect;
- duplicate create retry;
- incomplete/held prompt delivery;
- runtime removal while a prompt is held;
- partial/corrupt local event or thread store.

Recovery may yield `ambiguous`, `failed`, `restarted`, `unverified`, or `inconclusive` where those are the narrowest supported descriptions.

It must not invent a successful state or continuous provider history.

### Persisted provider-thread records

A provider-thread store must remain backward-readable when its schema grows. A decode failure of one migrated record must not silently turn the entire store into an empty map that is then overwritten by the next save.

Prior thread ids displaced by a replacement session may be retained in a small content-free bounded list for recovery. That list is a recovery hint, not an audit log.

---

# 16. Phase A acceptance disposition

The current evidence satisfies the substantive Phase A acceptance conditions defined by the original draft:

1. machine-bound results needed to constrain the contract exist and are linked through issue #3 / PR #7 and successor PRs;
2. initial-objective behavior has been observed across PTY and structured providers and Candidate A is now selected;
3. task/runtime/turn/approval/verification separation remains accepted and has caught real false-equivalence defects;
4. command/query/event families remain the intended semantic boundary;
5. capability classes remain separate;
6. MCP remains an adapter rather than internal semantic authority;
7. no final hosting mechanism has been selected;
8. material unknowns remain explicit below.

Therefore this PR is now a **Phase A acceptance candidate**, rather than a speculative contract draft.

Merging this PR accepts the v1 semantic contract only. It does not claim UI-independent runtime ownership is implemented, provider recovery is complete, or Conduit is production-ready.

---

# 17. Known unknowns before deeper Phase B work

The following remain intentionally unresolved:

- **OBS-1:** PTY control-plane output observation was blind in 2 of 5 original runs while tmux proved the work ran. Targeted later probes have not reproduced it, and the relevant mechanism was not changed. Root cause remains unknown.
- provider-specific resume reliability after a structured adapter has been stopped;
- `unverified` resume continuity for clients that cannot check the provider at startup;
- provider-specific observed interrupt/cancel semantics;
- approval recovery after GUI restart;
- exact structured-provider survival/recovery across GUI termination;
- whether current runtime ownership can be extracted in-process far enough to make the GUI a true client without a separate host;
- whether a helper/XPC/launch-agent/daemon host is ultimately required;
- actual hosted MCP capability and liveness at execution time;
- control-plane restart semantics for active non-tmux structured providers;
- whether the global supervisory cursor is needed before or after hosting extraction;
- how independent work verification should attach to task/turn lineage without collapsing agent claims into verification.

These are inputs to the next design step, not blanks to fill with assumptions.

---

# 18. Phase B implementation constraint

Phase B remains an **in-process boundary extraction first**, not a daemon rewrite.

Small pieces of that extraction have already begun on `main`, including testable Core policy for create-task preconditions, prompt-hold semantics, close semantics, and provider-thread resume provenance.

The next implementation slices should:

- continue moving durable lifecycle/control-plane policy into AppKit-independent ConduitCore types/protocols where practical;
- preserve current product behavior unless a separately evidenced defect requires change;
- route AppModel lifecycle operations through the extracted boundary rather than duplicating policy;
- add contract-level tests for each extracted semantic distinction;
- retain installed-app/provider-native canaries for boundaries the deterministic suite cannot reach;
- avoid selecting final process hosting;
- avoid recursive delegation;
- avoid broad UI redesign.

Only after enough ownership is behind that boundary should the GUI-termination/restart experiment determine whether a separate runtime host is actually required.

---

# 19. Evidence discipline for successor work

Future changes to this contract should preserve the distinction between:

- deterministic Core tests;
- installed-app canary evidence;
- provider-native ground truth;
- hosted MCP/tunnel observations;
- inference about architecture;
- untested capability.

A green Core suite does not establish installed runtime behavior. A provider's terminal status does not establish task success. A provider-grounded answer proves that the provider emitted that answer, not that the answer is correct. A clean run after an intermittent failure narrows the observed rate; it does not erase the failure.

When those boundaries matter, preserve the exact failure and the exact object under test.