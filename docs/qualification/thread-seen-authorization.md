# Thread seen-cursor authorization

This candidate defines the pure authorization seam between an established unseen
output revision and a future persisted presentation cursor.

## Boundary

The cursor may advance only when one explicit UI observation establishes all of
the following for the same task:

- the selected surface is Conversation, not Raw;
- the application is active;
- the owning window is key;
- the owning window is visible;
- the exact latest unseen output revision is the revision actually visible.

Task selection, task existence, task-row hover/focus, provider output state,
capture settling/closing, and source recency do not authorize cursor advancement.

The policy consumes the already-validated `ThreadUnseenOutputState`. An
unavailable source remains unavailable. A stale visible revision cannot clear a
newer unseen revision.

## Scope

This slice does not:

- detect actual viewport visibility;
- read AppKit window state;
- persist or reload a cursor;
- change the task rail;
- add badges or unseen counts;
- change selection or reconnect behavior;
- infer provider completion, waiting state, or operator response obligation.

A later mounted UI slice must produce `ThreadSeenObservation` from real
Conversation visibility and only then persist an authorized revision.

## Required qualification

Test the exact candidate unchanged:

1. source preflight;
2. `./scripts/test.sh --filter ThreadSeenCursorTests`;
3. full maintained `./scripts/test.sh`;
4. macOS 13 deployment-target compilation of `ConduitCore`;
5. source postflight and teardown.

No app launch, provider fixture, provider turn, cursor persistence, or mounted UI
is required for this pure Core authorization slice.

## Allowed disposition

- `PASS_BOUNDED_THREAD_SEEN_AUTHORIZATION`
- `PRODUCT_FAIL`
- `APPARATUS_FAIL`
- `BLOCKED_SOURCE_CUSTODY`
