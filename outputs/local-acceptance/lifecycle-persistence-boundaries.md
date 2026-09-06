# Lifecycle, persistence, and installed-app boundary receipt

Plan provenance: PR #5, `docs/LOCAL_ACCEPTANCE_AND_CONTROL_PLANE_TEST_PLAN.md`, blob `dcd1cfdc4f93aa6039585a4abfb48d2c8034e026`.

This receipt preserves the machine-bound lanes that could not be safely
completed because the local Session API write gate remained disabled. A
blocked test is evidence of the current boundary, not a passing substitute.

## Test context

- Test date/time: 2026-08-30T01:08:44Z
- Conduit SHA: `2c0f27c0008cb2cf8873685f909b385651ab63c9` for the acceptance source;
  the installed app used for read-only status was the fixed build recorded in
  `mcp-read-surface.md`
- Branch: `research/control-plane-local-acceptance-20260829`
- Machine/environment: macOS 26.5.2 (25F84), arm64; tmux 3.6b; SwiftTerm PTY
  support present; app Session API writes disabled
- Provider/runtime: installed Conduit.app and existing local task history
- Preconditions: no new task, runtime, approval, or provider process was
  created for these checks.

## L4 — tmux / PTY lifecycle

Test IDs: L4.1–L4.8

Expected: a controlled Conduit PTY task can be created detached, explicitly
left, reconnected, observed through external exit, and checked for startup
prompt delivery without inferring completion from silence.

Observed: the tmux binary was present at `3.6b`, and the connected read surface
reported an existing detached PTY task with `lifecycle: detached`,
`runtime_state: detached`, `recoverable: true`, and recovery action
`conduit_reconcile_task`. Its bounded events observation reported
`turn.state: ambiguous`, `thread_id_source: unavailable`,
`observation.checkpoint: capture_closed`, and
`provider_progress: unavailable`.

Result: BLOCKED for controlled create/leave/reconnect/external-exit/startup
prompt lanes; PASS only for prerequisite presence and read-only observation of
existing detached metadata.

Evidence: tmux version probe; actual connected `conduit_session_status` and
`conduit_session_events` metadata in `chatgpt-tunnel.md`. Task ID, title,
project, prompt, and rendered output were not retained.

Negative findings: no PTY quietness was interpreted as completion, and no
synthetic external process was substituted for a Conduit-owned session.

Follow-up: run the full L4 matrix only with an explicit controlled write fixture
and harmless deterministic prompt.

## L5 — persistence and restart

Test IDs: L5.1–L5.4

Expected: a controlled task can be created, persisted, restarted, reconciled,
and checked for duplicate runtime creation.

Observed: the read surface can enumerate existing sessions and report durable
metadata, but no task was created by this acceptance run. The one selected
existing detached task remained an observation with
`durable_state: registered`, `provisioning_state: unknown`, and a reconcile
action; this does not establish how its state was produced or whether restart
would recover it.

Result: BLOCKED for controlled persistence/restart/reconcile/duplicate-worker
experiment.

Evidence: bounded connected status/events metadata; no private history was
copied.

Negative findings: no process was killed, no runtime was duplicated, and no
durable record was edited.

Follow-up: preserve task ID, runtime-attempt ID, provider thread/session ID,
and event timeline in a private test log when the write gate can be enabled
under controlled conditions.

## L6 — GUI termination baseline

Test IDs: L6.1–L6.3

Expected: with one harmless task live, terminating and relaunching Conduit.app
would reveal which identities/state survive independently of the GUI.

Observed: Conduit.app itself was launched and its loopback listener was
reachable during this run. No harmless task/runtime was available for the
required pre-termination identity capture, so the GUI-kill experiment was not
performed. The app-only relaunch does not answer worker or provider survival.

Result: PASS for app launch/listener smoke only; BLOCKED for structured-provider
GUI-kill and recovery; BLOCKED for tmux/PTY GUI-kill comparison.

Evidence: installed-app listener probes and computer-use app-state checks; no
task/process identity was recorded.

Negative findings: no termination was used as a proxy for provider
interruption, completion, or recovery.

Follow-up: perform the two GUI-kill experiments only after a controlled task
creation path exists; record worker, provider thread, durable task, and event
outcomes independently.

## L6.4 — Approval restart baseline

Test ID: L6.4

Expected: a harmless provider approval state survives or is explicitly marked
ambiguous across GUI termination.

Observed: no provider task or approval was started. No automatic approval was
issued.

Result: UNTESTED

Evidence: absence of any task/runtime creation in the run and the unchanged
disabled write gate.

Negative findings: approval state was not inferred from an idle or detached
observation.

Follow-up: test only with a provider-specific harmless approval fixture.

## L6.5 — macOS permission and attachment boundaries

Test IDs: L6.5–L6.9

Expected: installed-app checks cover security-scoped MainFrame access, relaunch,
microphone/speech/screenshot permission, attachments, and removed paths.

Observed: the built app was launched and settings were inspected. The current
computer-control session could not reliably operate the relevant UI switches,
and no private MainFrame file or permission prompt was opened for this run.

Result: BLOCKED for microphone, speech, screenshot, attachment, inaccessible
path, and security-scoped access workflows.

Evidence: computer-use control limitation and app launch/listener smoke only.

Negative findings: no OS permission was changed and no private file contents
were copied.

Follow-up: run these boundary tests interactively with explicit operator
approval for each permission prompt and synthetic attachments.

## Scope boundary

OBSERVED: prerequisites and read-only detached metadata are available; the
write gate prevented controlled lifecycle experiments.

INFERRED: current observations do not discriminate durable initial-objective
delivery from strict two-phase create/start, nor GUI-hosted from independent
runtime hosting.

UNKNOWN: objective delivery timing/loss/duplication, provider survival,
reconnect, duplicate-worker behavior, approval persistence, and macOS boundary
workflows.
