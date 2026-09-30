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

- `conduit_read_filesystem` exposes bounded directory listing, exact ordinary
  UTF-8 reads, and live path metadata through Explorer Core. Exact paths recover
  newly created files without a cached index. Missing, inaccessible, symlink,
  outside-root, binary/unsupported, oversized and concurrent-change states are
  explicit. Observation remains separate from session/runtime commands and the
  Session API write switch.

- Explorer directory and text reads now use root-anchored, no-follow file
  descriptors for every path component. Text reads consume at most the byte
  limit plus one lookahead byte; links remain leaves and special files are
  never opened as text.

- Settings now includes an explicit **Run ChatGPT tunnel with Conduit** control.
  Conduit starts and stops only the `tunnel-client` process it owns, reports a
  healthy externally started tunnel without claiming control over it, and keeps
  tunnel connectivity separate from Session API listening and write authority.
  Existing one-time profile/key provisioning through `scripts/chatgpt-tunnel`
  remains supported.

- `conduit_fleet_snapshot` provides one versioned, read-only handoff projection
  with independent task/provider cursors. It rebuilds Conduit tasks and adapter
  thread handles from existing durable stores, adds read-only OpenCode worker
  observations, and keeps writer authority, turn state, process evidence,
  lifecycle, verification, and capacity as separate stamped facts. Persisted
  runtime observations are stale after restart; unsupported providers,
  execution-slot occupancy, and acceptance remain UNKNOWN. Reading the
  snapshot creates no task, turn, input delivery, writer lease, cleanup, or
  execution-slot reservation (#53, #49).

- `conduit_observe_worker` now reconciles OpenCode's persisted latest-turn/tool
  state with a separately stamped, exact-binding Slice 6A process observation.
  It preserves persisted tool-part identity/status/timestamps, represents stale
  running state and owned residuals explicitly, and keeps unavailable
  authorities and turn-to-process correlation UNKNOWN. Observation performs no
  provider-history rewrite or process cleanup; completion remains separate
  from objective acceptance (#52, #53).

- Provider-session control is now an explicit authority transition above read-only
  discovery. Conduit may recognize one writer/controller for an existing
  provider session without creating, resuming, prompting, replacing, or
  otherwise mutating that provider session. Competing controller claims fail
  closed as `writer_collision`, preserve the exact provider session/history,
  and leave external/unrecognized writer ownership UNKNOWN. Provider-session
  writer authority remains separate from future workspace/worktree writer
  leasing (#53, #57).

- The Session API can now discover and inspect existing OpenCode sessions through
  read-only provider persistence without creating a Conduit task or acquiring
  execution capacity. Results use the provider-neutral `WorkerLineage` model:
  missing task/runtime/process/writer facts remain UNKNOWN, model identity stays
  turn-scoped, persisted incomplete turns remain ambiguous, and provider
  completion is not promoted into objective acceptance (#53).

- A versioned provider-supervision state model now keeps Conduit task/runtime
  binding, provider host, provider session/thread, provider turn, process
  lineage, writer identity, delivery, verification, and objective acceptance as
  separate facts. Unknown observations remain explicit, model identity is
  turn-scoped, provider-specific payloads retain typed namespaced JSON, and
  lifecycle preflight can describe unsupported consequences without mapping
  them to a different operation (#53).

- Conduit-managed zsh Shell runtimes now record content-free execution and
  command lifecycle events, cwd, shell PID/PGID, typed `shell_stdin` delivery,
  and independent read-only process-tree observations in the existing task
  event log. PTY quietness, provider liveness, task completion, and objective
  acceptance remain separate or UNKNOWN (#51, #53).

- `conduit_fleet_snapshot` now adds a read-only Shell correlation to an
  OpenCode provider row when an owned live process exposes an exact session
  argument and a current persistence inventory contains that identity once.
  The join does not bind the session to a Conduit task, adopt it, claim a
  writer, change capacity, or infer provider-host/turn liveness (#51, #53).

- `conduit_process_tree` now exposes a read-only, identity-bound macOS process
  observation for a live task runtime. It records launcher and descendant PIDs,
  PGIDs, parent relationships at observation time, process start identity,
  task-created versus pre-existing versus UNKNOWN ownership, observed exits,
  and residual descendants after a lifecycle stop. Parent exit alone never
  becomes a complete stop postcondition. Slice 6A does not signal residual
  descendants; cleanup remains deferred until a separate ownership-qualified
  mutation is proven (#53, #52).


- MainFrame Explorer now has a lexical file/path filter and semantic pixel glyphs
  for lifecycle roots, project/operation scopes, source, tests, docs, assets,
  configuration, generated/dependency material, scripts, common file classes,
  and symbolic links. The glyphs are presentation-only navigation landmarks and
  do not carry task, lifecycle, verification, health, priority, or Git status.

### Fixed

- Fleet keeps every provider inventory row visible but reads expensive
  turn/runtime detail only for sessions with a current exact Conduit task
  association or current Conduit writer authority. Skipped historical/external
  detail stays UNKNOWN with an inspectable reason; inventory alone does not
  grant authority (#75, discovered during #74).

- Process-tree observation no longer treats a shared/pre-existing provider host
  as task-created merely because its PID is selected as an observation root.
  Descendants inherit no task ownership from topology/start ordering unless
  the root itself has task-specific identity-bound ownership evidence (#53,
  #75, #78; discovered during PR #79 qualification).

- Codex App Server turn interruption now retains the provider's exact active
  turn ID and sends it with the thread ID. Codex 0.154.0 rejects cancellation
  without both identities; a thread ID alone is not a turn-cancel request.

- Shell-to-OpenCode correlation now requires complete process-tree coverage
  before returning `exact`. A sole observed session under partial coverage
  remains a candidate, ambiguous coverage remains ambiguous, and unavailable
  coverage returns UNKNOWN (#51, #53).

- Session API liveness no longer depends on successful MainFrame bookmark
  restoration, project scanning, or informational startup probes. The loopback
  listener starts after settings load; `/healthz` stays live while `/readyz`
  reports a typed non-ready startup state, and Session API writes fail closed
  until project/bootstrap authority is ready. Failed security-scope activation
  is checked against direct root readability before requiring reauthorization.
  The listener is also marked close-on-exec so PTY/provider child processes
  cannot inherit port 8750.


- Codex `thread/resume` active-writer collisions no longer fall through to a
  fresh replacement thread and then to PTY. The Codex adapter translates its
  native single-writer error into the provider-neutral `writer_collision`
  failure, and structured startup fails closed while preserving the exact
  provider thread/history (#48, #53).

- Explorer's default rail no longer hides non-lifecycle roots behind a collapsed
  `SYSTEM FILES` section or truncates project/operation descendants. `All Files`
  is the canonical tree, validated scope identity annotates the real directory,
  and Focus Scope is an explicit temporary view instead of a replacement tree.
- The ordinary Explore graph is now a bounded one-hop `Related` view instead of
  presenting four graph-analysis modes up front. Atlas, Pathfinder, and Radar
  remain available under Advanced, while identical visible graph topologies
  reuse layout and unchanged projected task/runtime facts no longer deliberately
  republish both Graph and Workstation.

- Structured OpenCode streaming no longer publishes an application-wide
  retention state for every live output fragment. Conversation persistence
  remains append-only and current, while the sidebar observes a narrow
  projection and rebuilds only for task metadata, operational availability, or
  query changes; live revisions remain local to the conversation surface until
  a non-live retention boundary.

- A structured session that was **restarted** after a refused resume is no
  longer reported as one that was **resumed**. Every structured client accepts a
  resume id and every one of them substitutes a new session when it does not
  take: Codex and Grok/Gemini catch the failed `thread/resume` / `session/load`
  and start a fresh one, OpenCode creates a session when its existence check
  misses, and the Claude/Antigravity `stream-json` client contacts no provider at
  start at all. The adapter then reported a healthy ready session, so a task
  could come back with its entire history missing and look identical to one that
  recovered. `conduit_session_status` now carries `thread_provenance`
  (`fresh` / `resumed` / `restarted` / `unverified`) with an authority line, and
  names the displaced thread in `superseded_thread_id`. Only `resumed` claims
  continuity; a client that never checked reports `unverified` rather than
  guessing.
- A failed recovery no longer destroys the route back to the real thread.
  `AdapterThreadStore` is keyed by task, so the replacement session's id was
  written over the stored one and a second resume attempt could not even try the
  right thread. Displaced ids are kept in `supersededThreadIDs` (bounded, ids
  only) and surface as `superseded_thread_ids`. Records written before this field
  existed still decode: the store loads the whole map with `try?`, so a required
  field would have returned an empty store and dropped every existing pointer on
  the next save.

### Changed

- The macOS bundle identity advances from 0.2.0 (2) to **0.3.0 (3)** for the
  daily-driver release-candidate line. This reconciles the bundle metadata with
  the existing Conduit 0.3 product baseline; stable promotion remains a separate
  release decision after exact-candidate installed-app qualification.

- Sessions now open into a conversation-root shell: Conversation + composer own
  the ordinary window, while Tasks and Inspector appear as temporary drawers
  unless explicitly pinned. Raw remains on the same mounted runtime, and
  transcript copy/export/log reveal plus provider-reported OpenCode activity
  stay available without restoring the previous permanent dashboard stack.

- `conduit_list_adapters` now states what `structured: false` costs an
  orchestrator: a PTY agent has no turn protocol, so its `turn.state` never
  becomes `completed` and polling one for completion waits forever. The honesty
  existed in the turn snapshot already, but it only arrived after a caller had
  created the task and begun polling — too late to pick a different agent.

- Concurrent OpenCode tasks no longer leak an `opencode serve` process each.
  `OpenCodeServeLease.acquire` is `@MainActor`, but that serialises statements
  and not `await`s: it checked the shared record, awaited a health probe,
  awaited a second probe, and only then awaited `spawn`, so simultaneous
  `conduit_create_task` calls all saw a nil record and all spawned. Only the
  last process stayed reachable, so `shutdownIfIdle` could never terminate the
  others and the finite port range lost one entry per concurrent create for the
  life of the app. Observed with three simultaneous creates leaving servers on
  ports 18752-18754 after every task had been closed. Resolves are now chained
  so the second caller finds the record the first assigned. The retain count is
  also taken only on success; incrementing before the attempt meant a failed
  spawn left it permanently above zero, so a later release could never reach
  idle.

- A failure inside an MCP write no longer raises a blocking dialog on the
  operator's Mac. The Session API and the Mac UI shared one `errorMessage`
  channel, and `RootView` presents any non-nil value as an alert, so a remote
  `conduit_reconcile_task` on a closed structured task returned its refusal to
  the caller *and* left a modal on screen that only a human at the machine
  could dismiss. Errors raised while serving a Session API call are now
  captured into the MCP result instead; where a command already reported its
  own error, the suppressed alert text is offered separately as
  `ui_error_suppressed`. Errors raised later from async work the call started
  are outside this window and still reach the operator.

- `conduit_close_session` now reports which of two different things it did.
  Detaching a durable tmux runtime and stopping a structured adapter both
  returned `closed: true` with the same authority line, so a caller could not
  tell an interruption it could undo from one it could not. The response
  carries `close_outcome` (`detached` or `stopped`) and `recoverable`, and
  `conduit_session_status` reports the same `close_outcome` for a live task
  before the call is made, while not closing is still an option.

- `conduit_create_task` can now start an agent on an objective in one call.
  A structured runtime is still starting when the create response is
  serialized, so the objective was refused outright and reported
  `objective_delivery_state: failed` with instructions to send it again — on
  every structured backend, in every recorded canary run. Conduit now holds
  the objective and delivers it when the runtime reports ready, reporting
  `queued`, which already means Conduit owns delivery and the caller must not
  resend. A held prompt is visible as `prompts_held_pending_ready` on
  `conduit_session_status`, and always reaches a recorded outcome on its
  prompt event: delivered, refused by the host, or abandoned if the runtime
  never becomes ready within two minutes, stops first, or is removed — every
  path that makes a runtime unreachable now resolves what it still owed,
  rather than leaving the prompt `queued` for a caller that was told not to
  resend. `conduit_send_prompt` holds on the same terms. PTY delivery is
  unchanged.

- A structured turn that died inside the provider is no longer reported as a
  completed turn. `conduit_session_events` gains `turn.state: failed` and
  `observation.checkpoint: structured_failed`, derived from the adapter's own
  `.failed` signal rather than inferred from status text. Previously any
  non-nil turn status was mapped to `completed`, so a provider error and a
  finished turn were indistinguishable to a caller. `conduit_close_session`
  now also states that a structured adapter is stopped and its task is not
  recoverable afterwards, where a durable tmux runtime is only detached.
  The failure is scoped to the turn it ended: interrupting a turn that already
  finished makes the provider report an error, and that no longer un-completes
  the finished turn, nor does a failed turn leave every later turn on the same
  task reading as failed.

- `conduit_create_task` no longer causes an initial objective to run twice on a
  PTY runtime. A PTY host accepts the objective and writes to the terminal
  after the response is serialized, while a structured host that is still
  starting refuses it outright; both used to be reported as a bare
  `objective_delivered: false`, and the tool description told callers to resend
  in that case. The response now reports `objective_delivery_state`
  (`delivered`, `queued`, `failed`, `not_attempted`) alongside
  `objective_resend_required`, and every `create_task` return path that could
  carry an objective reports one — including the provisioning-failure and
  reload-failure paths. `objective_delivered` keeps its existing meaning, so
  current consumers are unaffected.

### Security

- The loopback Session API now keeps its bearer-token file owner-only (`0600`),
  repairs an existing regular token file to that mode, and accepts only one
  exact Bearer credential. It rejects malformed, ambiguous, oversized, and
  incomplete HTTP framing; applies a two-second read deadline; and bounds
  concurrently stalled connections rather than letting one block the listener.
  Session API write authorization and lifecycle semantics are unchanged.

### Changed

- Orchestrate can now explicitly prepare a proposal for the configured
  MainFrame root as well as a scanned project. This remains proposal-only;
  worker launch is still disabled.
- Local Ollama planner requests now ask Ollama to unload Conduit's Qwen model
  immediately after a response. Conduit does not stop or reconfigure the
  shared Ollama service or other loaded models.

### Added

- A first-class **Explore** workspace now provides a lazy, read-only MainFrame
  file tree, bounded Quick Open, source viewing, and navigation. Project and
  operation labels use validated lifecycle authority, and Explorer performs no
  file mutation.

- A top-level **Orchestrate** workspace now separates task planning from a
  worker's Conversation/Raw surfaces. It sends an explicit request only to a
  fixed loopback Ollama planner with no tool interface, carries
  scope/citation-labelled context packet and typed proposal contracts, rejects
  unsafe or multi-worker proposals, and keeps task start disabled pending a
  separate explicit handoff (D-046).
- `conduit_session_events` now carries a durable `interrupt_request` marker
  when Conduit issues `conduit_interrupt`. The marker says only that the local
  request was issued; it does not turn acknowledgement into provider-observed
  cancellation or completion, and it is distinct from the existing text-cap
  `truncated` flag (D-044).
- `conduit_query_mindgraph` separates sources a caller must not cite from the
  ones it may (D-043). Every result now carries a `citation_class`, documents
  that are quarantined, retracted, superseded, or flagged as a fabricated
  citation come back under `not_citable` rather than mixed into `results`, and
  `citation_counts` reports the split. Retrieval ranking is trust-blind — on two
  live queries a quarantined document from the 2026-08-09 fabricated-citations
  incident was the **highest-scoring hit**, carrying only a prose warning that
  the caller had to read and choose to obey. Nothing is dropped or re-ranked.

### Fixed

- A structured adapter no longer reports the operator's own prompt, the model's
  private reasoning, or a turn's output more than once as the agent's answer
  (D-042). Driven from an external orchestrator seat, a one-word OpenCode turn
  returned `"Say PONG only.PONGPONG"` three times over, and a one-word Gemini
  turn returned its own thinking ahead of the answer. Four faults stacked:
  `message.updated` was discarded as a foreign session because a message id was
  read as a session id, so message roles were never learned and the prompt was
  accumulated as output; the snapshot and delta channels were both appended,
  doubling every token; completion is announced three times per turn and each
  announcement appended another finished copy; and ACP's `agent_thought_chunk`
  matched a `contains("agent")` test. Answer-bearing streams are now named in an
  allowlist, text is tracked per part so a snapshot replaces and a delta
  extends, and a turn closes once.
- `conduit_create_task` no longer claims that `objective` is delivered when the
  runtime becomes ready. Delivery is attempted once, at create, and a runtime
  that is still starting reports `objective_delivered: false` — which is what it
  always did. Nothing is queued for later delivery, because every Session API
  write is one explicit call. The tool description now says so.

### Changed

- The Session API now publishes a stable eleven-action MCP catalog even while
  local writes are disabled. Discovery is not authorization: every lifecycle
  call is still rejected before dispatch unless the operator enables Session
  API writes locally. This prevents snapshotting clients from permanently
  missing `conduit_create_task` after a later, explicitly approved write gate
  change (D-045).
- The Session API tool catalog now lives in ConduitCore and has durable unit
  coverage. The loopback server remains responsible for dispatch and write
  admission, while tests now pin the read/write gate, required arguments,
  interruption wording, and the distinct text-truncation contract (D-044).
- Every Session API tool parameter now carries a description. Nine were empty,
  including every required argument of all five write tools, so a caller reading
  `tools/list` could not tell whether `agent` wanted a profile name or a command,
  or where a `taskSessionID` comes from. All 28 tool and parameter fields are now
  described, at a cost of 11.6 KB for the full 11-tool listing.

### Added

- Session API writes now pass a bounded admission boundary before they reach a
  runtime (D-041). Creates take a capacity reservation, prompts take a bounded
  queue slot, and every write consumes a per-caller rate budget. Refusals are
  structured: `code`, `detail`, and where relevant `retry_after_seconds` and the
  resource violations that opened the circuit. Shipped limits are four live
  tasks, six creates per caller per minute, thirty writes per caller per minute,
  and a prompt queue of four per task. The live-task ceiling is the wall; the
  create rate sits above it so a legitimate burst meets capacity rather than a
  rate limit, and only churn hits the rate limiter.
- `conduit_create_task` accepts an optional `idempotency_key`. An identical
  repeat returns the original task instead of starting a second one. The same
  key against a different request is refused rather than silently reused.
- Gemini CLI prefers ACP (`gemini --acp`) when a Gemini API key is present.
  Consumer Code Assist oauth stays ineligible; PTY remains the fallback.
  Do not run Gemini CLI and Antigravity as two Google workers on one task.
- Grok, OpenCode, Claude, Antigravity, and Gemini CLI now prefer first-party
  structured hosts (D-040): ACP stdio, one leased `opencode serve` (HTTP +
  SSE), and `stream-json` print mode. Conversation is fed by labelled adapter
  events. PTY remains the explicit fallback if the host fails. Gemini models
  remain an OpenCode backend as well as a Gemini CLI ACP host.
- Session API `conduit_list_adapters` lists enabled profiles and their
  declared backends. Create/send/interrupt/close use the structured host
  when the profile prefers one.
- `conduit_session_events` now includes an additive supervisory observation
  snapshot. Clients receive provider thread identity plus
  `thread_id_source` (`live` | `persisted` | `unavailable`),
  `runtime_attempt_id` when known, `observed_at` and last-output/checkpoint
  state, `provider_progress` (`structured` | `unavailable`), and input state
  that distinguishes structured `approval` from PTY `unknown`. PTY
  checkpoints remain observational (`output_live`, `output_quiet`,
  `output_unobserved`, `capture_closed`) and never mean turn completion.
  Existing event identity and cursor semantics are unchanged.
- ChatGPT and other Session API clients can now page incremental Conversation
  events through `conduit_session_events`. The tool is read-only, cursor-bounded,
  and returns authority/source labels, truncation/redaction state, artifact path
  refs without file contents, and a turn snapshot that stays distinct from
  session lifecycle. Codex app-server can report structured turn completion and
  complete bounded assistant messages; PTY output stays explicitly ambiguous.
- Codex tasks now prefer a long-lived `codex app-server` session (D-038).
  Conversation grows from structured adapter events (`toolReported`) instead
  of only scraping the TUI. Approvals surface as a Conduit alert. If
  app-server fails to start, Conduit falls back to the existing PTY path.
- Codex Reconnect starts app-server (and `thread/resume` when a thread id was
  stored) instead of requiring a tmux PTY.
- Raw can attach `codex --remote` to the same unix socket when app-server
  exposes one.
- Optional loopback Session API (`127.0.0.1:8750/mcp`, Settings toggle, bearer
  token). Read tools list projects/sessions and proxy MindGraph. Optional
  write toggle exposes `conduit_create_task`, `conduit_send_prompt`,
  `conduit_interrupt`, and `conduit_close_session`. Approvals stay on the Mac.
  Bind is IPv4 localhost. HTTP responses use a correct CRLF terminator.
- Settings can copy the Session API token and shows a stored ChatGPT tunnel
  id. `scripts/chatgpt-tunnel` writes the local `tunnel-client` profile.

### Changed

- Codex app-server now starts over stdio by default. The unix-proxy path hung
  on initialize and added a six-second Ended flicker; set `CONDUIT_CODEX_UNIX=1`
  only when debugging Raw `--remote`.
- Launch-or-Reconnect for Codex reconnects the latest matching task instead of
  minting a new thread. New Task / New Session For still create a new task.
- Codex app-server sends no longer get the PTY `<<CONDUIT_HOST` envelope.

### Fixed

- `conduit_list_sessions` no longer hides part of the task inventory. It
  returned the first 40 tasks with no total, no cursor, and no ordering
  guarantee, so a caller could not tell a truncated list from a complete one and
  the tasks it dropped were whichever identifiers sorted late. It now orders by
  last activity, newest first, and returns `total`, `returned`, `has_more`,
  `next_cursor`, and `cursor_state`, with `cursor` and `limit` arguments
  (default 40, cap 200) that reuse the `conduit_session_events` convention.
- `conduit_session_status` returns the conversation events it advertises. It
  read only live in-memory state or a warm cache, so after a restart every task
  reported an empty history; it now falls back to the durable log the way
  `conduit_session_events` already did.
- `conduit_query_mindgraph` returns parsed results instead of raw CLI stdout.
  The payload was the query process's stdout with a progress log glued to the
  front of the JSON, and its `status` field was the process exit code under a
  name that reads like a result status. Results are now structured, the exit
  code is `exit_code`, and an empty question is rejected instead of running a
  full embedding query.
- Tool descriptions state what each tool returns and where a `taskSessionID`
  comes from. They ranged from ninety words to six, and nothing said how to
  obtain the identifier every task tool requires.
- The sprite integrity manifest now covers every bundled image. Since the
  structured-adapter pass the app has shipped and rendered eight per-identity
  companion masters that `SHA256SUMS` did not list, so that art could drift
  without anything noticing. All twenty bundled PNGs are now pinned, the
  provenance ledger records the `masters/` import, and the bundle contract test
  models both asset classes instead of assuming every image belongs to a
  six-pose set. Masters still never satisfy the six-pose completeness gate.
- The XCTest target compiles again. A recorder test read its own recorder from
  inside the closure passed to that recorder's initializer, which had broken the
  whole suite; the running total is now kept in a separate lock-guarded counter.
- The ChatGPT tunnel launcher now stores the control-plane key instead of
  reading it only from the environment. It previously resolved the key as
  `env:CONTROL_PLANE_API_KEY`, so the key lived solely in whichever shell
  exported it and vanished with that terminal, leaving a working tunnel looking
  un-set-up on the next session. The launcher now prefers
  `file:~/.conduit/control-plane-api-key` (owner-read-only, beside the Session
  API bearer), captures an exported key into that file on first run, and falls
  back to the environment when no file exists.
- `conduit_send_prompt` no longer reports `delivered: true` for a PTY write that
  has not happened yet. The terminal write completes after the MCP response is
  serialized and can still fail, so the tool now returns `delivered: false` with
  `delivery: "queued"` and points the caller at `conduit_session_events` for the
  recorded delivery state. The durable prompt event was already truthful; only
  the immediate tool result was optimistic.
- Restart reconciliation no longer records a previously-open task as
  interrupted when complete tmux discovery still contains that task's exact
  durable binding. Malformed bindings continue to suppress negative inference,
  and project/agent compatibility remains an explicit reconnect gate.
- `conduit_reconcile_task` now reports an accepted asynchronous reconcile when
  a compatible discovered runtime can be resumed after local history loads,
  instead of returning a false immediate error while recovery proceeds.
- MCP discovery now labels `conduit_reconcile_task` as state-changing but
  non-destructive, matching its same-ID, no-kill, no-replace recovery contract.
- MCP discovery now labels `conduit_send_prompt` as an additive message write,
  while retaining the explicit boundary that delivery grants no agent approval.
- MCP tool discovery now advertises standard risk annotations: Conduit's local
  read-only queries are marked read-only and closed-world, while lifecycle
  controls remain conservatively state-changing/destructive.
- Session API now returns the standard absent-metadata response for OAuth
  protected-resource discovery, allowing no-auth tunnel-client readiness checks
  to distinguish it from malformed metadata.
- MCP task creation now reports explicit provisioning failure and recovery
  state instead of marking an absent runtime ready. Reconciliation retries the
  same durable task and preserves uncertain tmux sessions.
- Session API dropped HTTP bodies (bad header terminator / Network.framework).
- Session API now reads the complete declared HTTP body, so fragmented MCP
  discovery requests no longer fail with HTTP 400.
- JSON `1` was parsed as `true`, so MCP request ids became booleans.
- Codex `thread/resume` with no rollout now falls back to `thread/start`.
- Unix `app-server` + `proxy` handshake timeout now falls back to stdio
  instead of leaving the session Ended.
- Adapter re-host can recover a controller that was marked exited during
  that fallback.
- Conversation no longer prepends `[userMessage]` / other chat-chrome item
  tags to Codex adapter output.
- Reconnect of an existing Codex task no longer stops after loading history;
  it continues automatically once the JSONL is in memory.
- Prompt origin can now record ChatGPT or phone as well as the composer
  (D-039).

### Security

- `conduit_query_mindgraph` no longer forwards absolute host paths. Each result
  carried `source_root`, a full filesystem path on the operator's machine, to
  whatever external client asked. Results are now projected through an
  allowlist, so retrieval mechanics stay local and a future path-bearing field
  cannot leak by default. Weak-fit and provenance warnings are deliberately kept.
- Session API writes fail closed when the caller cannot be identified. A
  listener that has not seen an MCP `initialize` refuses every write with
  `caller_identity_required` instead of executing it anonymously.
- The resource circuit breaker evaluates only metrics Conduit genuinely samples
  and refuses a write when a required metric is unknown, stale, or over its
  limit. Unmeasured metrics are declared unmeasured rather than reported as zero.

### Changed

- Account usage Refresh prefers a live Codex app-server when one is ready.
- Declining `item/permissions/requestApproval` sends a JSON-RPC error instead
  of an empty grant.

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
