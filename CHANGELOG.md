# Changelog

All notable product changes to Conduit are recorded here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Dates are UTC calendar days of the nested workbench commit unless noted.

## Maintenance rule

**Any user-visible product change that lands on nested `main` must update this file in the same commit (or the same PR / session before handoff).**

| Change type | Changelog section |
| --- | --- |
| New capability the operator can use | `Added` |
| Change to existing behavior/UI | `Changed` |
| Fix for incorrect/broken behavior | `Fixed` |
| Removal of a capability | `Removed` |
| Security-relevant fix | `Security` |

Do **not** put private MainFrame project names, host paths, or personal career material here. Coordination detail lives in the outer project `log.md`. Product architecture decisions still get `DECISIONS.md` entries when boundaries change.

When finishing a session: update **Unreleased** (or cut a dated release block), then write/refresh the outer handoff under `plans/`.

---

## [Unreleased]

### Fixed

- Attention inspector card now loads recorded feeds on first appear when the
  card is already expanded (Operator default and persisted expand). Previously
  only collapse→expand and the full sheet triggered a read, so a cold start
  could show an empty “projection only” card.

### Added

- **Attention / Focus Board** as a read-only MainFrame projection in the
  Inspector (card title **Attention**, subtitle `MainFrame Focus Board ·
  read-only`) plus a full sheet from **Conduit → Attention Board…**. Ranked
  items come from session-close, eval-schedule, project-index, and optional
  `ingest-status` feeds; weekly proposal and approved focus are display-only
  overlays with no approve action. Missing feeds show an explicit “not an
  all-clear” banner. Refresh is manual (no background poller). Distinct from
  the agent-inbox reconnect counts and Doctor health.
- **Locked companion masters** bundled under `AgentSprites/masters/` (256px)
  nearest-neighbor from the pixel-sprites repo) for Claude, Codex, Shell,
  Grok, Antigravity, OpenCode, Gemini CLI, and Ollama. UI shows them as
  interim identity art when a full six-pose set is not available.
- Optional **Conversation companion bar** (toggle in Settings / Workbench View);
  click opens Session inspector only (never launches).
- **Mid-session model switch** for OpenCode (`/models` filter), Claude, Grok,
  Codex, Gemini, and Antigravity when a live runtime exists; Cursor, Aider,
  and Ollama still save for next launch with honest status copy.

### Fixed

- **Model picker catalogs** now populate for every default CLI profile:
  Codex (`debug models` JSON), Grok (`models`), Antigravity (`models`),
  Claude and Gemini documented aliases, Aider shortlist + local Ollama tags,
  plus the existing OpenCode / Cursor / Ollama discovery paths. Empty menus
  no longer claim “no catalog” when a Refresh or Settings custom ID can help.
- **Tools → Settings…** now opens Settings reliably (system scene or sheet
  fallback).
- **OpenCode mid-session model** uses `/models` + unique-suffix filter + Enter
  (not the incorrect `/model <id>` path that never switched the TUI model).
- **Conversation preserves live thinking/reasoning** that the TUI collapses
  after the final answer paints; duration-only thought chrome is still dropped.

### Added (prior)

- **Workbench Game Layer Phases 2–4 chrome:** agent-inbox summary on the rail
  (true reconnectable/active/pinned counts only), density-scaled companion
  prominence in the Conversation header and selected-row shelf, Session card
  **Next safe action** (Open Raw / Reconnect / New Task — never invented
  quests), optional customizable **Operator peek** shelf (off by default in
  Focused/Balanced, on in Operator until customized; filterable agent list),
  and optional juicy operator feedback on select/send (honors Reduce Motion;
  never animates poses or implies progress/XP).
- Workbench View menu + Settings toggles for peek, companion size, rail shelf,
  all-row sprites, juiciness, and output-active pulse.
- Pure `WorkbenchChrome` policy types in ConduitCore for companion scale, peek
  defaults, inbox attention, next-safe-action, and juiciness.
- A centralized **six-pose companion insertion seam** now defines exact
  profile signatures, canonical filenames, lifecycle cues, provenance/hash
  coverage, placeholder accessibility copy, and static Reduce Motion policy.
  Future approved skins need one catalog entry plus the approved six files and
  ledger/hash entries; no SwiftUI or layout rewrite is required.
