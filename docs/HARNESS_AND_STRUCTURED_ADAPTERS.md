# Harness + structured adapters (operator note)

## Short answer

**Yes — Conduit can take data more directly from a CLI when the CLI (or a thin
wrapper) exposes a real protocol.** That does **not** break the Raw contract if
those events are labelled as structured/adapter-sourced and Raw remains the
live PTY for everything the protocol does not cover.

**No — Conduit should not invent assistant messages from terminal paint and call
them ground truth.** That *would* break the epistemic contract.

## What “direct from CLI” can mean

| Path | Authority | Use in Conversation |
|------|-----------|---------------------|
| PTY / tmux rendered buffer | `derivedFromRaw` | Best-effort projection; scrub chrome for reading |
| ACP / agent JSON event stream | `toolReported` / structured adapter | Growing assistant turns with real boundaries |
| Host envelope (already shipped) | Conduit-recorded delivery context | Not assistant content — prompt packaging only |
| Full “fake chat” replacement of PTY | Rejected for TUI agents | Loses approvals, durability, true CLI |

## Harness attached to Conduit

A good harness is an **adapter host**:

1. Conduit still owns **tmux/PTY** and the real agent process (D-003, D-015).
2. On launch, Conduit may wrap `command` with a small shim that:
   - enables ACP or another sideband when the agent supports it, **or**
   - tees structured stdout while the interactive TUI still runs in the pane.
3. Structured events land in Conversation with explicit authority.
4. If the sideband dies, Conversation falls back to Derived-from-Raw; operator
   always has **Raw**.

A bad harness:

- Hides the PTY and pretends every agent is OpenAI Chat Completions.
- Auto-approves tools “for UX” without operator policy (see permission modes).
- Treats harness summaries as verified completion (violates D-011 / D-022).

## Recommended build order

1. **Presentation** (done in the workstation Conversation pass): turn document,
   scrubbing, quiet provenance — works on today’s Derived-from-Raw.
2. **Per-agent structured probes** where free: e.g. agents with documented ACP
   or `--output-format stream-json` style modes, only when they coexist with PTY.
3. **Optional launch harness** as a settings-backed wrapper per agent profile,
   not a global interceptor.
4. Keep **permission modes** (launch flags) separate from Conversation chrome.

## Relation to existing enums

`AgentOutputExtraction.structuredAdapter` and
`SessionEventAuthority.toolReported` already exist. The missing work is wiring
real producers — not inventing a second authority model.
