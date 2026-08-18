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
`SessionEventAuthority.toolReported` already exist. Codex `app-server` is the
first producer (D-038). Other agents still degrade to Derived-from-Raw.

## Verification required before calling this daily-driver

This slice is **not** installed-app smoked. Do not treat `swift build` as
operator proof.

Required on a machine with full Xcode when possible:

```bash
swift run conduit-selftest
swift test
./scripts/build-app.sh
```

Then one **disposable** Codex New Task in the installed app (not a live work
session):

1. Status says app-server, not an immediate silent PTY fallback.
2. Composer send grows Conversation with a structured-adapter / `toolReported`
   label (not only Derived-from-Raw).
3. An approval request shows Allow/Deny and does **not** auto-accept.
4. Close & Receipt still writes an evidence-aware receipt; turn completion is
   not treated as success.
5. Leave/End stops the app-server process (no tmux durability for this host).
6. If `codex` is missing or initialize fails, fallback to PTY is explicit.

Do not spend Codex `turn/start` quota from automation. An operator must be
present for approvals.

`swift test` was not run on the 2026-08-13 authoring machine (Command Line
Tools only; XCTest module unavailable). Selftest was 325 passed; Conduit
target compiled.

## Next moves (in order)

1. Rebuild/install and run the disposable Codex smoke above (still required).
2. Confirm Reconnect on a Codex task after Leave starts app-server / 
   `thread/resume` rather than a PTY.
3. Confirm Raw attach via `codex --remote` when a unix socket is present.
4. Session API: enable in Settings, `curl` `/healthz` and `POST /mcp` with
   the bearer token in `~/.conduit/session-api-token`.
5. ChatGPT: enable Session API writes, then
   `export CONTROL_PLANE_API_KEY=sk-...` and `scripts/chatgpt-tunnel`.
   Developer Mode → Connectors → Tunnel, paste `~/.conduit/chatgpt-tunnel-id`.
   Use Chat, not Work. Approvals stay in Conduit.
6. Daily-driver UX cuts remain the installed-app next_action unless the
   operator pauses them.
