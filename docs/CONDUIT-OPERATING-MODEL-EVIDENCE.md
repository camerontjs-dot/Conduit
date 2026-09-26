# Conduit Operating-Model Evidence Record

**Record date:** 2026-09-26 · **Repository:** [`camerontjs-dot/Conduit`](https://github.com/camerontjs-dot/Conduit)

**Verified [main](https://github.com/camerontjs-dot/Conduit/tree/main) at [commit `ce2ea202c734ec4533b43fc72967e110b049ea3e`](https://github.com/camerontjs-dot/Conduit/commit/ce2ea202c734ec4533b43fc72967e110b049ea3e)** · **Tree:** `f55ea8813e7d7af44f24b91af955a3ceff395c23`
**Record type:** point-in-time evidence synthesis; not an implementation contract, release decision, or live-status authority.

This record explains what field reports, merged qualification slices, and preserved candidate receipts establish about Conduit's operating boundaries. GitHub source and exact qualification receipts remain authoritative. Issue proposals are design evidence, not proof that a capability exists. The live plan and its ordering remain in the linked issues; this record does not mirror their changing status.

Repository identities and PR states below are dated snapshots. Check the linked GitHub surfaces before relying on present state.

The record deliberately does not repeat operator task/session IDs, process IDs, machine paths, or private project/corpus names from linked material. Follow receipt links when those details are needed for a bounded reproduction.

## 1. Scope, evidence labels, and authority boundary

**OBSERVED — high confidence:** Live `main` matched the exact commit/tree above on 2026-09-26. This is the same commit/tree used to start this record; PR #80 produced it. The base docs tree did not contain a consolidated operating-model evidence record.

Use these labels throughout:

| Label | Meaning |
|---|---|
| **OBSERVED** | Directly present in the identified source, GitHub snapshot, or qualification receipt. |
| **FIELD REPORT** | An operator-reported observation from actual use; useful evidence, but not a controlled qualification. |
| **SOURCE CLAIM** | A proposal or conclusion stated in an issue/PR. It does not become an implemented capability merely by being written there. |
| **INFERENCE** | A synthesis from cited observations. Confidence is stated where the inference matters. |
| **HYPOTHESIS** | A plausible explanation that still needs a discriminating test. |
| **UNKNOWN** | The available evidence cannot establish the value. It is not equivalent to false, unsupported, or safe. |

Qualification dispositions and GitHub lifecycle states are separate from those epistemic labels. `PASS` applies only to its named candidate and acceptance boundary; `FAIL` and `FAIL_OR_INCONCLUSIVE` remain results; `Draft`, `merged`, and `closed` describe PR lifecycle, not technical truth. The provider matrix also distinguishes `supported`, `unsupported`, `unavailable`, and `unknown` per interface and evidence layer.

**Boundary:** this is a point-in-time evidence synthesis. It does not authorize runtime changes, candidate advancement, merging, promotion, or release. Live issue status, sequencing, and acceptance ownership stay in [#4](https://github.com/camerontjs-dot/Conduit/issues/4), [#53](https://github.com/camerontjs-dot/Conduit/issues/53), [#56](https://github.com/camerontjs-dot/Conduit/issues/56), [#57](https://github.com/camerontjs-dot/Conduit/issues/57), [#58](https://github.com/camerontjs-dot/Conduit/issues/58), and [#60](https://github.com/camerontjs-dot/Conduit/issues/60). Add a dated entry here only when direct evidence changes or challenges an interpretation; do not copy changing issue or PR status into this record.

## 2. Operating model: a supervisory control plane over native runtimes

**SOURCE CLAIM — product direction:** Conduit should supervise independent provider CLIs through the richest practical structured interface, with Shell/PTTY retained as a fallback and for local operations. Conduit should not impersonate provider APIs or flatten provider behavior into a false common lifecycle. This direction is stated in [issue #49](https://github.com/camerontjs-dot/Conduit/issues/49); it is not a claim that every adapter already has equivalent fleet or lifecycle support.

The useful model is a chain of related, non-identical objects:

```text
operator / supervisor
  → Conduit task and supervisory binding
  → runtime attempt and launcher/host
  → provider session or thread
  → provider turn and tool/process activity
  → workspace (project, repository, worktree, candidate)
  → terminal receipt and independent acceptance
```

The underlying **runtime/transport** and the **model/provider selected inside it** are separate dimensions. For example, OpenCode can be the runtime while a different model is selected for a turn. A session-level model label may not describe every turn in that session. [The Fleet lane records this distinction](https://github.com/camerontjs-dot/Conduit/issues/49#issuecomment-5750073421); [the field-use pressure test observed different model labels within one OpenCode session](https://github.com/camerontjs-dot/Conduit/issues/52#issuecomment-5751745138).

### Boundaries in the active reliability plan

These issues assign work and evidence boundaries in the same supervisory path. Their bodies remain the live design and sequencing authority; this table explains why those boundaries must compose. Ownership is not evidence that a planned capability is implemented.

| Lane | Evidence or decision it owns | Why the boundary matters |
|---|---|---|
| [#53 provider/runtime](https://github.com/camerontjs-dot/Conduit/issues/53) | Task/runtime/provider/turn identity, typed delivery, provider lifecycle, process ownership, provider-versus-OS reconciliation, and explicit `UNKNOWN` states. | A delivered command or observed process does not establish provider-turn state or task acceptance. |
| [#57 workspace](https://github.com/camerontjs-dot/Conduit/issues/57) | Writable workspace identity, isolation, leases, drift, and recovery. | Correct provider identity does not prove the worker has the intended repository or safe write scope. |
| [#58 context](https://github.com/camerontjs-dot/Conduit/issues/58) | Context provenance and manifest identity. Retrieval nominates context; it does not grant runtime authority or prove what a worker received. | Routing and later review need the exact context handoff, not a reconstructed or silently changed bundle. |
| [#4 control plane](https://github.com/camerontjs-dot/Conduit/issues/4) | Canonical supervisory state and event history, idempotency, restart/recovery, and reconciliation-safe projections. | A supervisor needs one durable account that preserves disagreement among provider, process, and presentation views. |
| [#56 orchestration](https://github.com/camerontjs-dot/Conduit/issues/56) | Deterministic route and launch decisions consuming qualified state. | Routing can reject, defer, or reroute on stale or unknown facts; it must not manufacture them. |
| [#60 implementation train](https://github.com/camerontjs-dot/Conduit/issues/60) | Dependency ordering and system-level convergence across those owner lanes. | Sequencing coordinates the work but does not replace any lane's evidence or acceptance authority. |

The 2026-09-26 convergence is recorded in the latest [#4](https://github.com/camerontjs-dot/Conduit/issues/4#issuecomment-5843421082), [#53](https://github.com/camerontjs-dot/Conduit/issues/53#issuecomment-5843421229), and [#56](https://github.com/camerontjs-dot/Conduit/issues/56#issuecomment-5843421381) comments and the [#60 reliability-spine section](https://github.com/camerontjs-dot/Conduit/issues/60). Those are live planning surfaces, not receipts that the proposed end-to-end behavior has passed.

**INFERENCE — high confidence:** Conduit’s durable value is the supervisory relationship and its evidence trail, not ownership of the provider’s identity or semantics. The control plane is only useful when it reports the limits of that relationship: what Conduit created, what it merely discovered, what it can observe, what it can mutate, and what remains unknown.

## 3. Identity and state are separate dimensions

| Object | What it identifies | What it does not establish |
|---|---|---|
| Conduit task | Conduit’s durable task/control record | Provider existence, current execution, or objective success |
| Runtime attempt / launcher | One attempted launch and its process entry point | Provider session identity or complete descendant ownership |
| Provider host | A server or app-server process serving provider work | A single task; one host may be shared across tasks or predate them |
| Provider session/thread | Durable provider conversation identity | A currently active turn, a Conduit writer, or task acceptance |
| Provider turn | A bounded unit of provider/model/tool work where exposed | A completed objective or successful repository change |
| Conduit binding / writer authority | Conduit’s supervisory or mutation relationship to a provider session | Authority over the provider’s external writers or a workspace/worktree |
| Process tree | OS-observed processes, topology, liveness, and identity evidence | Provider-session state or permission to signal/clean descendants |
| Workspace identity | Project/repository/worktree/candidate scope | Provider-session identity or an automatic right to write there |
| Objective acceptance | A terminal receipt plus the required independent check | Something inferred from provider prose, a quiet PTY, process exit, or turn completion |

The field-use notes express a practical four-step check: (1) task/objective exists or was delivered, (2) provider identity is established, (3) worker execution is observed, and (4) the objective is accepted after a terminal receipt and independent verification. Each step needs its own evidence. See [#52 field notes](https://github.com/camerontjs-dot/Conduit/issues/52#issuecomment-5750150319).

**OBSERVED:** PR #67 added a read-only process-tree observation/reconciliation model with explicit ownership, freshness, coverage, and postcondition. It did not add descendant cleanup. Its qualified orphan case showed a launcher can exit while an owned child remains alive; that result was recorded as an incomplete residual, not successful cleanup ([PR #67 receipt](https://github.com/camerontjs-dot/Conduit/pull/67#issuecomment-5783374861)).

## 4. Authority: observation, ownership, and scope

Authority must be named per operation, not inferred from visibility.

| Authority surface | Current evidence-backed rule |
|---|---|
| GitHub repository state | GitHub is authoritative for the repository, branch, commit, PR, and merge state. A local checkout or handoff is not a substitute for a live check. |
| Provider observation | A read-only inventory row can establish visibility only to the extent its source, freshness, and coverage allow. It does not grant adoption or write authority. |
| Provider-session writer | Explicit adoption is the authority transition. PR #62 qualified one recognized Conduit writer per provider session, idempotent same-controller claims, and a fail-closed `writer_collision`; collision did not create a replacement session or fall back to PTY. Its registry was process-local, so cross-restart writer ownership was not established ([receipt](https://github.com/camerontjs-dot/Conduit/pull/62#issuecomment-5769476179)). |
| Process ownership | A process selected as an observation root is not thereby task-created. Ownership requires task-specific, identity-bound evidence. |
| Workspace/worktree writer | Separate from provider-session writer authority. PR #62 did not implement workspace leasing; [#57](https://github.com/camerontjs-dot/Conduit/issues/57) owns that boundary. One lease does not imply the other. |
| Objective acceptance | External to provider lifecycle. A provider result can be evidence for a task, but does not accept it. |

PR #80 repaired the process-root boundary on `main`: a shared or pre-existing provider-host PID can remain observable while its ownership stays `UNKNOWN`; descendants do not inherit task ownership from topology or start ordering unless the root already has task-specific ownership evidence. Direct task-created PTY/Shell launcher paths retain their explicit evidence. See [PR #80](https://github.com/camerontjs-dot/Conduit/pull/80), its [qualification receipt](https://github.com/camerontjs-dot/Conduit/pull/80#issuecomment-5834907210), head `17d5cfc2207209311e0ba7253a69831be2cf584c`, branch `fix/shared-provider-host-ownership-20260925`, merged as `ce2ea202c734ec4533b43fc72967e110b049ea3e`.

**INFERENCE — high confidence:** the same session can be observable to multiple readers while mutation remains single-writer. The same process can be visible without belonging to the task. The same provider identity can survive while Conduit’s authority or observation freshness does not. Those distinctions are architectural boundaries, not display details.

## 5. Lifecycle operations are not synonyms

The qualified lifecycle model separates:

- discover / observe;
- adopt / connect / resume by exact identity;
- start a turn, send or queue input, and respond to approval;
- abort a turn;
- release Conduit supervision;
- stop a provider host/runtime;
- archive or delete provider history.

**OBSERVED:** PR #63 qualified a non-mutating lifecycle preflight and explicit lifecycle operations on its exact candidate (`feature/lifecycle-preflight-operations`, head `0ef9d5db35cd836fab96761a83b16aec8743d1d5`, tree `6600d232e4fddcadd0b0798cac0c47e532179bf1`; receipt [#63 comment 5781150281](https://github.com/camerontjs-dot/Conduit/pull/63#issuecomment-5781150281)). It distinguished Codex turn abort from app-server stop, tmux detach from direct-PTY stop, and OpenCode release from stopping its final shared-host lease. It did not claim provider-history deletion, descendant cleanup, or objective acceptance.

That pass followed preserved failures: an early PTY receipt claimed runtime end while the process was still alive; a later stop request left the direct PTY alive and capacity occupied; another candidate could not classify a missing tmux socket. These failures were corrected in successors, not erased ([PR #63 history](https://github.com/camerontjs-dot/Conduit/pull/63)).

**FIELD REPORT:** an operator expected a structured OpenCode close to release supervision while preserving a recoverable worker; the observed operation instead reported the host stopped and the task non-recoverable. Shell/tmux detach behaved differently. This is a report of a lifecycle mismatch, not a universal claim about all OpenCode closes ([#52](https://github.com/camerontjs-dot/Conduit/issues/52#issuecomment-5750150319)).

**UNKNOWN:** active-turn continuation after releasing supervision was not established for OpenCode, Codex, or Grok in the Slice 10 probes. The operation’s name, a preserved session ID, or an idle provider host cannot fill that gap.

## 6. Provider differences are part of the contract

The versioned [provider-conformance matrix](https://github.com/camerontjs-dot/Conduit/blob/ce2ea202c734ec4533b43fc72967e110b049ea3e/docs/qualification/provider-conformance-v1.json) covers seven runtimes and thirteen capabilities. It records provider-native outcomes separately from Conduit adapter outcomes and preserves `supported`, `unsupported`, `unavailable`, and `unknown` instead of treating absence of evidence as failure or support. The exact Slice 10 lineage and disposition are in [#53](https://github.com/camerontjs-dot/Conduit/issues/53#issuecomment-5817464070).

| Runtime / transport | Directly observed difference | Boundary that remains |
|---|---|---|
| OpenCode HTTP/SSE | Session status reports busy/idle without a stable turn ID in the tested interface. The bounded cancel qualification records accepted abort, `busy → idle`, and `session.idle`. | No explicit terminal cancellation reason or exact turn ID in that receipt. Active-turn continuation after supervision release remains unknown. |
| Codex App Server | Thread and turn have distinct exact IDs. Codex 0.154.0 rejected `turn/interrupt` without `turnId`; the repaired path retained and sent both IDs. | Interrupting a turn is not stopping the host; structured supervision release is not a proven detach path. |
| Grok ACP | Cancellation was reported at session level (`stopReason=cancelled`) without a stable turn ID. Exact session load after host restart was observed. | Session-level cancellation is not a provider turn ID. The initial harness false-negative—requiring an echoed session ID after a successful exact load—was preserved and corrected. |
| Shell / PTY | OS process and tmux behavior can be observed; `tmux detach-client` left the command running in the bounded probe. | PTY bytes, quiet output, or process-group visibility are not provider-native turn semantics or general descendant-cleanup proof. Direct PTY stop differs from tmux detach. |
| Claude structured CLI | The Sep 23 inventory observed Claude Code 2.1.235 logged out, so no provider operation was attempted. | `unavailable` for that probe is not a claim that Claude lacks the capability. |
| Gemini CLI ACP | The Sep 23 probe initialized ACP only; it did not authenticate or create a provider session/turn. | Initialize success does not qualify session lifecycle. |
| Antigravity structured CLI | The Sep 23 probe did not establish safe auth/session readiness. | Capability and readiness remain `unknown`, not unsupported. |

The installed versions and complete capability states are time-bound to the matrix and its receipts. Do not promote them into a permanent vendor ranking or universal interoperability claim. The lane’s routing order is a preference, not a hard prohibition ([#49 fleet scope](https://github.com/camerontjs-dot/Conduit/issues/49#issuecomment-5750073421)).

## 7. Evidence chain: delivery is not execution, and execution is not acceptance

**OBSERVED:** Conduit has durable task/session events, runtime-attempt identity, provider-thread provenance, typed delivery kinds, and explicit task/runtime fields. Those records help reconstruct what was attempted; they do not themselves establish provider execution or objective success. The repository’s [agent contract](https://github.com/camerontjs-dot/Conduit/blob/ce2ea202c734ec4533b43fc72967e110b049ea3e/AGENTS.md) explicitly warns that deterministic core tests do not exercise the whole installed Session API, adapters, and PTY path.

Keep these evidence layers distinct:

1. **Delivery:** which transport received what typed message and content digest (`shell_stdin`, `agent_prompt`, or `structured_message`). Text sent to a PTY is shell input unless an actual agent surface receives it.
2. **Provider/runtime observation:** exact session/thread and turn state when the provider exposes them; otherwise preserve the actual weaker status and its freshness.
3. **Process observation:** PID identity, liveness, parentage, coverage, and ownership basis. Process disappearance is not provider-session inactivity.
4. **Terminal work evidence:** changed files, tests, commits, or another task-specific receipt.
5. **Independent acceptance:** the verifier or supervisor’s check against the objective. This is not inferred from provider prose, a completed turn, a closed capture, a stopped host, or a quiet PTY.

The #52 field report described direct provider turns that returned progress text and then ended without completing the requested objective. The operator still needed a terminal receipt and independent GitHub verification. That is why “turn complete” and “objective accepted” remain different facts ([#52](https://github.com/camerontjs-dot/Conduit/issues/52#issuecomment-5750150319)).

## 8. Field-use friction and supervision UI

**FIELD REPORT — actual use, not synthetic qualification:** the operator manually reconstructed a chain from apparatus/repository through Conduit task, Shell launcher, runtime, provider/model, branch/candidate, and receipt. Conduit exposed useful anchors—task UUIDs, delivery events, provider IDs where present—but not the complete lineage in one read-only view. Detached Shell launchers preserved capacity while making child progress harder to observe; `output_unobserved` and `output_quiet` did not establish completion. Discovering sessions without resuming or disturbing them was manual. See [#52 comment 5750150319](https://github.com/camerontjs-dot/Conduit/issues/52#issuecomment-5750150319) and the [bounded pressure test](https://github.com/camerontjs-dot/Conduit/issues/52#issuecomment-5751745138).

The pressure test also found boundaries that a fleet view must not hide: Conduit did not observe an external continuation of the same OpenCode session; separate controllers could interleave writes; interrupt scope did not cover every process using the same session ID; a provider parent exited while a tool child survived; and persisted provider state still said `running` after the observed process had ended. These are bounded test observations, not a claim every provider behaves this way.

**SOURCE CLAIM — UX proposals, not assumed implementation:** issue #49 records needs for deterministic sorting/filtering, visible conversation recency distinct from administrative edits, message timestamps, unseen output, a multi-thread working set, explicit current target/scope, and clear visual distinction between task state, provider state, unread state, and operator priority. Relevant notes: [task ordering and title chrome](https://github.com/camerontjs-dot/Conduit/issues/49#issuecomment-5754268327), [thread recognition and recency](https://github.com/camerontjs-dot/Conduit/issues/49#issuecomment-5764135598), [timestamps and multi-thread working set](https://github.com/camerontjs-dot/Conduit/issues/49#issuecomment-5770146575), and [operator priority semantics](https://github.com/camerontjs-dot/Conduit/issues/49#issuecomment-5781069225). These notes are evidence of friction and proposed acceptance criteria; they are not proof all proposed UI exists.

## 9. Merged boundaries and what each pass actually established

| PR | Exact qualified identity and merge result | Bounded evidence established |
|---|---|---|
| [#62](https://github.com/camerontjs-dot/Conduit/pull/62) | `feature/provider-session-authority` at `dd135f508c393ba3ee813287112ab1bbeb783074`, tree `d212f64c26585aae26cfc14e4134f4ca994e08dc`; merged as `add184048c850cdd01119213a08a0d0780e2adcd`. Receipt: [5769476179](https://github.com/camerontjs-dot/Conduit/pull/62#issuecomment-5769476179). | Explicit provider-session adoption and single recognized Conduit writer; read-only observation did not claim ownership. Registry was process-local. |
| [#63](https://github.com/camerontjs-dot/Conduit/pull/63) | `feature/lifecycle-preflight-operations` at `0ef9d5db35cd836fab96761a83b16aec8743d1d5`, tree `6600d232e4fddcadd0b0798cac0c47e532179bf1`; merged as `bdbba961238d7ca1851818c5ee474794ce2703de`. Receipt: [5781150281](https://github.com/camerontjs-dot/Conduit/pull/63#issuecomment-5781150281). | Non-mutating preflight and provider-specific abort/release/stop distinctions for qualified OpenCode, Codex, tmux, and direct-PTY cases. |
| [#67](https://github.com/camerontjs-dot/Conduit/pull/67) | `feature/process-tree-reconciliation-20260922` at `97177e8e09d12dfd4635a789dfe709323bc9e407`, tree `09ca703b7b2122ff1d01fcce97c561b6147ccb58`; merged as `2a2356d4291384b311ef111f6c2ec61a29a6424f`. Receipt: [5783374861](https://github.com/camerontjs-dot/Conduit/pull/67#issuecomment-5783374861). | Read-only process-tree ownership and post-lifecycle reconciliation, including incomplete residuals. No descendant signaling or cleanup path. |
| [#70](https://github.com/camerontjs-dot/Conduit/pull/70) | `codex/slice9-shell-provider-telemetry-20260923` at `571b1aaf30e25ed00e823fd57079bd5468a9fa68`, tree `cabf1c73731a7777a205ed10b685cefc6d5ece9a`; merged as `06efd2b4029c1d13c7a16cbc7e92b38bcb89a7e4`. | Narrow Shell → OpenCode process/session correlation. The predecessor’s independent FAIL (partial/ambiguous/unavailable process coverage could be classified exact) remains preserved; only the corrected successor PASS is current ([#70 lineage](https://github.com/camerontjs-dot/Conduit/issues/53#issuecomment-5798586369)). |
| [#73](https://github.com/camerontjs-dot/Conduit/pull/73) | `codex/slice10-provider-conformance-lead-20260923` at `cf5c14791014fa9031b8008dc296b9270748eb69`, tree `13578c325163b6e37bee0069513adca4d7395ec5`; merged as `2096f07c5366e427515f2a6f34aac93eccc2d6a7`. | Versioned seven-runtime/thirteen-capability matrix and bounded provider probes. A predecessor overclaim about OpenCode cancellation was corrected; its predecessor FAIL remains discoverable ([terminal #53 receipt](https://github.com/camerontjs-dot/Conduit/issues/53#issuecomment-5817464070)). |
| [#80](https://github.com/camerontjs-dot/Conduit/pull/80) | `fix/shared-provider-host-ownership-20260925` at `17d5cfc2207209311e0ba7253a69831be2cf584c`; merged as current `main` `ce2ea202c734ec4533b43fc72967e110b049ea3e`, tree `f55ea8813e7d7af44f24b91af955a3ceff395c23`. | An observation root no longer grants task-created ownership to a shared/pre-existing provider host or its descendants without task-specific root evidence. |

These are separate, bounded passes. Their merge history does not amount to end-to-end qualification of every runtime, lifecycle operation, queue behavior, or objective-acceptance path.

## 10. Preserved qualification results and evidence limits

This section preserves bounded results tied to exact candidate identities. PR lifecycle labels are snapshots checked on 2026-09-26; live PR state belongs to GitHub. The implementation order and next gates remain in [#53](https://github.com/camerontjs-dot/Conduit/issues/53) and [#60](https://github.com/camerontjs-dot/Conduit/issues/60).

### Slice 11 concurrency result

At the 2026-09-26 check, PR #74 was **closed and unmerged**. Its exact candidate was branch `research-infra/slice11-concurrency-qualification-20260924`, head `22c8761ca355e22df50666703c54d4c46f0508d1`, tree `ca6c0a58b10bd2daeaff9dbb4928881689e397f8`, based on `main@2096f07c5366e427515f2a6f34aac93eccc2d6a7`. The terminal receipt is [PR #74 comment 5826117332](https://github.com/camerontjs-dot/Conduit/pull/74#issuecomment-5826117332).

**OBSERVED:** the bounded tier-4 rerun created 4/4 tasks but observed no more than 3 of 4 exact provider sessions active simultaneously. Natural completion and its post-completion window were not reached. Post-close provider inactivity remained `UNKNOWN`; cleanup was not reconciled. Phase C, 6/8 runs, and the [issue #44](https://github.com/camerontjs-dot/Conduit/issues/44) assessment did not happen. During that run, the shipped task limit remained 4; see [#53](https://github.com/camerontjs-dot/Conduit/issues/53) for live policy. The receipt does not establish a hard concurrency ceiling or identify the scheduler layer.

The candidate’s qualification reader initially failed to preserve camelCase success-path and top-level error/reconciliation data. A candidate successor fixed parsing and added regressions; the corrected reader was exercised in the tier-4 rerun. Because #74 is closed and unmerged, that apparatus repair must not be described as merged `main` behavior. The original incomplete result remains part of the record.

### Fleet-detail qualification lineage

PR #79’s frozen candidate `b0848fda07fa88662b59d9aa467c1198d7f96f7f`, tree `935e3e3193d75bba84217d3b8e1f93941053028e`, first had an `INCONCLUSIVE` result because no live positive-authority row was present, then a `FAIL_FOR_FLEET_DETAIL_SCALING_REPAIR`: a pre-existing shared OpenCode host was misclassified as `task_created`. The failure is preserved in [#53 comment 5832570204](https://github.com/camerontjs-dot/Conduit/issues/53#issuecomment-5832570204) and its linked [PR #79 receipt](https://github.com/camerontjs-dot/Conduit/pull/79#issuecomment-5832556067). PR #80 repaired the ownership prerequisite.

PR #81 re-extracted and qualified the Fleet-detail change on repaired main. Branch `fix/fleet-provider-detail-issue75-20260925-successor`, head `273a7318c20547e269ffa0e2fdc7fc45dfc31f7f`, tree `3da3333d46a12d84fcc65a31deac0e1af67614ca`, base `ce2ea202c734ec4533b43fc72967e110b049ea3e`. Its bounded disposition is `PASS_FOR_FLEET_DETAIL_SCALING_REPAIR` ([qualification receipt](https://github.com/camerontjs-dot/Conduit/pull/81#issuecomment-5836775249)); at the 2026-09-26 check, PR #81 was open, Draft, and unmerged. The pass covered current exact-task detail, inventory-only rows remaining visible with detail `UNKNOWN`, bounded paging, and process-ownership sanity. It makes no concurrency claim. Hosted [run 36168363264](https://github.com/camerontjs-dot/Conduit/actions/runs/36168363264) executed zero steps due the billing/spending-limit runner-start block; this is not candidate execution evidence.

### Active-turn queueing

PR #82 has exact candidate head `c90172d3f46437c356274f79976b5074e5ef0d7e`, tree `7bd68ac8bcb18ffc9ebda29638996bb690e3c3ae`, based on `main@ce2ea202c734ec4533b43fc72967e110b049ea3e`. Deterministic gates passed, and teardown, terminal-next, PTY non-change, authority separation, and negative controls were qualified. The key active-turn queueing case remained blocked because the available structured backends were unhealthy in that run; steering remained `UNKNOWN`. No `PASS_FOR_SLICE4_TYPED_DELIVERY_AND_ACTIVE_TURN_SEMANTICS` disposition was claimed ([#77 receipt](https://github.com/camerontjs-dot/Conduit/issues/77#issuecomment-5837554759); [#53 receipt](https://github.com/camerontjs-dot/Conduit/issues/53#issuecomment-5837555907)). At the 2026-09-26 check, PR #82 was open, Draft, and unmerged.

### Hosted CI is not candidate execution

Several hosted macOS runs, including #73, #74, and #81, failed before job steps because GitHub did not assign a runner; some annotations identify billing/spending limits. A zero-step run is infrastructure evidence, not a code failure and not a successful test/build. Local tests, build/signing, live provider qualification, and hosted CI are separate evidence rows. Do not call CI green where it did not execute.

## 11. Why isn’t Conduit reliable yet?

**OBSERVED:** the merged work qualifies useful, narrow boundaries: writer authority, lifecycle preflight, process-tree observation, provider/runtime reconciliation, Fleet snapshots, Shell correlation, provider conformance, and the shared-host ownership correction. The preserved #74 result is `FAIL_OR_INCONCLUSIVE`; #81 passes only its Fleet-detail scaling boundary; #82's live active-turn case is blocked by backend health. The reviewed issues and receipts do not show one complete supervisory loop that survives restart and reconciliation.

**INFERENCE — moderate confidence:** the evidence points to a cross-boundary reliability gap rather than a simple lack of provider features. Conduit has useful components, but the receipts do not yet show a supervisor re-entering from durable, reconciled state with enough identity and authority to continue safely through verification and acceptance. This does not mean every ordinary session fails.

**HYPOTHESIS — moderate confidence, strengthened by this reconciliation:** Conduit lacks a sufficiently demonstrated reliability spine between “an instruction reached a provider” and “a supervisor can safely continue from durable, reconciled execution truth.” Candidate pieces are:

1. one versioned, reconciliation-safe supervisory event authority;
2. restart-safe identity and recovery;
3. idempotent create and send semantics after lost responses;
4. typed supervisory evidence where providers expose it, including approvals, tool activity, artifacts, errors, lifecycle, verification, and acceptance;
5. clear separation among durable history, provider state, OS/process observation, and presentation projections;
6. exact repository, build, and runtime identity for qualification receipts;
7. a demonstrated positive and negative supervisory loop.

This remains a hypothesis about demonstrated cross-lane behavior, not an established claim that these components are absent. The merged slices are counterevidence to a “no useful primitives exist” explanation. Provider-specific behavior and backend health are credible alternative causes for some individual failures; the tests in §12 distinguish those from failures of restart, event authority, retry safety, or projection reconciliation.

| Diagnostic class | Evidence and consequence |
|---|---|
| **Identity and authority boundaries** | The #79 failure treated a shared provider-host observation root as task ownership; #80 repaired that case. Provider-session writer authority remains distinct from workspace/worktree leasing in [#57](https://github.com/camerontjs-dot/Conduit/issues/57). A visible provider or process is not automatically owned by a task. |
| **Durable history, restart, and retry** | The latest [#4 reliability comment](https://github.com/camerontjs-dot/Conduit/issues/4#issuecomment-5843421082) makes canonical events, recovery, and lost-response idempotency explicit. Existing task/event primitives do not by themselves show identity and cursor continuity or duplicate-free create/send across restart. |
| **Provider/runtime disagreement** | Provider persistence can remain `running` after process exit; an exited parent can leave a child; partial process coverage cannot prove cleanup. [#53](https://github.com/camerontjs-dot/Conduit/issues/53) owns provider/runtime semantics; [#80](https://github.com/camerontjs-dot/Conduit/pull/80) prevents topology alone from granting process ownership. Disagreement must survive into read models as disagreement or `UNKNOWN`. |
| **Workspace and context provenance** | [#57](https://github.com/camerontjs-dot/Conduit/issues/57) owns writable workspace identity and leasing; [#58](https://github.com/camerontjs-dot/Conduit/issues/58) owns context provenance and manifest identity. Neither a provider session nor a retrieval nomination establishes which repository or context was actually handed to a worker. |
| **Routing and launch authority** | [#56's reliability refinement](https://github.com/camerontjs-dot/Conduit/issues/56#issuecomment-5843421381) says live route, launch, reuse, and acceptance must consume a versioned snapshot from authoritative events. Deterministic schemas can precede that feed; live decisions cannot fill missing runtime, workspace, writer, or context facts. |
| **Qualification defects and attribution** | The #74 reader initially dropped camelCase reconciliation fields; the #70 predecessor accepted partial process coverage; the #73 OpenCode cancellation wording exceeded its terminal evidence; and the first Grok harness rejected an exact successful load because it expected an echoed ID. Each changed what the evaluator could conclude. Exact candidate/build/runtime identity remains necessary to know which object a receipt qualifies. |
| **Concurrency and backend health** | Four task creates did not yield four simultaneously observed active provider sessions in #74; that run does not locate the scheduler or establish a permanent cap. #82's active-turn case was blocked by unhealthy backends and steering remained `UNKNOWN`. Hosted zero-step CI is infrastructure evidence, not candidate execution. |
| **Supervision still costs operator attention** | Field use required a manual cross-system lineage map; detached output, external sessions, close semantics, and recency/scope made it harder to know what changed and which action was safe. The UI proposals in #49 are evidence of friction, not proof that it has been removed. |

## 12. Discriminating tests and record update rules

These are **proposed discriminators**. This documentation reconciliation did not run them, and the record does not claim that any has passed. The live owners and dependency order remain in [#4](https://github.com/camerontjs-dot/Conduit/issues/4), [#53](https://github.com/camerontjs-dot/Conduit/issues/53), [#56](https://github.com/camerontjs-dot/Conduit/issues/56), [#57](https://github.com/camerontjs-dot/Conduit/issues/57), [#58](https://github.com/camerontjs-dot/Conduit/issues/58), and [#60](https://github.com/camerontjs-dot/Conduit/issues/60).

### Reliability-spine discriminators

| Boundary | Discriminating test | What the result distinguishes |
|---|---|---|
| Restart-safe identity | Create a qualification-owned task, record the exact task → runtime attempt → provider session/thread → provider turn chain, restart/relaunch Conduit, and reconnect. | Whether recovery resumes the same identity chain or creates/adopts a different runtime. Missing identity evidence remains `UNKNOWN`; a UI reopen alone is not recovery. |
| Event and cursor continuity | Read the supervisory event stream to a cursor, restart/relaunch, then continue from that cursor while checking sequence, event identity, and payload continuity. | Whether durable history is continuous and duplicate/gap handling is explicit, rather than reset or silently reconstructed from a projection. |
| Lost-response create retry | Simulate a response loss after create is durably accepted, then retry with the same idempotency key. Inspect task identity, objective delivery attempts, and provider-side effects. | Whether retry returns the same task and avoids duplicate initial delivery, or whether create acknowledgement and delivery are conflated. |
| Lost-response send retry | Simulate a response loss after a send is accepted or delivered, then retry the same command with the same idempotency key. Inspect provider turn identity and delivery receipts. | Whether one requested send creates one provider-side effect, with queued, delivered, active, terminal, and ambiguous outcomes kept distinct. |
| Provider/runtime disagreement | Construct a case where provider-persisted state and OS/process observation disagree, then read Fleet, task status, and other presentation projections. | Whether the disagreement stays explicit as a conflict or `UNKNOWN`, or a projection silently normalizes it into success, stopped, or live. |
| Typed evidence across restart | Where the provider exposes them, record and recover approval request/resolution, tool-call/result boundaries, artifacts, errors, lifecycle events, and verification/acceptance records. | Whether supported evidence survives restart with source and identity, while unavailable or unsupported types remain labelled instead of being fabricated or dropped. |
| Route and launch revalidation | Have #56 consume a versioned event/state snapshot and retain the RouteDecision and policy version, task/runtime/provider/turn identity, writer authority, [#57 workspace identity](https://github.com/camerontjs-dot/Conduit/issues/57), [#58 context-manifest identity](https://github.com/camerontjs-dot/Conduit/issues/58), cursor, and launch receipt. Change or stale one required fact before launch. | Whether launch fails or reroutes explicitly on stale or `UNKNOWN` state. A retrieval nomination, Fleet row, or UI projection must not fill the missing authority. |
| Complete supervisory loop | Exercise one bounded journey: `create/recover → deliver → observe → follow-up → inspect evidence → verify → accept/reject → reconcile/close`, crossing at least one restart/reconciliation boundary. | Whether one supervisor can continue from durable evidence through independent verification and explicit acceptance or rejection without collapsing provider completion into objective completion. |
| Negative or ambiguous journey | Keep one journey unresolved: for example, provider completion without external verification, provider/runtime disagreement, a process exit with incomplete provider evidence, quiet PTY output, or capture close. Restart and reconcile it. | Whether the outcome remains non-successful, ambiguous, or `UNKNOWN` rather than becoming accepted through silence, process exit, or projection cleanup. |
| Qualification identity | For every receipt used to support the conclusion, verify repository commit and tree, clean/dirty state, built-app or executable identity, runtime/provider version, protocol/input identity, and receipt linkage. | Whether the evidence belongs to the exact committed candidate being discussed. A locally repaired or dirty build can diagnose a problem but cannot qualify a different committed object. |

### Provider and capacity diagnostics

These narrower checks help locate a failure. Passing one does not close the full supervisory loop.

| Question | Discriminating test | What the result would and would not mean |
|---|---|---|
| Where does fourth-turn delay arise? | Hold workload and timing constant. Compare Conduit → OpenCode, direct OpenCode without Conduit scheduling, and a separately supported provider/model. Preserve timestamps for create, delivery, provider message, tool start, active observation, completion, and cleanup. See [#76](https://github.com/camerontjs-dot/Conduit/issues/76). | Helps separate provider/model behavior from Conduit scheduling for that workload. It does not prove a universal limit. The #74 maximum of three observed active sessions is not a hard-cap result. |
| Does an active-turn queue preserve order? | On one healthy structured provider, keep turn A active; submit B then C. Observe provider-native terminal evidence, queue order, delivery digest, and one dequeue per terminal event. Test steering separately only where explicitly supported. See [#77](https://github.com/camerontjs-dot/Conduit/issues/77). | Separates queueing from steering and concurrent sends. Backend-health failure is `BLOCKED`, not a pass or product failure. |
| Does lifecycle close match its postcondition? | Capture preflight and post-state for the same session/thread, active turn, host, task binding, and process evidence. Include shared/final OpenCode leases, Codex abort versus host stop, tmux detach, and direct PTY stop. | Distinguishes turn cancellation, host termination, supervision release, process exit, resumability, and history retention. Unknown postconditions remain unknown. |
| Can process evidence establish ownership or cleanup authority? | Re-run #80's shared/pre-existing root, task-created launcher, reparented child, PID reuse, partial-coverage, and unrelated-process cases. Keep descendant cleanup as a separate gate under [#78](https://github.com/camerontjs-dot/Conduit/issues/78). | Separates topology and liveness from task ownership. Unknown ownership must not create a destructive cleanup target. |
| Does Fleet detail preserve its bounded authority? | Use #81's exact-task positive row and inventory-only negative rows; page all rows and verify each appears once. Repeat with stale/released associations and a shared host. | Tests Fleet-detail routing and stale-authority exclusion. The #81 pass does not establish concurrency capacity or universal provider liveness. |
| Does another controller collide safely? | Use one isolated provider session; first controller adopts, second attempts control, then repeat around Conduit restart. Verify exact identity/history, no replacement session or prompt, and explicit `UNKNOWN` where the process-local registry cannot prove prior ownership. | Rechecks the bounded #62 single-writer property and exposes the unqualified restart boundary without touching operator sessions. |

### Record update rule

Add a dated entry only when direct evidence changes or challenges an interpretation. Include the exact repository/candidate identity where relevant, the primary receipt link, evidence class and protocol, provider/build identity when material, preserved failures, and specific non-claims. Keep OBSERVED, INFERENCE, HYPOTHESIS, and UNKNOWN distinct. Do not copy live issue order, PR status, or mutable next actions into this record; link to the owner issues instead. Never overwrite a failed or inconclusive receipt or treat a successor result as evidence for its predecessor.

### Reconciliation snapshot — 2026-09-26

- **OBSERVED:** GitHub `main` is `ce2ea202c734ec4533b43fc72967e110b049ea3e` with tree `f55ea8813e7d7af44f24b91af955a3ceff395c23`, the same identity as this record's source basis. [PR #80](https://github.com/camerontjs-dot/Conduit/pull/80) is the ownership-boundary change that produced it.
- **OBSERVED:** the latest reviewed comments on [#4](https://github.com/camerontjs-dot/Conduit/issues/4#issuecomment-5843421082), [#53](https://github.com/camerontjs-dot/Conduit/issues/53#issuecomment-5843421229), and [#56](https://github.com/camerontjs-dot/Conduit/issues/56#issuecomment-5843421381), together with [#60](https://github.com/camerontjs-dot/Conduit/issues/60), converge on the reliability-spine boundary described in §§2 and 11. These planning updates are not test receipts.
- **OBSERVED:** the reviewed qualification snapshots retain #74's `FAIL_OR_INCONCLUSIVE`, #81's narrow Fleet-detail pass, and #82's blocked active-turn case; see §10 and the linked receipts. They do not establish the complete tests in this section.
- **INFERENCE:** this convergence strengthens the reliability-spine hypothesis as a useful explanation of the evidence gap, while the merged provider/runtime primitives weaken any claim that the problem is simply an absence of provider features.
- **UNKNOWN:** the reviewed GitHub issues and receipts do not establish restart-safe event/cursor continuity, duplicate-free create/send after lost responses, complete supported-event preservation, projection behavior under provider/runtime disagreement, or one positive and one negative end-to-end supervisory journey. This is scoped to the linked surfaces checked for this reconciliation, not proof that no unlinked local observation exists.
