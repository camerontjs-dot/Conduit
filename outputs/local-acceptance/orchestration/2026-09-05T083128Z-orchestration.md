# Control-plane orchestration exercise

Fan-out, admission ceiling, independent observation, a chained
dependent task, and release — the primitives an orchestrating agent
needs, which the single-task canary lanes never exercise together.

## Object under test

```
recorded_at: 2026-09-05T08:29:35Z
repo_head: c7b7ac61e783a5621818f6fa73aa4e3ac4dfeae3
repo_branch: fix/opencode-lease-race
repo_dirty: True
installed_app_sha256: 1aa2460fcb9863e6ca962eedcf16ca5175b87eb9a87bfac8b165ea6409402965
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

- Date/time: 2026-09-05T08:29:35+00:00
- Expected: objective is accepted at create; Conduit owns delivery
- Observed: task=035EB3FE-70C9-48BB-ADEC-B21AFBE89B26 delivery_state=queued resend_required=False
- Result: OBSERVED
- Evidence: `{"runtime_state": "starting", "taskSessionID": "035EB3FE-70C9-48BB-ADEC-B21AFBE89B26", "provisioning_state": "starting", "objective_resend_required": false, "title": "OpenCode \u00b7 Conduit", "ready": false, "live": true, "agent": "OpenCode", "lifecycle": "starting", "objective_delivered": false, "durable_state": "registered", "authority": "session created; not verification", "objective_delivery_`
- Negative findings: Accepting an objective is not running it.

### ORCH-1-create-bravo

- Date/time: 2026-09-05T08:29:36+00:00
- Expected: objective is accepted at create; Conduit owns delivery
- Observed: task=9F31EC13-553E-4AAA-B04E-82975B5BAFA2 delivery_state=queued resend_required=False
- Result: OBSERVED
- Evidence: `{"runtime_state": "starting", "taskSessionID": "9F31EC13-553E-4AAA-B04E-82975B5BAFA2", "provisioning_state": "starting", "objective_resend_required": false, "title": "OpenCode \u00b7 Conduit", "ready": false, "live": true, "agent": "OpenCode", "lifecycle": "starting", "objective_delivered": false, "durable_state": "registered", "authority": "session created; not verification", "objective_delivery_`
- Negative findings: Accepting an objective is not running it.

### ORCH-1-create-charlie

- Date/time: 2026-09-05T08:29:37+00:00
- Expected: objective is accepted at create; Conduit owns delivery
- Observed: task=80AE1440-6835-4AF4-ADD4-D56C6BADC688 delivery_state=queued resend_required=False
- Result: OBSERVED
- Evidence: `{"runtime_state": "starting", "taskSessionID": "80AE1440-6835-4AF4-ADD4-D56C6BADC688", "provisioning_state": "starting", "objective_resend_required": false, "title": "OpenCode \u00b7 Conduit", "live": true, "ready": false, "agent": "OpenCode", "lifecycle": "starting", "objective_delivered": false, "durable_state": "registered", "authority": "session created; not verification", "objective_delivery_`
- Negative findings: Accepting an objective is not running it.

### ORCH-2-concurrent-live

- Date/time: 2026-09-05T08:29:37+00:00
- Expected: all three tasks exist concurrently with distinct ids
- Observed: distinct_ids=3 of 3
- Result: OBSERVED
- Evidence: `["035EB3FE-70C9-48BB-ADEC-B21AFBE89B26", "9F31EC13-553E-4AAA-B04E-82975B5BAFA2", "80AE1440-6835-4AF4-ADD4-D56C6BADC688"]`

### ORCH-3-admission-ceiling

- Date/time: 2026-09-05T08:29:38+00:00
- Expected: the create beyond the live-task cap is refused with a reason
- Observed: refused after 2 extra creates: mcp admission refused
- Result: OBSERVED
- Evidence: `{"error": "mcp admission refused", "authority": "admission decision; no runtime was started, changed, or ended", "admission": {"detail": "Global live-task capacity is full; finish or explicitly end a task before retrying.", "code": "global_live_task_limit_reached", "outcome": "rejected"}}`
- Negative findings: A cap that never refuses is not a cap.

### ORCH-4-turn-alpha

- Date/time: 2026-09-05T08:31:12+00:00
- Expected: the turn reaches a terminal state the caller can branch on
- Observed: turn=completed checkpoint=structured_completed
- Result: OBSERVED
- Negative findings: A terminal turn is not a correct answer.

### ORCH-4-turn-bravo

- Date/time: 2026-09-05T08:31:12+00:00
- Expected: the turn reaches a terminal state the caller can branch on
- Observed: turn=completed checkpoint=structured_completed
- Result: OBSERVED
- Negative findings: A terminal turn is not a correct answer.

### ORCH-4-turn-charlie

- Date/time: 2026-09-05T08:31:12+00:00
- Expected: the turn reaches a terminal state the caller can branch on
- Observed: turn=completed checkpoint=structured_completed
- Result: OBSERVED
- Negative findings: A terminal turn is not a correct answer.

### ORCH-5-ground-truth-alpha

- Date/time: 2026-09-05T08:31:12+00:00
- Expected: the answer exists in the provider's own store, not only in Conduit
- Observed: provider_answer=ALPHA-13
- Result: OBSERVED
- Negative findings: An answer only Conduit recorded proves recording, not work.

### ORCH-5-ground-truth-bravo

- Date/time: 2026-09-05T08:31:12+00:00
- Expected: the answer exists in the provider's own store, not only in Conduit
- Observed: provider_answer=BRAVO-7
- Result: OBSERVED
- Negative findings: An answer only Conduit recorded proves recording, not work.

### ORCH-5-ground-truth-charlie

- Date/time: 2026-09-05T08:31:12+00:00
- Expected: the answer exists in the provider's own store, not only in Conduit
- Observed: provider_answer=CHARLIE-5
- Result: OBSERVED
- Negative findings: An answer only Conduit recorded proves recording, not work.

### ORCH-6-chain

- Date/time: 2026-09-05T08:31:27+00:00
- Expected: a dependent task receives and acts on the first task's real output
- Observed: turn=completed carried_prior_answer=True source='ALPHA-13'
- Result: OBSERVED
- Evidence: `ECHO-ALPHA-13`
- Negative findings: Carrying a value is not understanding it.

### ORCH-7-release

- Date/time: 2026-09-05T08:31:28+00:00
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
