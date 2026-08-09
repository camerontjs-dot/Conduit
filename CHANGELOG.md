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

### Added

- **Provider-neutral model selection** for every non-shell agent profile, with
  lazy catalogs from Ollama, OpenCode, and Cursor Agent plus a CLI-default
  fallback for other CLIs.
- Optional **Ollama**, **Cursor Agent**, **Gemini CLI**, and **Aider** profiles
  can be added from Settings; existing configs are not silently rewritten.
- Compact circular **Usage** and **Context** meters in the active composer.
  Usage is account-reported when available; Context is explicitly a visible
  Conversation/composer estimate.

### Changed

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
