# Agent sprite contract, provenance, and insertion seam

Conduit carries a deliberately small, copied subset of MainFrame character art.
It does not read from or control another sprite repository at runtime. Character
art is presentation only: it never establishes agent availability, work quality,
completion, verification, or terminal authority.

The external [Conduit sprite handoff](https://github.com/camerontjs-dot/Mainframe-pixel-sprites/blob/main/conduit/README.md)
is a design and approval reference. Conduit does not fetch from it, and a file
existing there is not enough to approve or bundle that file here.

## Bundled provenance ledger

- `codex/`: copied from `workstation/assets/agents/codex/` on 2026-07-22.
  Its source record identifies an operator-delivered ChatGPT image received on
  2026-07-14, then sliced, transparency-repaired, and visually validated in
  MainFrame commit `c86610a`. Exact profile signatures are `Codex` + `codex`.
- `claude/`: copied from `workstation/assets/agents/claude/` on 2026-07-22.
  MainFrame commit `c86610a` records the delivered six-pose sheet and runtime
  validation, but the source tree does not carry a matching per-character
  provenance README. Treat the generation route as incompletely documented.
  Exact profile signatures are `Claude` + `claude` and `Claude Code` + `claude`.

- `masters/`: imported on 2026-08-11 as interim companion identities for the
  eight built-in profiles. These are operator-locked masters downscaled to 256px
  height with nearest-neighbor, one presentation file per identity. They are not
  six-pose sets and never satisfy the completeness gate above. Per-file source,
  lock records, and import route are in `masters/README.md`. They are bundled
  and rendered, so they carry `SHA256SUMS` entries like every other PNG here; a
  rendered image that nothing pins can drift without anyone noticing.

Cameron explicitly authorized internal Conduit reuse for this finish task on
2026-07-22. No separate license or public-redistribution proof was found in the
source folders. This ledger records internal-use provenance; it does not claim
that publishing the assets is cleared.

The existing Claude and Codex canvases differ in size. They are grandfathered
as the approved exact files bound by `SHA256SUMS`; equal dimensions are not a
runtime or build requirement.

## Fixed six-pose convention

Every dedicated skin directory must contain these exact filenames:

1. `clipboard.png`
2. `magnifying-glass.png`
3. `pointing-warning.png`
4. `skeptical.png`
5. `shrug.png`
6. `sleeping-coffee.png`

`AgentSpriteCatalog` is the single profile-to-skin registry. Matching is
case-insensitive after trimming, but otherwise exact: one registered full
profile name **and** its executable basename must agree. Similar, punctuated,
partial, wrapper, and conflicting identities remain generic.

The app loads a registered set atomically. All six images must decode, all six
paths must have SHA-256 entries, and this ledger must name the skin. A missing,
partial, unreadable, unmanifested, or unrecorded set uses the in-code generic
placeholder for every pose; Conduit never mixes dedicated and generic poses.

## Runtime semantics

Launched poses follow only observed terminal state:

| Observed state | Pose | Meaning boundary |
| --- | --- | --- |
| starting | `clipboard.png` | process launch is underway |
| output active | `magnifying-glass.png` | recent PTY output was observed |
| attached, output quiet | `skeptical.png` | session is running; no work outcome is implied |
| detached | `shrug.png` | UI detached; background progress is unknown |
| exited | `sleeping-coffee.png` | process exited; success is not implied |
| failed | `pointing-warning.png` | launch or process failure was observed |

Available is not a launched lifecycle pose. It uses the neutral generic
character and a faint mark, with adjacent `Available` text, so it stays distinct
from detached, exited, and failed.

The bundled poses swap immediately and have no decorative animation. Reduce
Motion therefore remains immediate by construction. A periodic UI refresh may
observe terminal state changing; that observation is not cosmetic motion.

The sprite itself is hidden from VoiceOver because adjacent lifecycle and
authority text is canonical. Those surrounding labels also disclose either a
dedicated character or a `Generic placeholder companion`. Placeholder status
never substitutes for availability or lifecycle text.

## Built-in profile coverage

- Dedicated exact art (six poses): Claude and Codex.
- Locked masters (interim companion identity, not six-pose complete): under
  `masters/<skin>/master.png` for Claude, Codex, Shell (`local-shell`), Grok,
  Antigravity, OpenCode, Gemini CLI, and Ollama. Soft-mapped by profile name or
  executable; labeled “locked master companion (poses pending)” in the UI.
- Generic vector placeholder: any profile without a master or exact set
  (Cursor Agent, Aider, custom commands).

This list describes art coverage only. It does not claim that a command is
enabled, authenticated, within quota, running, or capable of completing work.

## Adding a future approved skin

A future builder should make one bounded insertion:

1. Complete the external approval-board checks for hard alpha, useful bounding
   box, source dimensions, and readability at the 64-point review size. These
   checks are approval evidence, not new runtime status.
2. Add one `AgentSpriteSkin` id and one or more exact full-name + executable
   signatures to `Sources/ConduitCore/AgentSpriteCatalog.swift`.
3. Place the approved six files in `AgentSprites/<skin-id>/` using the fixed
   filenames above. Do not edit SwiftUI or layout code.
4. Add a ledger entry here recording source URL/path, approving operator and
   date, generator stack/version, seed/prompt/profile reference and generation
   date where applicable, transformations, approval-board reference, and the
   license/redistribution boundary.
5. Append exactly six unique lowercase SHA-256 entries to `SHA256SUMS`, one per
   canonical path. Duplicate, missing, uppercase, or extra/unmanifested PNG
   entries fail the source verification gate.
6. Run the focused sprite tests, selftest, full build, package, codesign check,
   VoiceOver label pass, and Reduce Motion pass.

Stop and keep the profile generic if any file, hash, decode, provenance,
approval, identity, or accessibility gate is unresolved.

Verify the current copied files from this directory:

```sh
shasum -a 256 -c SHA256SUMS
```
