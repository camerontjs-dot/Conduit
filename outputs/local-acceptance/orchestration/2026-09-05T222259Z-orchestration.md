# Control-plane orchestration exercise

Fan-out, admission ceiling, independent observation, a chained
dependent task, and release — the primitives an orchestrating agent
needs, which the single-task canary lanes never exercise together.

## Object under test

```
recorded_at: 2026-09-05T22:18:50Z
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

## Result: 13 observed, 0 failed

### ORCH-1-create-alpha

- Date/time: 2026-09-05T22:18:50+00:00
- Expected: objective is accepted at create; Conduit owns delivery
- Observed: agent=Codex task=3CABCA60-97DB-42AA-8C04-308E641F25F9 delivery_state=queued resend_required=False
- Result: OBSERVED
- Evidence: `{"project": "conduit", "agent": "Codex", "provisioning_state": "starting", "taskSessionID": "3CABCA60-97DB-42AA-8C04-308E641F25F9", "recoverable": false, "lifecycle": "idle", "runtime_state": "idle", "authority": "session created; not verification", "objective_delivery_state": "queued", "objective_resend_required": false, "live": true, "durable_state": "registered", "origin": "chatgpt", "ready": f`
- Negative findings: Accepting an objective is not running it.

### ORCH-1-create-bravo

- Date/time: 2026-09-05T22:18:54+00:00
- Expected: objective is accepted at create; Conduit owns delivery
- Observed: agent=OpenCode task=C4BB4577-4DAB-45CC-AD4C-2C3CFD1F0ACE delivery_state=queued resend_required=False
- Result: OBSERVED
- Evidence: `{"project": "conduit", "agent": "OpenCode", "provisioning_state": "starting", "taskSessionID": "C4BB4577-4DAB-45CC-AD4C-2C3CFD1F0ACE", "recoverable": false, "lifecycle": "starting", "runtime_state": "starting", "authority": "session created; not verification", "objective_delivery_state": "queued", "objective_resend_required": false, "live": true, "durable_state": "registered", "origin": "chatgpt",`
- Negative findings: Accepting an objective is not running it.

### ORCH-1-create-charlie

- Date/time: 2026-09-05T22:18:58+00:00
- Expected: objective is accepted at create; Conduit owns delivery
- Observed: agent=Shell task=5F90F491-DE6B-4908-8356-80667DB99D1C delivery_state=queued resend_required=False
- Result: OBSERVED
- Evidence: `{"objective_delivered": false, "agent": "Shell", "title": "Shell \u00b7 Conduit", "recoverable": false, "taskSessionID": "5F90F491-DE6B-4908-8356-80667DB99D1C", "runtime_state": "starting", "durable_state": "registered", "objective_authority": "Conduit owns delivery of this objective and will complete it without another call. Do not resend; poll conduit_session_events for the recorded delivery sta`
- Negative findings: Accepting an objective is not running it.

### ORCH-2-concurrent-live

- Date/time: 2026-09-05T22:18:58+00:00
- Expected: all three tasks exist concurrently with distinct ids
- Observed: distinct_ids=3 of 3
- Result: OBSERVED
- Evidence: `["3CABCA60-97DB-42AA-8C04-308E641F25F9", "C4BB4577-4DAB-45CC-AD4C-2C3CFD1F0ACE", "5F90F491-DE6B-4908-8356-80667DB99D1C"]`

### ORCH-3-admission-ceiling

- Date/time: 2026-09-05T22:19:04+00:00
- Expected: the create beyond the live-task cap is refused with a reason
- Observed: refused after 2 extra creates: mcp admission refused
- Result: OBSERVED
- Evidence: `{"authority": "admission decision; no runtime was started, changed, or ended", "admission": {"code": "global_live_task_limit_reached", "outcome": "rejected", "detail": "Global live-task capacity is full; finish or explicitly end a task before retrying."}, "error": "mcp admission refused"}`
- Negative findings: A cap that never refuses is not a cap.

### ORCH-4-turn-alpha

- Date/time: 2026-09-05T22:19:21+00:00
- Expected: the turn reaches a terminal state the caller can branch on
- Observed: agent=Codex turn=completed checkpoint=structured_completed
- Result: OBSERVED
- Negative findings: A terminal turn is not a correct answer.

### ORCH-4-turn-bravo

- Date/time: 2026-09-05T22:19:45+00:00
- Expected: the turn reaches a terminal state the caller can branch on
- Observed: agent=OpenCode turn=completed checkpoint=structured_completed
- Result: OBSERVED
- Negative findings: A terminal turn is not a correct answer.

### ORCH-4-turn-charlie

- Date/time: 2026-09-05T22:22:06+00:00
- Expected: a PTY reports ambiguity rather than inventing a turn result
- Observed: agent=Shell turn=ambiguous checkpoint=output_quiet
- Result: OBSERVED
- Negative findings: ambiguous is honest, not terminal. An orchestrator cannot detect PTY completion through the control plane and must not poll for a state that never arrives; confirm PTY work from the pane, or orchestrate through a structured backend.

### ORCH-5-ground-truth-alpha

- Date/time: 2026-09-05T22:22:06+00:00
- Expected: the answer exists in the provider's own store, not only in Conduit
- Observed: agent=Codex source=codex-rollout provider_answer=ALPHA-13
- Result: OBSERVED
- Negative findings: An answer only Conduit recorded proves recording, not work.

### ORCH-5-ground-truth-bravo

- Date/time: 2026-09-05T22:22:06+00:00
- Expected: the answer exists in the provider's own store, not only in Conduit
- Observed: agent=OpenCode source=opencode-db provider_answer=BRAVO-7
- Result: OBSERVED
- Negative findings: An answer only Conduit recorded proves recording, not work.

### ORCH-5-ground-truth-charlie

- Date/time: 2026-09-05T22:22:06+00:00
- Expected: the answer exists in the provider's own store, not only in Conduit
- Observed: agent=Shell source=tmux:conduit-conduit-shell-cf21bcee-23 provider_answer=CHARLIE-5
- Result: OBSERVED
- Negative findings: An answer only Conduit recorded proves recording, not work.

### ORCH-6-chain

- Date/time: 2026-09-05T22:22:55+00:00
- Expected: a dependent task on another backend receives and acts on the first task's real output
- Observed: Codex -> OpenCode: turn=completed carried_prior_answer=True source='ALPHA-13'
- Result: OBSERVED
- Evidence: `ECHO-ALPHA-13`
- Negative findings: Carrying a value is not understanding it.

### ORCH-7-release

- Date/time: 2026-09-05T22:22:59+00:00
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
