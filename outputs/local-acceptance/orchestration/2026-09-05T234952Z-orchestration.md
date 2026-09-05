# Control-plane orchestration exercise

Fan-out, admission ceiling, independent observation, a chained
dependent task, and release — the primitives an orchestrating agent
needs, which the single-task canary lanes never exercise together.

## Object under test

```
recorded_at: 2026-09-05T23:46:31Z
repo_head: bba24a9021a0084157c8106466b7db0152b9a87b
repo_branch: main
repo_dirty: False
installed_app_sha256: 92a6d285c1b08ea633afb232e1e3cf70bffac79e09d812bf9d4ba69295ed8cbe
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

- Date/time: 2026-09-05T23:46:31+00:00
- Expected: objective is accepted at create; Conduit owns delivery
- Observed: agent=Codex task=37FAF2C8-7B9E-431E-BCD5-0AD86A8B54B8 delivery_state=queued resend_required=False
- Result: OBSERVED
- Evidence: `{"taskSessionID": "37FAF2C8-7B9E-431E-BCD5-0AD86A8B54B8", "backend": "app-server", "lifecycle": "idle", "objective_resend_required": false, "durable_state": "registered", "live": true, "ready": false, "title": "Codex \u00b7 Conduit", "project": "conduit", "runtime_state": "idle", "recoverable": false, "origin": "chatgpt", "authority": "session created; not verification", "objective_delivered": fal`
- Negative findings: Accepting an objective is not running it.

### ORCH-1-create-bravo

- Date/time: 2026-09-05T23:46:32+00:00
- Expected: objective is accepted at create; Conduit owns delivery
- Observed: agent=OpenCode task=1E67F95F-5AB4-4675-8FE8-91DD017CCCE9 delivery_state=queued resend_required=False
- Result: OBSERVED
- Evidence: `{"title": "OpenCode \u00b7 Conduit", "objective_delivered": false, "origin": "chatgpt", "ready": false, "authority": "session created; not verification", "runtime_state": "starting", "taskSessionID": "1E67F95F-5AB4-4675-8FE8-91DD017CCCE9", "objective_delivery_state": "queued", "close_outcome": "stopped", "backend": "http-server", "durable_state": "registered", "lifecycle": "starting", "live": true`
- Negative findings: Accepting an objective is not running it.

### ORCH-1-create-charlie

- Date/time: 2026-09-05T23:46:33+00:00
- Expected: objective is accepted at create; Conduit owns delivery
- Observed: agent=Shell task=FF774D30-D05E-4940-81DA-F9397E12AABE delivery_state=queued resend_required=False
- Result: OBSERVED
- Evidence: `{"provisioning_state": "ready", "taskSessionID": "FF774D30-D05E-4940-81DA-F9397E12AABE", "agent": "Shell", "title": "Shell \u00b7 Conduit", "project": "conduit", "objective_delivery_state": "queued", "origin": "chatgpt", "recoverable": false, "durable_state": "registered", "backend": "pty", "live": true, "close_outcome": "detached", "runtime_state": "starting", "lifecycle": "starting", "objective_`
- Negative findings: Accepting an objective is not running it.

### ORCH-2-concurrent-live

- Date/time: 2026-09-05T23:46:33+00:00
- Expected: all three tasks exist concurrently with distinct ids
- Observed: distinct_ids=3 of 3
- Result: OBSERVED
- Evidence: `["37FAF2C8-7B9E-431E-BCD5-0AD86A8B54B8", "1E67F95F-5AB4-4675-8FE8-91DD017CCCE9", "FF774D30-D05E-4940-81DA-F9397E12AABE"]`

### ORCH-3-admission-ceiling

- Date/time: 2026-09-05T23:46:34+00:00
- Expected: the create beyond the live-task cap is refused with a reason
- Observed: refused after 2 extra creates: mcp admission refused
- Result: OBSERVED
- Evidence: `{"error": "mcp admission refused", "admission": {"detail": "Global live-task capacity is full; finish or explicitly end a task before retrying.", "code": "global_live_task_limit_reached", "outcome": "rejected"}, "authority": "admission decision; no runtime was started, changed, or ended"}`
- Negative findings: A cap that never refuses is not a cap.

### ORCH-4-turn-alpha

- Date/time: 2026-09-05T23:46:43+00:00
- Expected: the turn reaches a terminal state the caller can branch on
- Observed: agent=Codex turn=completed checkpoint=structured_completed
- Result: OBSERVED
- Negative findings: A terminal turn is not a correct answer.

### ORCH-4-turn-bravo

- Date/time: 2026-09-05T23:46:47+00:00
- Expected: the turn reaches a terminal state the caller can branch on
- Observed: agent=OpenCode turn=completed checkpoint=structured_completed
- Result: OBSERVED
- Negative findings: A terminal turn is not a correct answer.

### ORCH-4-turn-charlie

- Date/time: 2026-09-05T23:49:36+00:00
- Expected: a PTY reports ambiguity rather than inventing a turn result
- Observed: agent=Shell turn=ambiguous checkpoint=output_quiet
- Result: OBSERVED
- Negative findings: ambiguous is honest, not terminal. An orchestrator cannot detect PTY completion through the control plane and must not poll for a state that never arrives; confirm PTY work from the pane, or orchestrate through a structured backend.

### ORCH-5-ground-truth-alpha

- Date/time: 2026-09-05T23:49:36+00:00
- Expected: the answer exists in the provider's own store, not only in Conduit
- Observed: agent=Codex source=codex-rollout provider_answer=ALPHA-13
- Result: OBSERVED
- Negative findings: An answer only Conduit recorded proves recording, not work.

### ORCH-5-ground-truth-bravo

- Date/time: 2026-09-05T23:49:36+00:00
- Expected: the answer exists in the provider's own store, not only in Conduit
- Observed: agent=OpenCode source=opencode-db provider_answer=BRAVO-7
- Result: OBSERVED
- Negative findings: An answer only Conduit recorded proves recording, not work.

### ORCH-5-ground-truth-charlie

- Date/time: 2026-09-05T23:49:36+00:00
- Expected: the answer exists in the provider's own store, not only in Conduit
- Observed: agent=Shell source=tmux:conduit-conduit-shell-cf21bcee-24 provider_answer=CHARLIE-5
- Result: OBSERVED
- Negative findings: An answer only Conduit recorded proves recording, not work.

### ORCH-6-chain

- Date/time: 2026-09-05T23:49:52+00:00
- Expected: a dependent task on another backend receives and acts on the first task's real output
- Observed: Codex -> OpenCode: turn=completed carried_prior_answer=True source='ALPHA-13'
- Result: OBSERVED
- Evidence: `ECHO-ALPHA-13`
- Negative findings: Carrying a value is not understanding it.

### ORCH-7-release

- Date/time: 2026-09-05T23:49:52+00:00
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
