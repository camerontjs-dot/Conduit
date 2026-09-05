# Control-plane orchestration exercise

Fan-out, admission ceiling, independent observation, a chained
dependent task, and release — the primitives an orchestrating agent
needs, which the single-task canary lanes never exercise together.

## Object under test

```
recorded_at: 2026-09-05T22:13:54Z
repo_head: 836ceb62ea2895187098df183468291ca437d592
repo_branch: main
repo_dirty: True
installed_app_sha256: 1aa2460fcb9863e6ca962eedcf16ca5175b87eb9a87bfac8b165ea6409402965
installed_app_present: True
macos: 26.5.2
arch: arm64
tmux: tmux 3.6b
shell: /bin/zsh
running_from: installed app
agent: Codex,OpenCode,Shell
enableSessionAPIWrites: True
```

## Result: 12 observed, 1 failed

### ORCH-1-create-alpha

- Date/time: 2026-09-05T22:13:54+00:00
- Expected: objective is accepted at create; Conduit owns delivery
- Observed: agent=Codex task=83F23FCF-3525-4FC9-A660-D4F1C124D951 delivery_state=queued resend_required=False
- Result: OBSERVED
- Evidence: `{"provisioning_state": "starting", "authority": "session created; not verification", "objective_resend_required": false, "recoverable": false, "project": "conduit", "ready": false, "origin": "chatgpt", "agent": "Codex", "runtime_state": "idle", "taskSessionID": "83F23FCF-3525-4FC9-A660-D4F1C124D951", "objective_authority": "Conduit owns delivery of this objective and will complete it without anoth`
- Negative findings: Accepting an objective is not running it.

### ORCH-1-create-bravo

- Date/time: 2026-09-05T22:13:59+00:00
- Expected: objective is accepted at create; Conduit owns delivery
- Observed: agent=OpenCode task=0D6CA8DD-3770-4EF0-8368-914806DC8502 delivery_state=queued resend_required=False
- Result: OBSERVED
- Evidence: `{"ready": false, "origin": "chatgpt", "objective_delivery_state": "queued", "taskSessionID": "0D6CA8DD-3770-4EF0-8368-914806DC8502", "recoverable": false, "authority": "session created; not verification", "objective_delivered": false, "title": "OpenCode \u00b7 Conduit", "project": "conduit", "agent": "OpenCode", "durable_state": "registered", "live": true, "runtime_state": "starting", "close_outco`
- Negative findings: Accepting an objective is not running it.

### ORCH-1-create-charlie

- Date/time: 2026-09-05T22:14:03+00:00
- Expected: objective is accepted at create; Conduit owns delivery
- Observed: agent=Shell task=70707165-6B9B-4DF1-8D20-93BCA5D2F83B delivery_state=queued resend_required=False
- Result: OBSERVED
- Evidence: `{"provisioning_state": "ready", "origin": "chatgpt", "objective_delivery_state": "queued", "recoverable": false, "taskSessionID": "70707165-6B9B-4DF1-8D20-93BCA5D2F83B", "authority": "session created; not verification", "objective_delivered": false, "title": "Shell \u00b7 Conduit", "project": "conduit", "durable_state": "registered", "live": true, "agent": "Shell", "runtime_state": "starting", "cl`
- Negative findings: Accepting an objective is not running it.

### ORCH-2-concurrent-live

- Date/time: 2026-09-05T22:14:03+00:00
- Expected: all three tasks exist concurrently with distinct ids
- Observed: distinct_ids=3 of 3
- Result: OBSERVED
- Evidence: `["83F23FCF-3525-4FC9-A660-D4F1C124D951", "0D6CA8DD-3770-4EF0-8368-914806DC8502", "70707165-6B9B-4DF1-8D20-93BCA5D2F83B"]`

### ORCH-3-admission-ceiling

- Date/time: 2026-09-05T22:14:09+00:00
- Expected: the create beyond the live-task cap is refused with a reason
- Observed: refused after 2 extra creates: mcp admission refused
- Result: OBSERVED
- Evidence: `{"admission": {"code": "global_live_task_limit_reached", "outcome": "rejected", "detail": "Global live-task capacity is full; finish or explicitly end a task before retrying."}, "error": "mcp admission refused", "authority": "admission decision; no runtime was started, changed, or ended"}`
- Negative findings: A cap that never refuses is not a cap.

### ORCH-4-turn-alpha

- Date/time: 2026-09-05T22:14:30+00:00
- Expected: the turn reaches a terminal state the caller can branch on
- Observed: turn=completed checkpoint=structured_completed
- Result: OBSERVED
- Negative findings: A terminal turn is not a correct answer.

### ORCH-4-turn-bravo

- Date/time: 2026-09-05T22:14:44+00:00
- Expected: the turn reaches a terminal state the caller can branch on
- Observed: turn=completed checkpoint=structured_completed
- Result: OBSERVED
- Negative findings: A terminal turn is not a correct answer.

### ORCH-4-turn-charlie

- Date/time: 2026-09-05T22:17:12+00:00
- Expected: the turn reaches a terminal state the caller can branch on
- Observed: turn=ambiguous checkpoint=output_quiet
- Result: FAIL
- Negative findings: A terminal turn is not a correct answer.

### ORCH-5-ground-truth-alpha

- Date/time: 2026-09-05T22:17:12+00:00
- Expected: the answer exists in the provider's own store, not only in Conduit
- Observed: agent=Codex source=codex-rollout provider_answer=ALPHA-13
- Result: OBSERVED
- Negative findings: An answer only Conduit recorded proves recording, not work.

### ORCH-5-ground-truth-bravo

- Date/time: 2026-09-05T22:17:12+00:00
- Expected: the answer exists in the provider's own store, not only in Conduit
- Observed: agent=OpenCode source=opencode-db provider_answer=BRAVO-7
- Result: OBSERVED
- Negative findings: An answer only Conduit recorded proves recording, not work.

### ORCH-5-ground-truth-charlie

- Date/time: 2026-09-05T22:17:12+00:00
- Expected: the answer exists in the provider's own store, not only in Conduit
- Observed: agent=Shell source=tmux:conduit-conduit-shell-cf21bcee-22 provider_answer=CHARLIE-5
- Result: OBSERVED
- Negative findings: An answer only Conduit recorded proves recording, not work.

### ORCH-6-chain

- Date/time: 2026-09-05T22:18:13+00:00
- Expected: a dependent task on another backend receives and acts on the first task's real output
- Observed: Codex -> OpenCode: turn=completed carried_prior_answer=True source='ALPHA-13'
- Result: OBSERVED
- Evidence: `ECHO-ALPHA-13`
- Negative findings: Carrying a value is not understanding it.

### ORCH-7-release

- Date/time: 2026-09-05T22:18:16+00:00
- Expected: every close states what it cost
- Observed: outcomes={'alpha': 'stopped', 'overflow1': 'stopped', 'chain': 'stopped'}
- Result: OBSERVED
- Evidence: `{"alpha": "stopped", "overflow1": "stopped", "chain": "stopped"}`
- Negative findings: close_outcome stopped means these tasks are not recoverable.

## Boundary

One machine, one project, adapters: Codex,OpenCode,Shell. Small
deterministic objectives. This establishes that the control plane can
carry work between agents; it establishes nothing about how well any
agent does the work. A model that answers wrongly still produces a
green transport lane, and the answers are recorded above so that
distinction stays visible.
