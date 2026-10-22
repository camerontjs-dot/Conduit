# T3 Code adoption plan for Conduit and MainFrame

Prepared 20 October 2026; finalized 21 October 2026 after local review (America/Toronto).

**Status: finalized plan with linked implementation.** Every area below has a disposition recorded in [§0](#0-finalized-decisions-21-october-2026). Retained implementation is in separate Draft PRs: the revision feed in [#184](https://github.com/camerontjs-dot/Conduit/pull/184) and the first in-process service slice in [#185](https://github.com/camerontjs-dot/Conduit/pull/185). This planning change itself still contains no product implementation and establishes no runtime qualification.

Primary coordination remains [Conduit #60](https://github.com/camerontjs-dot/Conduit/issues/60). The owner issues below retain their authority. This document is a bounded adoption proposal and source-review record, not a second live project dashboard.

Local execution entry point: [review, finalize and implement](t3code-local-agent.md).

## 0. Finalized decisions (21 October 2026)

Local review used live GitHub, an owned worktree at maintained main `10a8d03852b1589a98f212d317c26463cda93c76` and the reader receipts listed in the PRs. Main had not moved since this plan was drafted. The operator's installed app was identified (`/Applications/Conduit.app` 0.3.0 build 3, executable SHA-256 `d90de0bb2e1afa49000fce6e97421136e1e1f1c53a291d0e3efcd94f6e4f23cc`, the qualified PR #102 baseline, with a live loopback listener) and was not launched, replaced or called.

| Area | Disposition | Gap observed in live source | Existing work reused | Acceptance and evidence | Dependency or next action |
| --- | --- | --- | --- | --- | --- |
| 1. Request acceptance, effects, truthful completion | **Reuse existing; no new mechanism here** | Main has only an in-memory create ledger. A durable keyed replay journal exists only in Drafts #177 → #178 → #180; output truth fixes in #179 → #181 → #182. UNKNOWN intents have no resolution path, so a new key can duplicate accepted work. OpenCode delta identity stays unresolved. | #175 → #177 → #178 → #180 and #179 → #181 → #182, all rooted at #177 head `64d6b7c`. Heads `a4b6562` (#180) and `828498a` (#182) are macOS-CI green. Independent verdicts: #175 FAIL, #177 FAIL twice, #178 FAIL, #180 BLOCKED for behavior, #179 FAIL (repaired in #181), #182 PASS_BOUNDED_SOURCE. | The integration candidate must show: lost ACK returns the stored receipt; a conflicting key is refused; a crash after intent and before outcome reports UNKNOWN and never redispatches; a failed settlement write reports UNKNOWN; a refusal before any effect reports `not_dispatched`; an application error inside a 2xx response is a failure; a stale runtime callback cannot close or label its replacement; provider completion is not verification. | `git merge-tree` of `a4b6562` and `828498a` conflicts only in CHANGELOG, DECISIONS (both stacks add D-063/D-064) and the provider-conformance pins; AppModel and the self-test auto-merge. The #60 owner builds the reviewed integration candidate named in [checkpoint 6281289361](https://github.com/camerontjs-dot/Conduit/issues/60#issuecomment-6281289361), choosing the decision numbering, then runs macOS CI and the separately authorized two-client acceptance. |
| 2. Revision-aware reads, snapshots, coverage | **Implemented (bounded)** in [#184](https://github.com/camerontjs-dot/Conduit/pull/184) | The `v1:<index>` cursor is a presentation position, so a revision of an earlier event never reached a reader past it. A missing log read exactly like an empty one. Text past the 2,000-character export cap was unrecoverable, and `truncated` did not say why. mainframe-live #86 separately found the default page projection lossy. | Append-only `ConversationEventLog`, the `ThreadRecognition` source-state vocabulary, and #147's idea of binding a cursor to a source prefix (not its code: #147 projects task metadata logs, is DIRTY against main and remains separate). | Opt-in `changes_since` revision cursor bound to the exact log prefix; named refusals for truncation, rewrite, a foreign log and mid-line offsets; coverage `complete/partial/empty/missing/unreadable`; `timeline_source`; `text_capped` versus `source_truncated`; exact Character-offset expansion with a digest; text whose redaction has not settled within its eight-pass bound is withheld. Current head, checks, mutation results and CI identity: [#184 receipt](https://github.com/camerontjs-dot/Conduit/pull/184#issuecomment-6326889225). | Installed-app, hosted-client and mounted checks NOT_RUN. The v1 cursor keeps its meaning and the page changes only additively: every record gains `text_capped` and `source_truncated`, capped records gain `full_text_sha256` and `text_continuation_offset`, the page gains `timeline_source`, and `changes` and `expansion` appear only when requested. |
| 3. Portable source-bound handoffs | **Defer (implementation gap)** | [#58](https://github.com/camerontjs-dot/Conduit/issues/58) already names task history and prior agent outputs as Context Set sources, so including task conversation needs no new operator approval. The gap is a missing producer: no app path adds task conversation to a handoff bundle, and the `.agentOutput`/`.task` kinds and `.taskHistory` authority have none. Handoffs go to the pasteboard, so Conduit can only know "prepared". | Context primitives on main (`ContextSet`, `ContextManifest`, `expanding()`, `AgentContextHandoffRenderer`); exact-source drafts #140 → #148 → #150. [#184](https://github.com/camerontjs-dot/Conduit/pull/184) already gives hosted consumers event identity, revision sequence, coverage and exact expansion. | When a producer exists: a manifest naming the source task and revision cursor, included revisions, omitted identities, expansion references and byte budgets, re-validated against a fresh read; delivery `prepared/delivered/unknown` with no reinjection after an uncertain send. | Next is ordinary #58 implementation: a producer that attaches conversation items through the existing source identities (#140 → #148 → #150), not a parallel path. Injecting a handoff into a runtime, rather than preparing it, also needs the #177-stack delivery truth. |
| 4. Coherent task view | **Defer** | The distinctions the view needs are partly new (`timeline_source`, coverage from [#184](https://github.com/camerontjs-dot/Conduit/pull/184)) and partly in unmerged drafts (journal states). | Conversation, Raw, Inspector and context surfaces; `ConversationRetentionState`. | Plan §5 distinctions in the native journey, with owned mounted evidence. | Mounted lanes stay paused under the frozen #168 → #123 → #128 order, and #168 owns the mounted Conversation viewport this would change. Start after the #168 disposition. |
| 5. UI-independent service boundary | **Implemented (first in-process slice)** in [#185](https://github.com/camerontjs-dot/Conduit/pull/185) | The `conduit_session_events` read was assembled inside `AppModel`; its D-077 ordering rule had no AppKit-free test. | Issue #4 Phase B. Execution, lifecycle and admission are left in `AppModel` while #175 to #182 rework them. | `ConduitSessionReadService` runs without AppKit behind a read-only owner interface; a write racing the read is re-delivered, and reading the timeline first fails the test. Responses unchanged. Current head and checks: [#185 receipt](https://github.com/camerontjs-dot/Conduit/pull/185#issuecomment-6326893184). | Process packaging is not chosen. GUI-restart survival is the #4 Phase C experiment. Admission and delivery move after the journal integration lands. |
| 6. Provider capabilities and caller authority | **Reuse existing; reject a runtime registry now** | `conduit_list_adapters` reports declared surfaces only. The versioned provider-conformance matrix is evidence bound to versions observed on 23 September. | `provider-conformance-v1` (explicit unknown, unavailable and unsupported states); PTY turns stay ambiguous; caller authority in #146, #178 and #170. | Clients negotiate [#184](https://github.com/camerontjs-dot/Conduit/pull/184) by presence: an older server ignores the new arguments and omits `changes`, which a client treats as unsupported. | Publishing the matrix at runtime would present old observations as current without a re-probe, and a probe must not launch sessions. Revisit when the Session API adds steering, rollback or approval-option features. |
| 7. Change review, checkpoints, restoration | **Defer read-only review; reject restoration now** | `GitWorkspaceInspector` gives snapshot, diff, history and blame, but no task-scoped base identity, so observed changes cannot be scoped to a task or separated from concurrent edits. | #120 `ExecutionWorkspace` (exact base SHA, one-writer lease), READY_FOR_FRESH_INDEPENDENT_WORKSPACE_FOUNDATION_QUALIFICATION. | Read-only "changes since task base, observed and not attributed" once a qualified base identity exists. | Restoration has no demonstrated need and would require lease ownership, matching identity and separate authorization. |
| 8. MainFrame consumer and research | **No consumer now** | mainframe-live #72, #86, #114, later issues and Conduit #58 request no Conduit resume or handoff consumer; #72 and ADR-077 rule out a duplicate history store. | Direct file and Git workflows. | Not applicable. | [#184](https://github.com/camerontjs-dot/Conduit/pull/184)'s coverage and revision cursor are a candidate source contract for a future #86 successor, which keeps its own admission: #114 is not qualified and actor cells remain 0. |

Upstream currency, checked 21 October: T3 Code `main` is `688ee52f0e8fcc6c0789f82d8145441b6663e7eb`, 101 commits after the pinned review commit, which is still its ancestor. Thirteen of the fifteen referenced paths are byte-identical, including every cursor, replay and handoff source. `threadRequests.ts` now declines approvals on send, and one replay regression test was removed from `threads-sync.test.ts`; neither changes what this plan adopted. Orchestrator delegate, stop and completion semantics changed in a file this plan does not reference and did not adopt.

## 1. Outcome and decision

Improve Conduit's existing execution, observation and continuation loop using the useful contracts inspected in T3 Code. A user or supervising client should be able to identify the request, recover its known state after a disconnect, inspect what changed, understand missing evidence, and continue through an appropriately bounded handoff.

MainFrame should consume exact Conduit references through its existing orientation, governing-source and handoff routes. Native repositories, applicable instructions and accepted decisions continue to determine current project authority.

The adoption decision is selective. For each area, local review must choose **reuse existing**, **implement a bounded change**, **defer with a concrete dependency**, or **reject with a reason**. Finding that existing behavior satisfies the acceptance conditions is a useful outcome. The plan does not require another implementation merely to resemble T3.

The seven areas are:

1. Durable request acceptance, delivery and completion semantics.
2. Revision-aware replay, snapshot recovery and explicit source coverage.
3. Portable handoffs with source identity, omissions and expansion.
4. A coherent task view for status, approvals, changes, context and verification.
5. A UI-independent execution-service boundary and client compatibility.
6. Explicit provider capabilities and caller authority.
7. Workspace change review and, where justified, constrained restoration.

Cross-cutting work includes focused failure tests, isolated development state, provenance and an optional MainFrame consumer. MainFrame history-benefit research remains a separate decision.

## 2. Authority, work classes and protected behavior

### Current task authority

The owner requested a new planning PR and a local-agent prompt to review, finalize and implement this work. The local implementation agent is authorized to inspect, revise the proposal, write source and tests, make ordinary repairs, update documentation and create or update scoped implementation PRs. Routine transitions between those activities do not need another approval.

This explicitly permits local source implementation. Older generic instructions that allocate local agents only to qualification do not negate this task-specific instruction. A frozen qualification run still needs its exact candidate preserved; repairs produce a new identified candidate and new evidence.

This planning PR is documentation/maintenance. Its implementation successors will normally be standard engineering or reversible product exploration. A claim that optional history improves model continuation is research and follows its own admitted apparatus.

### Preserve these boundaries

- MainFrame's native files and repositories remain project authority. Conduit operational stores and read projections must not become a shadow project registry.
- Keep Conduit's native interface, independent provider tools and real PTY access where required. A T3 reference does not select a replacement framework.
- Keep task, runtime attempt, provider thread, turn, prompt, event/item and caller identities distinct where they have different meanings.
- Keep acceptance, dispatch observation, provider completion, follow-up processing, agent claims and work verification distinct.
- A possibly executed request must recover its prior outcome or report explicit uncertainty. A reconnect does not authorize a fresh execution.
- A local event sequence identifies local observations. It cannot invent a missing native provider sequence or prove that identical upstream payloads are duplicates.
- Preserve required source/revision evidence separately from an efficient current-state projection.
- Native request options and permission meanings must survive provider normalization. Displaying a pending approval does not grant authority to answer it.
- Historical content is evidence/context. It cannot silently supersede current governing sources or replay foreign tool calls.
- Existing installation, release, integration HOLD and frozen-qualification decisions remain in their owner records until legitimately superseded. Do not infer their removal from this plan.
- Current client capabilities must be inspected. Historical MCP entitlement prose is not a current product-policy lookup.

Source implementation, source review, independent qualification, merge, installation and release are separate states. The local agent should advance every eligible source and test lane while keeping blocked machine or experimental actions explicit.

## 3. Source-review record

These are inspected historical identities, not instructions to assume that the same objects remain current at execution time.

| Object | Reviewed identity | What the review establishes |
| --- | --- | --- |
| Conduit maintained source | `10a8d03852b1589a98f212d317c26463cda93c76` | Starting implementation and repository conventions. Not the installed application's identity. |
| T3 Code reference source | `8cd561ef6f8d09e22b50429982acaf1e9b896086` | Inspected contracts, implementation and test sources. No T3 application or tests were executed for this review. |
| MainFrame maintained source | `873ac4fcfe8a292fdd52d3a24c3d23a57e9d4059` | Starting lifecycle/authority reference; mutable research state belongs to its owner issues. |

Material observations:

| Observation | Source | Consequence for adoption |
| --- | --- | --- |
| Conduit's exported cursor follows presentation positions; revisions retain an item's original position. | [Conduit event export][C1] | A consumer must not treat that cursor as a complete revision stream. Investigate an additive change-feed contract. |
| Conduit already retains append-only revisions, while `read()` exposes latest valid projected values; an absent log returns empty events without diagnostics. | [Conduit log reader][C2] | Improve source accessibility and coverage before introducing storage. Distinguish unavailable/missing from valid empty state. |
| T3 commits command receipt, events, projections and pending effects together, then publishes. | [EventSink][T1] | Compare the atomic acceptance boundary with the existing Conduit journal. |
| T3 separates logical item identity from event sequence and supports bounded replay or snapshot recovery. | [ThreadStream][T2], [event store][T3] | Adapt explicit cursor scope, snapshot watermark and catch-up semantics. |
| T3 compacts some intermediate message/node updates while preserving current-state reconstruction. | [ProjectionMaintenance][T4] | Projection convergence is a narrower claim than historical evidence preservation. Do not copy compaction indiscriminately. |
| T3's provider handoff binds source/target/run coverage, selects intact items, records omissions and supplies expansion pointers. | [ContextHandoffService][T5], [handoffBudget][T6] | Reuse the contract ideas through Conduit's existing Context Compiler. |
| T3 distinguishes connection health, data synchronization, cached state and request resumability. | [connection runtime][T7], [pending requests][T8] | Improve the task view without presenting cached or unanswerable state as live. |
| T3 puts provider differences and permission ceilings at explicit boundaries. | [provider constraints][T9], [MCP access][T10] | Compare capabilities and authority checks with existing Conduit adapters. |
| T3 separates provider completion from workspace finalization and constrains restoration. | [architecture][T11], [restore safety][T12] | Start with reviewable changes; treat restoration as a separate consequential action. |

The source review found a promising implementation reference, not evidence of superior performance, measured token savings, a complete audit trail, exactly-once external effects or improved MainFrame continuation.

T3 handoff budgeting includes serialized byte accounting; it must not be reported as measured model-token use. Its portable provider handoff is not complete provider-native state transfer. Attachments, live approvals and native tool/reasoning state have separate boundaries. Where internals prose and code differ, record the inspected path and prefer the behavior supported by source and execution evidence.

## 4. Reuse map and dependencies

Refresh each relevant owner's latest body, comments, heads and checks before selecting a base. Links are navigation, not permission to combine candidate branches.

| Area | Existing owner and starting work | Reuse/dependency rule |
| --- | --- | --- |
| Overall sequencing | [#60](https://github.com/camerontjs-dot/Conduit/issues/60), [#4](https://github.com/camerontjs-dot/Conduit/issues/4) | Add retained work to existing lanes; keep implementation receipts in the relevant PRs. |
| Replay and runtime observations | [#53](https://github.com/camerontjs-dot/Conduit/issues/53), [global stream #147](https://github.com/camerontjs-dot/Conduit/pull/147) | Inspect the existing derived global projection and per-task source authority before adding another stream or store. Reuse current revision/unseen-output identity where suitable. |
| Request journal and direct operations | [#175](https://github.com/camerontjs-dot/Conduit/pull/175) → [#177](https://github.com/camerontjs-dot/Conduit/pull/177) → [#178](https://github.com/camerontjs-dot/Conduit/pull/178) → [#180](https://github.com/camerontjs-dot/Conduit/pull/180); [#51](https://github.com/camerontjs-dot/Conduit/issues/51), [#170](https://github.com/camerontjs-dot/Conduit/issues/170) | Reconcile the journal/admission and enforceable-execution-profile work. Do not recreate a command runner or activate a disabled production constructor as a shortcut. |
| Provider output truth | [#179](https://github.com/camerontjs-dot/Conduit/pull/179) → [#181](https://github.com/camerontjs-dot/Conduit/pull/181) → [#182](https://github.com/camerontjs-dot/Conduit/pull/182), rooted in #177 | Preserve application-level errors, current-runtime attribution and the unresolved native duplicate-delta limitation. |
| Context | [#58](https://github.com/camerontjs-dot/Conduit/issues/58), [#140](https://github.com/camerontjs-dot/Conduit/pull/140) → [#148](https://github.com/camerontjs-dot/Conduit/pull/148) → [#150](https://github.com/camerontjs-dot/Conduit/pull/150) | Extend existing source identities, snapshots, recipes and provenance. No second Context Compiler. |
| Task/work UI | [#50](https://github.com/camerontjs-dot/Conduit/issues/50), [#54](https://github.com/camerontjs-dot/Conduit/issues/54), #49/#53 where runtime behavior is involved | Reuse Conversation, Raw, context and inspector surfaces; preserve navigation and pending drafts. |
| Workspaces and changes | [#57](https://github.com/camerontjs-dot/Conduit/issues/57), [#120](https://github.com/camerontjs-dot/Conduit/pull/120) | Workspace writer ownership and provider-session ownership remain separate. |
| Service boundary | [#4](https://github.com/camerontjs-dot/Conduit/issues/4) | Extract a testable in-process boundary before choosing helper/XPC/launchd/daemon packaging. |
| Optional MainFrame consumption | [MainFrame #72](https://github.com/camerontjs-dot/mainframe-live/issues/72), [#86](https://github.com/camerontjs-dot/mainframe-live/issues/86) | Use existing lifecycle/handoff routes; keep causal continuation research separate. |

At the planning inspection, the journal and output repairs were separate Draft stacks, including #180 at `a4b656283b7e8c74bddb16175b667944a5a255fa` and #182 at `828498adcccea5ee9acee403a888c037337701dd`. The latter still disclosed that native OpenCode delta identity cannot support universal duplicate suppression. Preserve the negative records that led to both successors.

Protected mounted sequencing was recorded under [the #60 checkpoint](https://github.com/camerontjs-dot/Conduit/issues/60#issuecomment-6281289361): #168 → #123 → #128, with #142 integration HOLD. Recheck the governing record. These are dependencies for the actions they govern, not a reason to block unrelated deterministic contracts or source/UI development.

## 5. Implementation sequence

The dependency order below is the starting recommendation. Local review may combine related reversible UI/workflow changes into one isolated candidate, then prune and harden it. Changes to command replay, persistence, authority and destructive operations need their own inspectable boundaries.

### Step 0 — Review and finalize the retained plan

**Disposition:** done; see §0.

Inspect local repository roots, remotes, heads, worktrees and unrelated changes. Distinguish the installed operator application from maintained main, candidate code and the new plan. Read applicable host/repository instructions and live owner records. Use an owned worktree rather than tidying someone else's work.

For each of the seven areas, record the adoption disposition, observed gap, relevant existing implementation, acceptance conditions and real dependencies. Resolve routine implementation choices directly. State the smallest open product/authority question only when evidence cannot resolve it.

**Exit:** a revised plan and source starting point are recorded in this PR. Continue directly into eligible implementation; plan finalization is not the terminal task.

### Step 1 — Revision-aware reads and honest coverage

**Disposition:** implemented in [#184](https://github.com/camerontjs-dot/Conduit/pull/184) (D-077). Contract: `docs/conversation-revision-feed.md` in that PR.

**Purpose:** let an independent reader recover promised updates and distinguish complete, partial, unavailable and empty sources.

Build on the existing conversation log and event-export machinery. Separate stable item identity, source/revision identity, presentation position and change sequence. Specify the scope of each cursor and the source/log generation it belongs to.

Required behavior:

- A revision advances the change cursor while preserving the item's display identity.
- Snapshot responses identify the point through which they are current.
- Catch-up and live delivery cannot silently lose changes at the transition.
- Bounded views disclose truncation, omitted history and available expansion paths.
- Exact expansion can recover the promised source content, including long Unicode text.
- Missing, empty, unreadable/corrupt and partially available sources remain distinguishable.
- A cursor from an incompatible generation or unavailable retention range produces explicit reconciliation, snapshot recovery or unavailable coverage.
- A cancelled reader never persists a cursor beyond the state it applied; an obsolete reader cannot replace its successor's cache.
- Normal gaps caused by scope, filtering or a documented projection are not automatically labelled corruption.
- Reading, replaying observations and opening history never execute provider work.

Keep the existing timeline cursor's meaning intact. Use an additive/versioned interface where needed; reject unsupported semantics explicitly. Do not make raw evidence retention depend on UI compaction.

**Exit:** deterministic producer/consumer tests establish the retained contract, including negative cases. Report current-view convergence and retained-revision accessibility separately.

### Step 2 — Reconcile acceptance, effects and truthful outcomes

**Disposition:** reuse the existing stacks; the acceptance list in §0 goes to the #60 integration candidate.

**Purpose:** strengthen the existing request journal and output-ownership work using T3's failure cases.

Compare durable intent, command identity, authorization, effect execution and result settlement in the current candidates. A refused-before-effect request and an accepted or possibly executed request require different recovery treatment.

Required behavior:

- Durable accepted intent exists before the first possible effect.
- A retry uses the original request identity; a conflicting reuse of that identity is rejected according to an explicit contract.
- Lost acknowledgement or lost settlement does not cause silent re-execution.
- Process-bound effects are distinguished from replay-safe work; uncertain external results remain unknown.
- A provider error cannot become successful completion because HTTP or transport acceptance succeeded.
- A stale runtime callback cannot close, label or append output to its replacement.
- Output remains bound to the task/runtime/prompt/provider identities actually established.
- Provider completion and finalization are observable independently; neither establishes verified task success.
- Partial writes, exhausted admission capacity and cancellation races have honest outcomes.

Reuse or repair the appropriate existing stack. If a composition is necessary, record its exact parents and treat it as a new candidate; preserve frozen predecessor records.

**Exit:** the bounded implementation and relevant failure controls pass at their claimed boundary. Developer fixtures, real provider evidence and installed/hosted acceptance are reported separately.

### Step 3 — Provider capabilities, authority and compatibility

**Disposition:** reuse; runtime capability registry rejected for now (§0, area 6).

**Purpose:** make supported actions discoverable and enforceable without assuming uniform providers or synchronized clients.

Compare existing capability fields against native identity strength, steering, interruption, request resumability, approval option IDs, history injection, workspace checkpointing, conversation rollback and enforcement.

Expose unsupported and unknown capabilities honestly. Preserve provider-instance/account ownership. Health probes must not silently launch sessions, logins or other setup effects.

For externally initiated commands, derive caller authority from authenticated context and recheck relevant mutable authority at the execution boundary. A visible approval is not an approval grant. Keep read-only tools semantically read-only and preserve existing execution-profile restrictions.

Negotiate optional client features from actual runtime capabilities. Test older or missing capability fields and incompatible persisted records where the changed contract creates that risk. A descriptor does not prove that a hosted client refreshed its catalog.

**Exit:** one explicit supported/unsupported/unknown mapping drives the affected behavior, with targeted denial, stale-request and compatibility cases. No new provider is required merely to demonstrate the abstraction.

### Step 4 — Source-bound portable handoffs

**Disposition:** deferred; the conversation-item producer is unbuilt #58 implementation work, not a pending operator approval (§0, area 3).

**Purpose:** give a successor enough context to proceed and enough provenance to recover omitted material.

Extend Conduit's context primitives with the distinctions needed by the real consumer:

- Source task/thread/run/item and applicable revision identity.
- Source and destination provider/runtime identity when material.
- Covered run/item range and the selection basis.
- Included intact content, explicit omission counts/identities and bounded expansion references.
- Prepared versus delivered/injected status, with failure/unknown preserved.
- Byte/character budgets distinguished from native model-token telemetry.
- History labelled as context; current governing sources remain separately identified.

Do not imply that portable context restores provider-native tools, attachments, approval callbacks or hidden state. A retry must not inject the same handoff twice. If native acceptance may have occurred but the durable delivery marker is missing, preserve an explicit unknown delivery outcome; do not retry injection or silently replace the provider thread to escape that uncertainty. Reconciliation or an explicitly authorized new-thread action must preserve the continuity distinction. Validate references against the actual retained source; a self-reported item ID alone is not source custody.

**Exit:** a consumer can recover promised content and identify partial/missing history. This establishes a product contract, not improved model reasoning or lower token cost.

### Step 5 — One coherent task view

**Disposition:** deferred behind the #168 disposition (§0, area 4).

**Purpose:** reduce the effort required to understand and control a task.

Use the existing surfaces to show objective/scope, exact workspace and provider, current request state, actionable pending input, changed artifacts, context provenance and verification evidence. Keep Raw available.

Required distinctions include:

- Transport connected versus task data synchronized.
- Live versus cached/stale observations.
- Queued/accepted versus dispatched/active.
- Provider ended versus finalization pending.
- Pending actionable request versus lost/expired/non-resumable request.
- Claimed completion versus verified/failed/inconclusive work.

Related reversible view and workflow changes may be explored together in an isolated candidate. Prune redundant controls and test the actual journey before adding abstractions. Preserve active selection, drafts, accessibility, keyboard behavior and source-labelled history.

**Exit:** an operator can answer what is running, what needs attention, what changed and what remains unverified through the intended interface. Native/mounted evidence must come from an owned authorized candidate; screenshot or source review alone does not qualify interaction.

### Step 6 — UI-independent service boundary

**Disposition:** first in-process slice implemented in [#185](https://github.com/camerontjs-dot/Conduit/pull/185) (D-078); packaging deferred to #4 Phase C.

**Purpose:** give native and external clients a consistent execution owner.

Follow #4: first extract a narrow Core/service boundary that can be exercised independently of SwiftUI/AppKit, while preserving behavior. Keep one owner for task/runtime identity, admission, delivery and durable observations. Avoid parallel ownership in AppModel and a new service.

Use contract evidence and the existing lifecycle/restart acceptance question to decide whether process separation is warranted. Do not choose an additional daemon merely because T3 uses a server.

If a separate host is retained, test lifecycle, ownership, authentication, startup, shutdown and recovery with owned fixtures. GUI restart survival is not established by an in-process refactor. A real GUI termination/reconnect test must demonstrate the same task/runtime without a duplicate launch.

**Exit:** the implemented boundary is identified precisely, with evidence for what it survives and explicit limits on process independence.

### Step 7 — Change review, checkpoints and constrained restoration

**Disposition:** read-only review deferred to #120; restoration rejected for now (§0, area 7).

**Purpose:** make work inspectable before adding restoration authority.

Start with read-only change review: identify workspace/base/checkpoint, show changed files and diffs, and distinguish observed changes from attribution to an agent. Concurrent external edits must not be silently claimed as agent work.

Reuse current Git inspection and workspace leases. Evaluate a checkpoint representation that preserves the user's branch and unrelated dirty state. Retention, disk usage and partial checkpoint failures need bounded behavior.

Restoration is conditional on a demonstrated need and an explicit supported contract. It requires current workspace ownership, isolation, matching source identity, provider conversation capability where relevant, and a precise response to partial failure. Recheck those conditions immediately before the effect. Preserve unrelated and external edits.

Filesystem restoration cannot promise reversal of external messages, services, credentials or other side effects. A diff or checkpoint is evidence of observed workspace state, not task verification.

**Exit:** read-only change review has its own acceptance result. Any restore capability has separate authorization, negative controls, recovery evidence and limitations.

### Step 8 — Optional MainFrame consumer and separate research

**Disposition:** no consumer now (§0, area 8).

Where a concrete consumer needs it, add Conduit source references to existing MainFrame resume/handoff routes in a separately scoped MainFrame PR. Preserve direct file/Git workflows when Conduit is unavailable. Do not add a second event database, duplicate context compilation, force history preload or introduce a universal authority packet.

Ordinary source-contract integration may proceed independently of the causal history-benefit study.

The research comparison remains under MainFrame #72/#86:

- BASE: a good handoff plus current sources.
- HISTORY: identical inputs plus optional source-bound history.
- Score task/next-action quality, authority correctness, continuation, observed model usage and avoidable operator intervention separately.
- Include useful, redundant, stale, missing and partial history.
- A poor baseline handoff rescued by history does not establish the need for a memory architecture.

At review time, [MainFrame PR #114](https://github.com/camerontjs-dot/mainframe-live/pull/114) was closed unmerged and its evaluator was NOT QUALIFIED for these claims. Do not reuse it as if it had passed. A separately identified successor must bind responses and source acquisition to frozen case/arm/world/attempt evidence and pass challenge; the actual experimental actor boundary must also be qualified.

**Exit:** consumer engineering has a bounded disposition. Any later research outcome is reported separately and does not retroactively change the original negative record.

## 6. Failure controls and evidence

Choose focused cases that can expose the changed behavior. The following is a required coverage map for retained features, not an instruction to duplicate tests already proving the same boundary.

| Boundary | Decisive cases | Evidence required |
| --- | --- | --- |
| Revision reads | Old item revised after cursor; multiple revisions; long Unicode; bounded expansion; missing/empty/unreadable; incompatible cursor generation | Promised changes and content recovered, or explicit unavailable/partial state. |
| Snapshot/live transition | Update during catch-up; replay overlap; cancellation before apply; obsolete connection/cache callback | No silent state gap; cached cursor never outruns applied state; fresh state survives stale callbacks. |
| Request journal | Lost ACK; conflicting request ID; pre-effect refusal; crash after possible effect; failed durable settlement | Recover original receipt/outcome or explicit unknown; no blind repeated external effect. |
| Provider attribution | Prior runtime exits late; earlier prompt output arrives late; application error in successful HTTP response | Correct current identity and truthful outcome; native ambiguity preserved. |
| Permissions | Read-only caller tries mutation; grant or runtime mode changes while waiting; request no longer actionable | Denial at the actual effect boundary without hidden fallback. |
| Handoff | Budget overflow; omitted item retrieval; failed/retried injection; crash after native acceptance before durable marker; stale source revision; unavailable native state | Honest coverage/delivery and exact promised expansion; uncertain delivery cannot trigger reinjection or silent thread replacement; no authority upgrade. |
| UI | Offline cache; healthy socket with failed data stream; lost approval process; provider ended with pending finalization | Observable distinctions and usable recovery actions in the native journey. |
| Service boundary | Client replacement; GUI close/reopen where authorized; worker loss; conflicting ownership | Same known identities or explicit discontinuity; no duplicate runtime. |
| Workspace | Dirty/shared worktree; external edit; lease change; checkpoint failure; unsupported rollback | Read review remains useful; consequential restore refuses or reports bounded partial failure safely. |
| MainFrame | Old instruction conflicts with current accepted source; history unavailable; direct-work fallback | Current governing sources win; optional history cannot become a mandatory dependency. |

T3 reference tests worth examining include [FoundationPersistence][T13] and [threads-sync][T14]. They cover transaction rollback, effect claims, cancellation, publication order and cursor/cache ownership. Adapt relevant failure scenarios to Conduit's specification; do not treat imported tests or implementation-authored tests as independent validation.

Use event/receipt milestones or deterministic test clocks for asynchronous assertions where practical. A queue being empty is not proof that its current item finished. Keep development state separate from the live installation; use owned synthetic or appropriately sanitized copies, never a writable reference to live task databases or credentials.

## 7. Delivery and completion

Keep this PR documentation-only. Implementation belongs in coherent linked PRs or an explicitly identified isolated integration candidate. Link actual dependencies, preserve negative predecessors and avoid unrelated cleanup. Do not require every open Conduit draft to finish before independent work can proceed.

For each retained change:

1. State the intended behavior, protected behavior, source/base and acceptance conditions.
2. Implement and run proportionate tests capable of exposing the failure mode.
3. Preserve meaningful first failures; repair ordinarily and retest under a new identity.
4. Perform the strongest available consumer/integration check required by the claim.
5. Update CHANGELOG in the same commit as user-visible product changes; update DECISIONS when an architectural boundary changes.
6. Reconcile exact source/tree, checks, skips, failures, limitations and disposition into the owning PR.
7. Continue to the next eligible retained change.

Document-only checks for this planning PR are source/reference, scope/diff and information-hygiene review. Native, provider, installed-app and model experiments are NOT_RUN for this planning change; CHANGELOG is N/A.

The local task is complete when every proposed area has an evidence-backed disposition, retained eligible implementation is delivered with inspectable evidence, and genuinely blocked/conditional work has a precise owner and prerequisite. Do not mark the whole programme complete from a source build, one green test suite or a rewritten plan.

If an action is blocked, name the exact instruction, capability or apparatus that blocks it, finish unaffected work, and leave the smallest actionable handoff. Do not repeatedly ask the operator to confirm already-authorized implementation.

## 8. Source reuse and attribution

Prefer behavior specifications, failure cases and small compatible mechanisms. Directly importing T3's TypeScript/Effect orchestration into Conduit's Swift code is a separate dependency/migration decision and is not selected here.

T3's [MIT license][T15] requires its copyright and permission notice in copies or substantial portions. Record upstream commit/path and preserve required notices for any actual copied code. A reference link or an independently implemented idea must not be represented as an upstream qualification of Conduit.

## References

[C1]: https://github.com/camerontjs-dot/Conduit/blob/10a8d03852b1589a98f212d317c26463cda93c76/Sources/ConduitCore/ConduitSessionEvents.swift#L398-L476
[C2]: https://github.com/camerontjs-dot/Conduit/blob/10a8d03852b1589a98f212d317c26463cda93c76/Sources/ConduitCore/ConversationEventLog.swift#L383-L415
[T1]: https://github.com/pingdotgg/t3code/blob/8cd561ef6f8d09e22b50429982acaf1e9b896086/apps/server/src/orchestration-v2/EventSink.ts#L615-L679
[T2]: https://github.com/pingdotgg/t3code/blob/8cd561ef6f8d09e22b50429982acaf1e9b896086/apps/server/src/orchestration-v2/ThreadStream.ts#L42-L108
[T3]: https://github.com/pingdotgg/t3code/blob/8cd561ef6f8d09e22b50429982acaf1e9b896086/apps/server/src/persistence/OrchestrationEventStore.ts#L449-L535
[T4]: https://github.com/pingdotgg/t3code/blob/8cd561ef6f8d09e22b50429982acaf1e9b896086/apps/server/src/orchestration-v2/ProjectionMaintenance.ts#L199-L241
[T5]: https://github.com/pingdotgg/t3code/blob/8cd561ef6f8d09e22b50429982acaf1e9b896086/apps/server/src/orchestration-v2/ContextHandoffService.ts#L410-L485
[T6]: https://github.com/pingdotgg/t3code/blob/8cd561ef6f8d09e22b50429982acaf1e9b896086/packages/provider-core/src/server/handoffBudget.ts#L223-L275
[T7]: https://github.com/pingdotgg/t3code/blob/8cd561ef6f8d09e22b50429982acaf1e9b896086/docs/internals/connection-runtime.md
[T8]: https://github.com/pingdotgg/t3code/blob/8cd561ef6f8d09e22b50429982acaf1e9b896086/packages/client-runtime/src/state/threadRequests.ts
[T9]: https://github.com/pingdotgg/t3code/blob/8cd561ef6f8d09e22b50429982acaf1e9b896086/docs/internals/providers.md
[T10]: https://github.com/pingdotgg/t3code/blob/8cd561ef6f8d09e22b50429982acaf1e9b896086/apps/server/src/mcp/McpToolAccess.ts#L124-L167
[T11]: https://github.com/pingdotgg/t3code/blob/8cd561ef6f8d09e22b50429982acaf1e9b896086/docs/internals/overview.md
[T12]: https://github.com/pingdotgg/t3code/blob/8cd561ef6f8d09e22b50429982acaf1e9b896086/apps/server/src/orchestration-v2/CheckpointRestoreSafety.ts
[T13]: https://github.com/pingdotgg/t3code/blob/8cd561ef6f8d09e22b50429982acaf1e9b896086/apps/server/src/orchestration-v2/FoundationPersistence.test.ts
[T14]: https://github.com/pingdotgg/t3code/blob/8cd561ef6f8d09e22b50429982acaf1e9b896086/packages/client-runtime/src/state/threads-sync.test.ts
[T15]: https://github.com/pingdotgg/t3code/blob/8cd561ef6f8d09e22b50429982acaf1e9b896086/LICENSE

