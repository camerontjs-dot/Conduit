# Conduit worktree management plan

Status: accepted planning baseline

Date: 2026-09-17

## Objective

Make Git worktree state legible and safely associated with Conduit's durable agent tasks without turning Conduit into a second Git authority or expanding the default conversation UI into a permanent repository dashboard.

The operator problem is concrete: agents create linked worktrees for bounded work, and later an operator or another agent can enter one without realizing it is a historical or task-specific checkout.

The first implementation should prevent accidental reuse and improve reconstruction before adding destructive cleanup or automated worktree lifecycle actions.

## Authority model

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

Do not persist branch, HEAD, dirty state, or worktree topology as an independent Conduit truth when Git can be queried directly.

Do not overload durable project scope with execution checkout identity. Project scope answers "what project is this task about?" Execution scope answers "which checkout is this task operating in?" They are separate facts.

## Existing seams

Conduit already has useful substrate:

- `GitWorkspaceInspector` for bounded read-only Git inspection;
- durable `TaskSessionID` and runtime-attempt identity;
- explicit task workspace metadata rather than terminal-prose inference;
- `MainframeObservedTaskBridge` for authority-preserving task projections;
- Source Workbench and Context IDE surfaces that can display exact repository/file identity;
- a conversation-first UI direction that keeps secondary operational state contextual rather than permanently occupying the central thread.

The missing capability is a first-class read model for linked Git worktrees plus an explicit task-to-execution-workspace association.

## Phase 1 read model

Extend the read-only Git boundary with a typed parser for:

```text
git worktree list --porcelain
```

Represent, when Git exposes it:

- repository/common Git directory identity;
- worktree path;
- HEAD SHA;
- branch ref or detached state;
- primary checkout vs linked worktree;
- locked, prunable, or bare facts where applicable;
- current dirty/clean state when separately inspected;
- observation time as presentation metadata, not Git truth.

The parser should be deterministic and fixture-testable.

## Task-to-worktree association

Add an explicit execution-resource association distinct from semantic project scope.

Minimum conceptual record:

```text
TaskSessionID
resource kind: git-worktree
repository identity
worktree path
association provenance
recorded at
```

Initial provenance should remain conservative:

- `conduitRecorded`: Conduit created or explicitly bound the worktree for the task;
- `operatorAsserted`: the operator explicitly associated an existing worktree with a task;
- `observedUnowned`: Git proves the worktree exists but Conduit cannot establish task ownership.

Do not infer ownership from timing, worktree naming, agent identity, terminal prose, or filesystem adjacency.

## Presentation state

The UI may derive bounded operational labels from Git observations plus explicit associations:

- `ACTIVE`: explicitly associated with a current/nonterminal task or runtime;
- `AVAILABLE`: valid worktree with no current association requiring attention;
- `HISTORICAL`: explicitly associated task is closed/archived or no longer has a current runtime;
- `UNKNOWN_OWNER`: Git worktree exists but association provenance is absent.

These are navigation aids only. They must not assert merge status, correctness, task success, or safe deletion.

## Operator safety behavior

The first implementation should solve accidental reuse, not automate cleanup.

When a file belongs to a historical task-associated worktree, make that identity obvious before editing. Read-only inspection remains available. Editing should require an explicit current-use acknowledgement for that Conduit session.

Candidate presentation:

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

This is an editing-admission guard, not filesystem permission mutation and not a claim that the checkout is intrinsically read-only.

## UI fit

Keep the conversation surface dominant.

A compact worktree indicator may appear near task identity when useful. Full repository/worktree detail belongs in Inspector and Source Workbench, including:

- repository identity;
- primary checkout;
- linked worktrees;
- branch/HEAD/status;
- explicit task associations and provenance;
- active/historical/unknown-owner presentation state;
- reveal/open/default-checkout actions.

Source Workbench should always make the current worktree identity inspectable so a source file is not presented as if it were simply "the repo" when it belongs to a linked checkout.

## MainFrame boundary

Ordinary MainFrame Explorer traversal retains its selected-root containment contract. Do not inject arbitrary external worktrees into the MainFrame tree.

A worktree outside the selected MainFrame root is an associated operational resource, not a synthetic MainFrame child. MainFrame lifecycle files should not become a duplicate worktree registry.

## Phase 1 scope

1. Parse `git worktree list --porcelain` through a bounded read-only inspector.
2. Represent exact worktree topology and repository identity.
3. Keep semantic project scope separate from execution/worktree scope.
4. Add explicit task-to-worktree association with conservative provenance.
5. Project worktree identity into Inspector and Source Workbench.
6. Add a compact conversation/header indication only where useful.
7. Gate editing of historical task-owned worktrees behind explicit current-use acknowledgement.
8. Expose the read model to reconstruction through a narrow stable interface.

## Explicitly out of scope

- automatic worktree deletion;
- `git worktree remove` or mutating prune actions;
- checkout/reset/add/commit/merge/rebase/stash;
- automatic branch deletion;
- inferred ownership;
- treating merged branch state as sufficient proof that a worktree is disposable;
- changing MainFrame lifecycle authority;
- adding external worktrees to ordinary Explorer traversal.

## Qualification expectations

Core tests should cover porcelain parsing, repository/worktree identity, provenance rules, historical/current presentation, refusal to infer ownership, editing admission, and unchanged Explorer containment.

Installed acceptance should exercise a primary checkout plus multiple linked worktrees, active/historical/unowned associations, dirty and clean states, historical inspection before explicit use, return-to-default navigation, detach/reconnect, and restart recovery if associations are persisted.

Preserve exact commit/build/install identity and negative findings.

## Exit condition

A first implementation candidate is ready for qualification when Conduit can truthfully answer:

> Which Git checkout am I in, which task is explicitly associated with it, is that association current or historical, and have I explicitly chosen to work here?

without inventing ownership and without taking destructive Git action.
