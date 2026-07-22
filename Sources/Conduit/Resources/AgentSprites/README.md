# Agent sprite provenance and use boundary

Conduit carries a deliberately small, copied subset of MainFrame's workstation
character art. It does not read from or control `workstation/` at runtime.

## Included identities

- `codex/`: copied from `workstation/assets/agents/codex/` on 2026-07-22.
  Its source record identifies an operator-delivered ChatGPT image received on
  2026-07-14, then sliced, transparency-repaired, and visually validated in
  MainFrame commit `c86610a`.
- `claude/`: copied from `workstation/assets/agents/claude/` on 2026-07-22.
  MainFrame commit `c86610a` records the delivered six-pose sheet and runtime
  validation, but the source tree does not carry a matching per-character
  provenance README. Treat the generation route as incompletely documented.

Cameron explicitly authorized internal Conduit reuse for this finish task on
2026-07-22. No separate license or public-redistribution proof was found in the
source folders. This copy therefore records internal-use provenance; it does
not assert that publishing these assets is cleared.

## Runtime semantics

Each exact identity uses six poses, driven only by observed terminal state:

| Observed state | Pose | Meaning boundary |
| --- | --- | --- |
| starting | `clipboard` | process launch is underway |
| output active | `magnifying-glass` | recent PTY output was observed |
| ready | `skeptical` | session is running and currently quiet |
| detached | `shrug` | UI detached; background progress is unknown |
| exited | `sleeping-coffee` | the process exited; success is not implied |
| failed | `pointing-warning` | launch or process failure was observed |

Shell, Gemini, OpenCode, and custom profiles use Conduit's in-code generic
pixel character with an accessibility hint explaining that no dedicated sprite
is available. Similar names are not fuzzy-matched to a known identity.

The SHA-256 manifest beside this file binds every copied PNG to the inspected
source set.