- **Provider-neutral model selection** for every non-shell agent profile, with
  lazy catalogs from Ollama, OpenCode, and Cursor Agent plus a CLI-default
  fallback for other CLIs.
- Optional **Ollama**, **Cursor Agent**, **Gemini CLI**, and **Aider** profiles
  can be added from Settings; existing configs are not silently rewritten.
- Compact circular **Usage** and **Context** meters in the active composer.
  Usage is account-reported when available; Context is explicitly a visible
  Conversation/composer estimate.
- A draggable trailing-Inspector splitter with persisted width, keyboard and
  VoiceOver adjustment, and a reset to the responsive default.

### Changed

- Inspector tool panels are **stacked collapsible cards** (Session, Files,
  Review, Context, Usage) instead of a single segmented form. Visibility and
  expansion persist; density supplies quieter/fuller defaults until customized.
  **Conduit → Inspector Cards** toggles each card; Reset restores density
  defaults. Layout still never remounts the PTY.
- Inspector geometry now follows window width without changing saved density:
  Focused always uses a temporary trailing overlay, every mode overlays below
  1440 points, and Balanced/Operator pin a 320/336-point default panel at 1440+.
  The operator can resize it between 300 and 420 points; narrow windows clamp
  the effective width without overwriting the saved preference and preserve a
  520-point Conversation minimum. Fresh installs start with Inspector closed;
  opening moves keyboard/VoiceOver focus to its section control, closing
  restores the prior workspace responder when possible (with the Inspector
  toggle as fallback), and Escape closes it.
- Account-reported usage is now operator-initiated from Inspector › Usage or
  the usage sheet. Opening Conversation, Inspector, or the sheet no longer
  refreshes account data, and the Session tab no longer embeds account meters.
- Rail width now stays within 232–280 points across the three responsive
  classes. The Review empty state distinguishes an observed clean tree from a
  missing repository and repeats that clean is not completion evidence.
- Dedicated Claude/Codex art now requires the full profile name and executable
  to agree and the entire six-pose set to decode with provenance and manifest
  coverage. Missing or partial sets fall back atomically to an explicitly
  labelled generic companion instead of mixing identities pose by pose.
- Available companions use a neutral generic presentation rather than the
  exited pose. Selected task rows expose their selected trait and surrounding
  VoiceOver labels disclose dedicated versus placeholder art; lifecycle text
  remains authoritative.
- Task history now scans as **Pinned → Active → Recent**, with
  active/reconnectable pinned tasks first. Agent and project remain visible row
  metadata, and Reconnect remains a separate explicit action.
- The selected exact known-agent task may show its existing contextual companion
  in the rail, while the Conversation header now states observed
  attached/output/backend/Raw authority instead of ambiguous `Ready` or
  agent-intent language. Companion art remains non-interactive and redundant to
  text.
- Raw chrome and the terminal footer now distinguish a live PTY, detached buffer,
  exited buffer, and failed/blocked state. Ended and failed copy explicitly says
  that process state does not establish task completion. A recorded launch issue
  wins over the terminal lifecycle so a blocked launch cannot be mislabeled Ended.
- Conversation header state and its Follow/Raw controls remain separate
  VoiceOver elements instead of one combined action.
- The existing Inspector reveal now becomes immediate when Reduce Motion is
  enabled.
- Operator-mode diagnostics now present neutral local probe counts with an
  explicit no-auth/quota/quality boundary instead of aggregate readiness.
  History-only task names cannot inherit dedicated identity art from current
  settings when their executable signature was never recorded.
- Agent profiles persist an optional model, launch style, and context-window
  limit. Choices apply to the next process launch and never mutate a live PTY.
- The New Task sheet reserves a larger native macOS layout so the model popup
  and its provider-limit note remain visible instead of being compressed below
  the footer.
- Ollama launches use `ollama run MODEL`; common model-flag CLIs use
  `--model MODEL`.
- Gemini CLI is treated as a cloud-capable CLI whose free access depends on
  its configured authentication; Aider is treated as a provider-neutral
  local/BYOK CLI, not as a free cloud provider.

### Fixed

