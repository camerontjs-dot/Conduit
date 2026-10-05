# Unseen output revision identity

Owner: [UX-A chronology / supervision #49](https://github.com/camerontjs-dot/Conduit/issues/49).

## Problem

A presentation cursor cannot decide whether an agent has produced unseen output
from `SessionPresentationEvent.id` alone.

Conduit intentionally revises one visible output block under the same event ID
while text streams. If a cursor stores only that event ID, new text can arrive
while the operator is elsewhere and still compare equal to the "seen" cursor.

The inverse failure also matters: output capture can move from `live` to
`settled` or `closed` without any new visible text. That state transition must
not become a false unread indicator.

## Candidate contract

`ThreadOutputRevisionIdentity` binds:

- exact output event ID;
- associated prompt event ID;
- extraction/source representation;
- source truncation fact;
- exact visible UTF-8 byte count;
- SHA-256 of the full visible output text.

It deliberately excludes `AgentOutputState`.

`ThreadUnseenOutput.project` returns:

- `none` when there is no retained output or the latest visible revision matches
  the supplied presentation cursor;
- `unseen(identity)` when the latest visible revision differs;
- `unavailable(reason)` when the already-bound conversation source cannot
  support a valid decision.

The projector reuses `ThreadRecognition` validation for source coverage,
duplicate IDs, timestamp validity and event authority.

## Authority boundary

This is presentation state only.

It does not say:

- the provider turn completed;
- the agent is waiting;
- the operator owes a response;
- the objective succeeded;
- an output has been acknowledged by a provider;
- how many unseen turns exist.

It does not persist or advance a read cursor.

A later UI/storage slice must advance a cursor only when it has evidence that
the operator actually viewed the relevant Conversation surface. Hovering a task
row is not sufficient.

## Performance boundary

The identity is designed so a later sidebar integration can publish one unseen
transition on the first changed visible revision while keeping subsequent
streaming revisions out of the narrow `TaskSidebarModel` publication path.

This candidate does not implement that integration.

## Prepared verification

Focused XCTest covers:

1. no output;
2. first output with no cursor;
3. exact seen revision;
4. new text under the same event ID;
5. capture-state-only transition;
6. source truncation change;
7. new output event ID;
8. Unicode UTF-8 identity;
9. unavailable source;
10. invalid event authority.

Dependency-free SelfTest mirrors the key revision/state/source controls.

Native Swift compilation and execution are NOT_RUN in the GitHub authoring
environment. The local gate should run the focused test, maintained SelfTest,
Python contracts and full native suite on the exact candidate.
