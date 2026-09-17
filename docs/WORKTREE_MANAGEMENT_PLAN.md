# Conduit worktree management plan

Status: planning candidate

Date: 2026-09-17

Pinned planning base: `4b87ddd3ee72d42955e7f044a6b24bdc292023e1`

## Objective

Make Git worktree state legible and safely associated with Conduit's durable agent tasks without turning Conduit into a second Git authority or expanding the default chat UI into a permanent repository dashboard.

The immediate operator problem is concrete:

> Agents create linked worktrees for bounded work. Later, an operator may re-enter one of those directories and continue working there without realizing that it is a historical or task-specific checkout.

The first implementation should prevent accidental reuse and improve reconstruction before adding destructive cleanup or automated worktree lifecycle actions.

## Current live seams

Conduit already has most of the required substrate:

- `GitWorkspaceInspector` provides bounded read-only repository inspection for branch, HEAD, status, diff, history, blame, and content identity.
- `TaskSessionID` is durable across runtime attempts, while `RuntimeAttemptID` identifies a concrete runtime attempt.
- `TaskSessionMetadata.workspace` preserves project/MainFrame scope rather than terminal prose or inferred intent.
- `MainframeObservedTaskBridge` projects task associations only from explicit durable workspace bindings and does not infer ownership from agent names or output text.
- PR #33 added the Context IDE, source workbench, Git inspection, graph/workstation projections, and authority-labelled handoff/context surfaces.
- The conversation-first UI plan keeps secondary operational state in contextual side surfaces rather than permanent central chrome.

The missing capability is a first-class read model for linked Git worktrees plus an explicit task-to-execution-workspace association.

## Governing architecture

Preserve distinct authorities:

```text
Git
  = repository/worktree topology and repository state

Conduit
  = durable task/runtime identity and explicit task-resource associations

MainFrame
  = project/lifecycle identity and workspace policy

Conduit UI
  = joined projection of those facts
```

Do not persist branch/HEAD/dirty state as independent Conduit truth when it can be read from Git.

Do not overload `TaskSessionMetadata.workspace.projectPath` with a linked worktree path. Project scope answers "what project is this task about?" while execution scope answers "which checkout is this task operating in?" Those are different facts and may change independently.

## Proposed worktree read model

Extend the existing read-only Git inspection boundary with a typed parser for:

```text
git worktree list --porcelain
```

A worktree observation should be able to represent, when Git exposes it:

- repository/common Git directory identity;
- worktree path;
- HEAD SHA;
- branch ref or detached state;
- whether it is the primary checkout or a linked worktree;
- locked/prunable/bare facts where applicable;
- current dirty/clean state from the existing inspector when inspected;
- observed time / refresh boundary as presentation metadata, not Git truth.

The parser should be deterministic and independently testable from fixture output.

## Task-to-worktree association

Add an explicit execution-resource association distinct from immutable project scope.

Minimum conceptual record:

```text
TaskSessionID
resource kind: git-worktree
repository identity
worktree path
association provenance
recorded at
```

Initial provenance classes should be conservative:

- `conduitRecorded`: Conduit created or explicitly bound the worktree for the task.
- `operatorAsserted`: the operator explicitly associated an existing worktree with a task.
- `observedUnowned`: Git proves the worktree exists, but Conduit cannot establish task ownership.

Do not infer ownership merely because a worktree appeared while an agent was active.

If future structured provider/tool telemetry reports worktree creation, preserve that as provider/tool-reported evidence unless Conduit itself performed the binding.

## Workspace-use state

Presentation may derive a bounded use state from Git observations plus task associations:

- `ACTIVE`: explicitly associated with a current/nonterminal task/runtime.
- `AVAILABLE`: valid worktree with no current task association requiring operator attention.
- `HISTORICAL`: associated task is closed/archived/nonterminal runtime absent.
- `UNKNOWN_OWNER`: Git worktree exists but association provenance is absent.

These labels are operational navigation aids only. They must not assert merge status, correctness, task success, or safe deletion.

## Operator safety behavior

The first implementation should solve accidental reuse, not automate cleanup.

When an operator opens a file whose repository root is a historical task-associated worktree, Conduit should make that identity obvious before editing.

Candidate behavior:

```text
Historical worktree
Task: <task title>
Branch: <branch>
Path: <path>
Task state: closed
Git state: clean / dirty / unknown

[Return to default checkout]
[Use this worktree]
[Reveal in Finder]
```

Editing a historical task-owned worktree should remain unavailable until an explicit `Use this worktree` action establishes current operator intent for the session. This should be an editing admission guard, not filesystem chmod or a claim that the directory itself is read-only.

