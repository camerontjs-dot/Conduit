# Local agent: review, finalize and implement the T3 Code adoption plan

Act as my local engineering collaborator for Conduit and its bounded MainFrame interfaces.

## Objective and authority

Review the planning PR containing this file and [the adoption plan](t3code-adoption.md) against live GitHub and the actual local implementation. Correct assumptions and sequencing where the evidence warrants, finalize the retained plan, then implement it.

Review, plan revisions, local source implementation, focused tests, repairs, relevant builds, documentation, and scoped GitHub PR updates are authorized. Continue through ordinary successors without asking for confirmation at every step. Do not stop at another plan if eligible implementation remains.

This task explicitly permits local implementation. Older general instructions allocating local agents only to qualification do not override that permission. Preserve the exact object of any frozen qualification; a repair creates a separately identified successor.

The planning PR is documentation-only. Deliver product implementation in coherent linked PRs or an explicitly identified isolated integration candidate. Use the plan as a set of questions and acceptance conditions, with freedom to simplify or reject a proposed mechanism when evidence supports that decision.

## Establish the real starting state

Locate the actual Conduit checkout through its Git remote (`camerontjs-dot/Conduit`), and distinguish it from any outer MainFrame repository. Read the applicable host and repository instructions. Inspect worktree cleanliness, existing work, remotes, exact heads and local/remote relationship before choosing a base. Preserve unrelated edits and unique evidence; use an owned worktree where needed.

Inspect the planning PR's current head, the plan's pinned T3 sources and any material upstream changes. Refresh Conduit #60 and the owner issues/PRs for the slice being selected. Read recent comments and check actual branch heads and executed CI rather than trusting an old PR description. Identify which candidate already implements the intended behavior.

Separately identify any installed/running Conduit baseline before runtime interaction. A local source checkout, a new build and the operator's installed app are different objects. Keep private machine paths, tasks, credentials and local receipts out of public diffs.

## Review and finalize

For each proposed area, choose reuse existing, implement a bounded change, defer with a real prerequisite, or reject with a reason:

- Durable request acceptance, effect recovery and truthful completion.
- Revision-aware reads, snapshots, reconnects and coverage.
- Portable source-bound handoffs.
- Task status, approvals, changes, context and verification UX.
- A UI-independent service boundary and client compatibility.
- Provider capabilities and caller authority.
- Change review, checkpoints and constrained restoration.
- Optional MainFrame consumption and separately gated history-benefit research.

Record the observed gap, protected behavior, acceptance conditions and actual dependencies. Reconcile existing global-event, journal/output, context and workspace candidates rather than starting competing implementations.

Prefer revision-aware read/coverage work first if the live source still confirms the gap. Preserve the old timeline cursor's meaning; a local event sequence cannot manufacture native provider identity.

Finalize the plan in its PR and continue directly into implementation. Only unresolved decisions that materially affect product intent, authority or irreversible behavior need operator input.

## Implement and verify

Build the smallest coherent candidate that satisfies the retained conditions. Related reversible interface/workflow changes may be developed together, evaluated, simplified and hardened. Keep consequential replay, persistence, authority and destructive-action boundaries explicit.

Use the plan's failure controls and the repository's existing tests. Choose tests for observable behavior; do not duplicate low-value implementation-shaped tests. Preserve meaningful failures and unknowns. Source-written fixtures are useful developer evidence, not independent qualification.

As applicable, verify late revisions, snapshot/live overlap, stale callbacks, missing/empty/partial sources, lost acknowledgements, possibly executed requests, pending approvals, context omissions, dirty workspaces and older clients. Inspect scripts before use and run the repository's appropriate native/Core/build checks. Keep asynchronous tests tied to events, receipts or controlled time where practical.

Conduit #4 calls for a testable in-process service boundary before deciding separate-process packaging. Do not introduce a daemon or claim GUI-restart survival from extraction alone.

Reuse Conduit's direct command/filesystem and Context Compiler work. Keep provider completion, process exit, agent claims and task verification separate. Preserve native permission options, direct PTY access and explicit unsupported/unknown states.

Use owned synthetic/fake-provider fixtures and isolated development state. Real provider or mounted acceptance must use a specifically authorized owned configuration and the current governing lane. Do not use the operator's existing tasks as test fixtures.

## MainFrame boundary

Conduit produces execution facts, retained-history references and destination context. MainFrame owns orientation, governing-source checks and lifecycle/handoff coordination.

Where a concrete consumer warrants a change, use a separate MainFrame PR linked to this plan. Preserve direct file/Git fallback and current-source revalidation. Avoid a second memory store, duplicated Context Compiler or mandatory history preload.

Keep the #72/#86 causal continuation comparison separate. Its prior PR #114 evaluator was not qualified. Do not launch that research through the failed evaluator or bypass the actor-admission boundary. Ordinary source-contract engineering and appropriately authorized product verification do not depend on resolving that research gate. Do not claim token savings or improved agent continuation from deterministic tests.

## Continue within the actual authority

The user has authorized source work and routine verification. This task does not itself lift an active installed-app, integration or experimental HOLD.

Preserve the running operator installation and existing task/provider state. Do not infer permission for production replacement, release, destructive migration, credential/permission changes, tunnel restarts or write-gate changes. Check the current owner record for any separately authorized machine action. If it is unavailable, record the exact missing prerequisite and continue independent source work.

Do not make all open drafts prerequisites. When dependencies genuinely overlap, preserve frozen evidence and use a named successor/composition with exact parents. Do not silently change historical candidates to obtain a pass.

For consequential reviews, use appropriate separate review and accurately state its independence. If an existing qualification specifies an exact reviewer/model or environment that is unavailable, report that gate honestly rather than substituting it silently.

## Deliver and close

Keep GitHub current with exact base/head/tree identities, implementation scope, checks actually executed, CI outcomes, preserved failures, skipped/unavailable checks and limitations. Update CHANGELOG with user-visible changes and DECISIONS when an architecture boundary changes.

Complete all eligible retained implementation and report a disposition for every plan area. Separate source readiness, qualified integration, merge readiness and installation/release. Advance merges only where the specific PR has authority and satisfies the applicable gates; plan finalization is not blanket promotion of existing drafts.

End with the revised plan PR, implementation PRs and source identities, what now works, what was actually tested, what remains unknown, and the next precise action for each blocked lane. If operator input is necessary, state the smallest decision, why existing authority cannot resolve it, the evidence and recommendation. Do not finish at “review complete” while authorized implementation remains.

