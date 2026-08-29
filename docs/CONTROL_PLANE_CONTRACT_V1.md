# Conduit Control-Plane Contract v1

Status: proposed contract freeze  
Programme authority: issue #4  
Machine-bound evidence dependency: issue #3

## Purpose

This document defines the first explicit contract for separating Conduit's execution/control-plane semantics from the macOS user interface.

It is intentionally implementation-neutral.

The contract may initially be implemented in-process. It does not select XPC, a helper process, launchd, a daemon, or any other hosting mechanism.

The goal is to establish the semantics that any future host and any client must preserve.

---

# 1. Product boundary

Conduit is a local agent execution and governance control plane.

It owns:

- task identity;
- runtime-attempt identity;
- provider adapter leases/process ownership;
- turn lifecycle;
- prompt delivery state;
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

The macOS application is a privileged client of this control plane.

External orchestration surfaces such as MCP are adapters over this control plane.

No external protocol is the internal semantic authority.

---

# 2. Authority separation

The following states are independent.

## 2.1 Task state

A task is the durable identity of an intended unit of work.

Initial v1 states:

```
proposed
approved
admitted
started
closed
```

A task may outlive multiple runtime attempts.

A task being `closed` does not by itself mean the requested work was successful.

## 2.2 Runtime-attempt state

A runtime attempt is one concrete provider/process execution attempt for a task.

Initial v1 states:

```
starting
ready
running
detached
exited
failed
```

A runtime exit is an execution observation, not a work-verification result.

## 2.3 Turn state

A turn is one admitted prompt/instruction interaction with a provider runtime.

Initial v1 states:

```
queued
delivered
active
awaiting_input
completed
cancelled
failed
ambiguous
```

Provider-reported completion may justify `completed` at the turn axis.

It does not verify the task's requested outcome.

PTY output quietness must not produce `completed`.

## 2.4 Approval state

Initial v1 states:

```
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

```
no_claim
claimed_complete
```

This captures only what the agent claims about its work.

It is not verification.

## 2.6 Verification state

Initial v1 values:

```
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
- agent "done" prose with verified completion;
- interrupt request with observed interruption;
- prompt queued with prompt delivered;
- prompt delivered with provider acknowledged;
- output quietness with provider completion;
- retrieved context with verified evidence;
- UI selection with runtime ownership;
- MCP tool publication with authorization.

Where evidence is insufficient, the state should remain explicit or ambiguous rather than being inferred upward.

---

# 4. Identity model

The following identifiers are distinct.

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

Identity for one admitted prompt/instruction interaction.

Required for:

- delivery acknowledgement;
- provider progress;
- completion/cancellation/failure;
- approval association;
- interrupt association.

## 4.4 provider_thread_id

Native provider thread/session identity where available.

The control plane must also record the source of the identity:

- live;
- persisted;
- unavailable.

## 4.5 approval_id

Identity for one approval request.

## 4.6 event_id

Stable identity for a durable supervisory event.

## 4.7 principal_id

Identity for the authenticated caller/capability principal.

Self-declared client metadata may be retained as descriptive provenance but must not be the sole security authority for future write-capable clients.

---

# 5. Internal command contract

The internal command surface is semantic and independent of MCP tool count or hosted-client entitlement.

Initial v1 command families:

## CreateTask

Inputs should include, at minimum:

- project/scope identity;
- agent/profile identity;
- objective or explicit absence of objective according to the selected delivery contract;
- origin/principal;
- optional idempotency key;
- optional lineage metadata where supported.

Outputs should distinguish:

- admitted/refused;
- created task id;
- runtime attempt id when provisioned;
- initial-objective state;
- admission refusal reason.

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

## ReconcileTask

Reconciles durable task state against current provider/runtime observations.

Reconciliation must not fabricate work verification.

## RequestInterrupt

Creates a durable interrupt-request event before or with the backend request.

The output acknowledges only the request.

Observed provider cancellation/interruption is a separate event.

## CloseTask

Closes Conduit's task lifecycle according to explicit policy.

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

Initial v1 query families:

## ListTasks

Supports deterministic ordering and pagination.

