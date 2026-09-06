# Control-plane orchestration exercise

Fan-out, admission ceiling, independent observation, a chained
dependent task, and release — the primitives an orchestrating agent
needs, which the single-task canary lanes never exercise together.

## Object under test

```
recorded_at: 2026-09-05T08:21:48Z
repo_head: db7381b9a3fa80a0cbd25d22a2c1afbeafaa543c
repo_branch: fix/hold-objective-until-ready
repo_dirty: True
installed_app_sha256: 1b9e745b0c51a75fdd625db795a8de646da73da041a31361d4a7959ad5adb1e0
installed_app_present: True
macos: 26.5.2
arch: arm64
tmux: tmux 3.6b
shell: /bin/zsh
running_from: installed app
agent: OpenCode
enableSessionAPIWrites: True
```

## Result: 13 observed, 0 failed

### ORCH-1-create-alpha

- Date/time: 2026-09-05T08:21:48+00:00
- Expected: objective is accepted at create; Conduit owns delivery
- Observed: task=BC5D4D35-5173-493D-9E56-EDB383E56B32 delivery_state=queued resend_required=False
- Result: OBSERVED
- Evidence: `{"objective_delivered": false, "live": true, "agent": "OpenCode", "origin": "chatgpt", "ready": false, "project": "conduit", "recoverable": false, "runtime_state": "starting", "provisioning_state": "starting", "title": "OpenCode \u00b7 Conduit", "backend": "http-server", "objective_authority": "Conduit owns delivery of this objective and will complete it without another call. Do not resend; poll c`
- Negative findings: Accepting an objective is not running it.

### ORCH-1-create-bravo

- Date/time: 2026-09-05T08:21:49+00:00
- Expected: objective is accepted at create; Conduit owns delivery
- Observed: task=982CD1C2-C02C-423F-A2B6-8D46BDFC597E delivery_state=queued resend_required=False
- Result: OBSERVED
- Evidence: `{"objective_delivered": false, "live": true, "agent": "OpenCode", "origin": "chatgpt", "ready": false, "project": "conduit", "recoverable": false, "runtime_state": "starting", "provisioning_state": "starting", "backend": "http-server", "title": "OpenCode \u00b7 Conduit", "objective_authority": "Conduit owns delivery of this objective and will complete it without another call. Do not resend; poll c`
- Negative findings: Accepting an objective is not running it.

### ORCH-1-create-charlie

- Date/time: 2026-09-05T08:21:49+00:00
- Expected: objective is accepted at create; Conduit owns delivery
- Observed: task=0D83FDB2-FF1C-4D06-92E6-65C57AF64D1C delivery_state=queued resend_required=False
- Result: OBSERVED
- Evidence: `{"lifecycle": "starting", "close_outcome": "stopped", "runtime_state": "starting", "objective_resend_required": false, "project": "conduit", "title": "OpenCode \u00b7 Conduit", "taskSessionID": "0D83FDB2-FF1C-4D06-92E6-65C57AF64D1C", "backend": "http-server", "durable_state": "registered", "origin": "chatgpt", "authority": "session created; not verification", "agent": "OpenCode", "ready": false, "`
- Negative findings: Accepting an objective is not running it.

### ORCH-2-concurrent-live

- Date/time: 2026-09-05T08:21:49+00:00
- Expected: all three tasks exist concurrently with distinct ids
- Observed: distinct_ids=3 of 3
- Result: OBSERVED
- Evidence: `["BC5D4D35-5173-493D-9E56-EDB383E56B32", "982CD1C2-C02C-423F-A2B6-8D46BDFC597E", "0D83FDB2-FF1C-4D06-92E6-65C57AF64D1C"]`

### ORCH-3-admission-ceiling

- Date/time: 2026-09-05T08:21:51+00:00
- Expected: the create beyond the live-task cap is refused with a reason
- Observed: refused after 2 extra creates: mcp admission refused
- Result: OBSERVED
- Evidence: `{"admission": {"code": "global_live_task_limit_reached", "detail": "Global live-task capacity is full; finish or explicitly end a task before retrying.", "outcome": "rejected"}, "authority": "admission decision; no runtime was started, changed, or ended", "error": "mcp admission refused"}`
- Negative findings: A cap that never refuses is not a cap.

### ORCH-4-turn-alpha

- Date/time: 2026-09-05T08:22:11+00:00
- Expected: the turn reaches a terminal state the caller can branch on
- Observed: turn=completed checkpoint=structured_completed
- Result: OBSERVED
- Negative findings: A terminal turn is not a correct answer.

### ORCH-4-turn-bravo

- Date/time: 2026-09-05T08:22:20+00:00
- Expected: the turn reaches a terminal state the caller can branch on
- Observed: turn=completed checkpoint=structured_completed
- Result: OBSERVED
- Negative findings: A terminal turn is not a correct answer.

### ORCH-4-turn-charlie

- Date/time: 2026-09-05T08:22:36+00:00
- Expected: the turn reaches a terminal state the caller can branch on
- Observed: turn=completed checkpoint=structured_completed
- Result: OBSERVED
- Negative findings: A terminal turn is not a correct answer.

### ORCH-5-ground-truth-alpha

- Date/time: 2026-09-05T08:22:36+00:00
- Expected: the answer exists in the provider's own store, not only in Conduit
- Observed: provider_answer=ALPHA-13
- Result: OBSERVED
- Negative findings: An answer only Conduit recorded proves recording, not work.

### ORCH-5-ground-truth-bravo

- Date/time: 2026-09-05T08:22:36+00:00
- Expected: the answer exists in the provider's own store, not only in Conduit
- Observed: provider_answer=BRAVO-7
- Result: OBSERVED
- Negative findings: An answer only Conduit recorded proves recording, not work.

### ORCH-5-ground-truth-charlie

- Date/time: 2026-09-05T08:22:36+00:00
- Expected: the answer exists in the provider's own store, not only in Conduit
- Observed: provider_answer=CHARLIE-5
- Result: OBSERVED
- Negative findings: An answer only Conduit recorded proves recording, not work.

### ORCH-6-chain

- Date/time: 2026-09-05T08:22:53+00:00
- Expected: a dependent task receives and acts on the first task's real output
- Observed: turn=completed carried_prior_answer=True source='ALPHA-13'
- Result: OBSERVED
- Evidence: `ECHO-ALPHA-13`
- Negative findings: Carrying a value is not understanding it.

### ORCH-7-release

- Date/time: 2026-09-05T08:22:54+00:00
- Expected: every close states what it cost
- Observed: outcomes={'alpha': 'stopped', 'overflow1': 'stopped', 'chain': 'stopped'}
- Result: OBSERVED
- Evidence: `{"alpha": "stopped", "overflow1": "stopped", "chain": "stopped"}`
- Negative findings: close_outcome stopped means these tasks are not recoverable.

## Boundary

One machine, one project, the OpenCode adapter, small
deterministic objectives. This establishes that the control plane can
carry work between agents; it establishes nothing about how well any
agent does the work. A model that answers wrongly still produces a
green transport lane, and the answers are recorded above so that
distinction stays visible.