Do not block read-only inspection.

Do not assume a clean worktree is safe to delete.

## UI fit

Follow the conversation-first hierarchy.

### Thread/header

Show only a compact repository/worktree indicator when it is useful, for example:

```text
CAL · Claude
research/contract-c-rc3 · linked worktree
```

or a warning state for a historical/unknown worktree.

### Inspector

Add a Workspace/Git section that can show:

- repository identity;
- primary checkout;
- linked worktrees;
- branch/HEAD/status;
- explicit task associations and provenance;
- active/historical/unknown-owner presentation state;
- open/reveal/use-default-checkout actions.

This is the full operational surface. The default conversation remains dominant.

### Source workbench

Surface the exact current worktree identity with source inspection/editing so a file is never presented as if it were simply "the repo" when it belongs to a linked checkout.

## MainFrame boundary

Ordinary MainFrame Explorer traversal should retain its existing selected-root containment contract. Do not inject arbitrary external worktrees into the MainFrame file tree.

A worktree outside the selected MainFrame root is an associated operational resource, not a synthetic MainFrame child.

The MainFrame integration should consume this read model for reconstruction and policy, but MainFrame lifecycle files should not become a duplicate worktree registry.

## Phase 1 scope

Implement only the evidence and safety layer:

1. Parse `git worktree list --porcelain` through a bounded read-only inspector.
2. Represent exact worktree topology and repository identity.
3. Keep semantic project scope separate from execution/worktree scope.
4. Add explicit append-first task-to-worktree association with conservative provenance.
5. Project worktree identity into Inspector and Source Workbench.
6. Add compact thread/header indication only where useful.
7. Gate editing of historical task-owned worktrees behind explicit current-use acknowledgement.
8. Expose the read model to MainFrame/session reconstruction through a narrow bridge or stable local interface.

## Explicitly out of scope for Phase 1

- automatic worktree deletion;
- `git worktree remove`;
- `git worktree prune` as a mutating operator action;
- checkout/reset/add/commit/merge/rebase/stash;
- automatic branch deletion;
- inferred ownership from timing, agent name, terminal prose, or filesystem naming conventions;
- treating merged branch state as sufficient proof that a worktree is disposable;
- changing MainFrame lifecycle authority;
- adding external worktrees to normal Explorer traversal.

## Future cleanup/disposition slice

Only after Phase 1 is exercised on real worktrees should Conduit consider an explicit disposition workflow.

A future cleanup assessment would need to distinguish at least:

- dirty working tree;
- staged changes;
- untracked files;
- unique/unpushed commits;
- branch reachability/merge state;
- detached HEAD;
- lock/prunable state;
- task association and task state;
- operator-declared retention intent.

No single one of these is sufficient by itself to establish `SAFE_TO_REMOVE`.

A destructive action should remain explicit, independently qualified, and receipt-producing.

## Evidence and tests

### Core deterministic tests

Cover:

- porcelain worktree parsing across primary, linked, detached, locked, prunable, and malformed fixtures;
- repository/worktree identity stability;
- task association authority/provenance rules;
- historical/current use-state projection;
- refusal to infer ownership from coincidental runtime state;
- editing-admission behavior for historical worktrees;
- no change to ordinary Explorer containment behavior.

### Installed-app acceptance

Exercise at least:

- one primary checkout plus two linked worktrees;
- one active task-bound worktree;
- one closed-task historical worktree;
- one unowned worktree;
- dirty and clean states;
- open file from historical worktree -> inspect -> explicit use -> edit;
- return-to-default-checkout navigation;
- task detach/reconnect without losing the durable association;
- app restart/recovery if association is persisted.

Preserve exact commit/build/install identity and the existing local qualification discipline.

## Decision questions before implementation

Use research and a local inventory to answer rather than assume:

1. What exact worktree creation patterns are current agents/tools producing on this machine?
2. Which associations can Conduit observe directly today, and which require an explicit operator or creation hook?
3. Is the repository common Git directory the right stable identity across linked worktrees for Conduit's purposes?
4. What lifecycle should a task/worktree association have when a task closes and later reopens?
5. What is the smallest acknowledgement mechanism that prevents accidental edits without making legitimate historical work awkward?
6. What cleanup conditions can be proved locally, and which remain operator judgment?

## Exit condition for this plan

A first implementation candidate is ready for qualification when Conduit can truthfully answer:

> Which Git checkout am I in, which task is explicitly associated with it, is that association current or historical, and have I explicitly chosen to work here?

without inventing ownership and without taking destructive Git action.