## GetTask

Returns current projections for:

- task;
- runtime attempt;
- turn;
- approval;
- agent claim;
- verification.

These axes must remain separately labelled.

## ListAdapters

Returns declared and observed adapter capabilities separately where possible.

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

# 7. Initial-objective delivery decision

The current implementation may create a task while returning `objective_delivered: false` when the runtime is not yet ready.

That behavior is not accepted as the target control-plane contract.

The programme must choose one of two explicit semantics.

## Candidate A: durable create intent

Preferred candidate pending local evidence.

`CreateTask(objective)` durably records the objective as part of the accepted task intent.

Conduit then owns exactly-once eventual initial delivery once the selected runtime is ready, unless a terminal failure occurs.

Required observable stages:

```
task_created
objective_queued
objective_delivery_attempted
objective_delivered | objective_delivery_failed
```

A duplicate idempotent create must not duplicate objective delivery.

## Candidate B: strict two-phase start

`CreateTask` creates/adopts only the task/runtime.

A separate `StartTurn` command carries the first instruction.

This avoids implicit eventual delivery but requires the caller to perform two explicit operations.

## Freeze rule

Do not choose between A and B solely from preference.

Use the local L3.3 and L10.4 evidence from the local acceptance plan to document current behavior and failure modes before final acceptance.

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
- provider thread id/source;
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
- `runtime_exited`, not `task_succeeded`.

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
- a future write-capable subset.

The choice must preserve:

- per-action authorization;
- confirmation clarity;
- structured refusal;
- idempotency;
- authority labels;
- evidence quality.

Do not change the internal command model merely to satisfy a temporary hosted-tool count or plan entitlement.

Do not disguise mutation as a read operation.

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

Before any agent-to-agent delegation, add minimal lineage fields:

- parent_task_id;
- delegated_by;
- origin;
- proposal_id;
- verification_of;
- runtime_attempt_id.

This is not authorization for a general DAG engine.

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

The control plane must eventually define explicit behavior for:

- GUI restart;
- control-plane host restart;
- provider process exit;
- provider transport disconnect;
- tmux detach/orphan;
- stale provider thread id;
- pending approval at restart;
- interrupt request followed by disconnect;
- duplicate create retry;
- incomplete prompt delivery;
- partial/corrupt local event log.

Recovery may yield `ambiguous`, `failed`, or `inconclusive`.

It must not invent a successful state.

---

# 16. Phase A acceptance conditions

This contract can be considered accepted for Phase A when:

1. issue #3 machine-bound results needed to constrain the contract are linked;
2. current initial-objective behavior is observed and recorded;
3. task/runtime/turn/approval/verification separation is accepted;
4. command/query/event families are accepted;
5. capability classes are accepted;
6. MCP is explicitly treated as an adapter rather than the internal semantic authority;
7. no hosting mechanism is prematurely selected;
8. explicit unknowns remain listed.

Acceptance of this contract does not claim UI-independent runtime ownership is implemented.

---

# 17. Known unknowns before Phase B

The following remain intentionally unresolved until local evidence exists:

- exact failure modes of current initial-objective delivery;
- provider-specific resume reliability;
- provider-specific observed interrupt/cancel semantics;
- approval recovery after GUI restart;
- whether current runtime ownership can be extracted in-process without large AppModel surgery;
- whether a helper/XPC/launch-agent host is ultimately required;
- actual hosted MCP capabilities of the user's connected ChatGPT surface at execution time;
- control-plane restart semantics for active non-tmux structured providers.

These unknowns are inputs to the next design step, not blanks to fill with assumptions.

---

# 18. Phase B implementation constraint

The first implementation PR after contract acceptance should be an **in-process boundary extraction**, not a daemon rewrite.

It should:

- introduce testable control-plane protocols/types in ConduitCore where practical;
- preserve current product behavior;
- route AppModel lifecycle operations through the new boundary;
- add contract-level tests;
- avoid selecting final process hosting;
- avoid adding delegation;
- avoid broad UI redesign.

Only after that boundary exists should the GUI-termination/restart experiment determine the next runtime-hosting change.