- The Inspector resize handle's accessibility representation now uses an AppKit
  `NSSlider` so VoiceOver and other AX clients receive a stable title
  (`Resize Inspector`), value in points, help text, and a named reset action.
  The earlier SwiftUI `Slider` representation exposed adjustable semantics but
  left `AXTitle` empty on macOS.

### Security

- Optional Claude account-usage refreshes use a noninteractive Keychain lookup.
  If macOS requires authentication, the meter fails closed instead of summoning
  SecurityAgent; Conduit never needs that credential for Conversation, Raw, or
  provider launch.

---

## [2026-08-07] — Account usage, MindGraph, workstation Conversation

Nested tip at cut: `7267d43`.

### Added

- **Account usage** for Claude (Anthropic OAuth 5h + weekly windows), Codex (`app-server` rate limits), and OpenCode (local session DB tokens/cost), with source labels and Refresh.
- **MindGraph query station** in-app: Knowledge or Projects scope, trust-labelled hits via MainFrame `bin/mindgraph`.
- **Agent usage UI**: relative meters, optional operator weekly/session budgets (Settings → Agents), Inspector **Usage** tab.
- **Slash / skills** composer menu (builtins + project/user skill discovery); Tab completes; Return runs CLI inject for agent builtins.
- **Conversation as turn document**: You + growing assistant turns, proportional prose, heading/bullet/code blocks, chrome scrub (presentation-only).
- **Seamless Conversation ↔ Raw**: PTY stays mounted; capture continues; resync/reconnect catch-up for incomplete turns.
- Collapsible right inspector; surface finish (matte/sheen); labeled **Tools** menu; sheet **Close** at top-left.
- Continue-outside-Conduit rail for reconnectable tmux sessions.

### Changed

- Conversation density metrics by Focused Flow density (tighter stream, progressive disclosure of chrome).
- Slash commands use TUI inject (not host-envelope paste) so builtins like `/cost` run.
- Denser Conversation layout; quieter provenance footers.

### Fixed

- Conversation focus ring on stream click.
- Slash selection no longer only dumps into the agent TUI input without a clear composer path (composer fill + inject on send).
- Capture no longer ends solely from switching to Raw or typing there.

### Architecture notes

- Product ADR **D-031**: Conversation is a turn document; structured adapters may feed Conversation without replacing Raw.
- Harness note: `docs/HARNESS_AND_STRUCTURED_ADAPTERS.md`.

---

## [2026-08-06] — Settings, permissions, stream rails

### Added

- Expanded Settings (General / Appearance / Agents / Conversation / Privacy / Utilities).
- Per-agent **permission modes** with CLI launch-flag mapping.
- Conversation control strip for menu replies without ending capture.
- Stream Conversation layout; agent-grouped left rail; right Inspector (Session / Files / Review / Context).

### Fixed

- Stream scrolls as one surface; right inspector always available as a column/panel.
- First-prompt Raw-derived capture hardened (`promptAnchored` cold start).

---

## [2026-08-05] — Conversation history + reading UX

### Added

- Conversation history over task sessions (append-only local JSONL).
- Follow-latest, attachment feedback, host envelope for CLI deliveries.
- Clickable/keyboard agent permission menus in Conversation.

### Fixed

- Session thread scroll vs prompt history.
- Conversation focus-ring and related presentation issues through the week.

---

## [2026-07-28] — Tier A observed usage

### Added

- Observed per-agent usage ledger (sessions, attach wall-clock, prompts, output bytes) — not vendor tokens/cost.

---

## [2026-07-27] — Focused Flow R2

### Added

- Harbor-default live palette switcher (five palettes), three density modes, inspector column, operator seats, honest receipt reveal, staging forwarder.

---

## [2026-07-21] — Conduit 0.3 baseline

### Added

- Native macOS work surface: MainFrame project navigation, real PTY via SwiftTerm, tmux-first durable sessions, composer (text/voice/attachments), context bundles, append-only work-session receipts.

---

## Links

| Doc | Role |
| --- | --- |
| `DECISIONS.md` | Product ADRs |
| `docs/QUICK_START.md` | Operator quick start |
| `docs/DAILY_DRIVER_PASS.md` | Daily-driver definition |
| Outer `../log.md` | MainFrame coordination log (private) |
| Outer `../plans/` | Finish plans and session handoffs |
