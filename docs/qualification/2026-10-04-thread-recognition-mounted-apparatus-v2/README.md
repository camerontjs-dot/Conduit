# Thread recognition mounted apparatus v2 — 2026-10-04

Work class: **Research Infrastructure / mounted qualification apparatus**.

This packet exists because exact #158 passed its source/native gates but the mounted driver could not reliably deliver pointer hover or task-row keyboard focus. It does not change Conduit product behavior.

## Decision

Determine whether exact current-main UX candidate #160 responds correctly when the operating system actually delivers pointer-hover and keyboard-focus input to the intended task row.

The apparatus must distinguish:

- **input delivery failure** → APPARATUS_FAIL;
- **verified input delivery to the intended row followed by incorrect recognition behavior/state** → PRODUCT_FAIL;
- **correct bounded mounted behavior** → PASS_BOUNDED_NATIVE_AND_MOUNTED_UX.

Do not infer product failure from an input mechanism that never reached the target.

## Frozen subject

PR: #160  
Commit: `4c6298264d786b0b9cfda869053ba03a554d2158`  
Tree: `c64bfef19736aa690c8e931905678a2f08301924`

Base main at subject creation:
`81053d80db7ab364055665f96408a174b60d44bb`

The candidate carries the exact #158 AppModel, TaskSidebarView and provider-conformance blobs. #158 remains the predecessor native-pass / mounted-apparatus-fail record.

## Preserved predecessor evidence

Do not repeat or relabel these observations:

- #158 focused/native gates passed;
- distinct conversation vs generic recency cues were visible;
- 200 owned output revisions produced 409 Runtime/AppModel publications and zero TaskSidebarModel publications;
- pointer hover and row keyboard focus were not established;
- preview/source-state/noninterference mounted checks remained NOT_RUN.

Primary #158 return SHA-256:
`b1e079589dc4ba0607aeab8e96496aa15a5cb7b951be7004c8a042f56a5caf84`.

## Apparatus authority

Use an owned, qualification-only build and fixture state. Do not install Conduit into production locations.

The mounted driver may use documented/native macOS APIs required to deliver input to the owned test window:

- Accessibility APIs (`AXUIElement`) to discover the owned process/window hierarchy, task-row element bounds/identity, focused element, and post-input UI state;
- Quartz/CoreGraphics `CGEvent` to move the pointer and deliver keyboard events to the owned test app;
- `CGWindowList` / window geometry for cross-checking coordinates;
- an owned screenshot capture of the test window where it materially helps preserve the observation.

Do **not** change global keyboard-navigation preferences, Accessibility settings, input-source configuration, provider settings, account state or operator Conduit state merely to make the test pass.

If the current host lacks permission to use AX or CGEvent against the owned test process, preserve that exact denial and stop as APPARATUS_FAIL unless an already-authorized local permission state makes the call possible. Do not silently alter system privacy settings.

## Hard protocol

1. Verify exact #160 commit/tree and clean tracked source.
2. Run a compact current-main replay first:
   - maintained focused gate;
   - ThreadRecognition XCTest;
   - full maintained native gate.
3. Build the owned mounted artifact from the exact candidate.
4. Use fresh owned fixture roots and disable provider processes / provider writer authority / Session API writes unless the specific fixture requires an inert live Runtime object.
5. Before any input:
   - capture selected task;
   - active runtime/task inventory;
   - task-history and conversation-log hashes;
   - provider/writer/adoption flags;
   - target task row accessibility identity/bounds if available.
6. Pointer path:
   - make the owned window key/frontmost without selecting a task row;
   - locate the intended row from the accessibility hierarchy and derive its screen-space center;
   - cross-check the point resolves to the intended owned app/window/row where practical;
   - send a native mouse-move CGEvent to that point;
   - record event delivery attempt, pointer position, AX state and resulting UI observations;
   - require recognition card appearance before using its contents as evidence.
7. Keyboard-focus path:
   - establish the owned app/window as keyboard target;
   - prefer setting accessibility focus to the exact row when the AX focused attribute is writable;
   - otherwise drive native Tab traversal with real keycode events while recording every focused element;
   - do not enable/modify global Full Keyboard Access settings;
   - require the exact task row to become the focused element before treating the recognition result as keyboard-focus evidence.
8. If either input route cannot establish delivery to the target row, classify that route as apparatus failure. Do not call the product wrong.
9. Once recognition is successfully triggered, verify:
   - retained prompt/output excerpts match source bytes;
   - original retained timestamps match;
   - bounded excerpt signalling is truthful;
   - clean persisted source → retained timeline;
   - live Runtime source → retained window only;
   - missing/unreadable/diagnostic source → explicit unavailable state;
   - loading is represented while the asynchronous read is unresolved where naturally observable.
10. Recognition-only noninterference:
   - compare pre/post selected task;
   - task/runtime inventory;
   - task-history bytes/events;
   - conversation-log bytes/events;
   - provider writer/adoption state;
   - no reconnect/launch/send/provider turn.
11. Performance/publication:
   - repeat or reuse the prior 200-revision owned stream if the exact current-main replay remains compatible;
   - preserve Runtime/AppModel/TaskSidebarModel publication deltas;
   - additionally observe the actual mounted task-rail rendering path at the strongest practical boundary available without modifying product source;
   - do not translate zero TaskSidebarModel publications into a whole-app CPU claim unless that actual boundary was measured.
12. Preserve actual argv, environment, permissions state, exits, waits, AX/CGEvent results, screenshot hashes if captured, source pre/post custody and owned teardown.
13. Do not repair product source inside this apparatus.

## Fixture expectations

Use bounded owned fixtures sufficient to distinguish:

- retained conversation timeline;
- generic task-only activity;
- missing expected conversation source;
- unreadable source;
- diagnostic-bearing source;
- live inert Runtime with retained events.

A fixture title is not evidence of the state. Verify the underlying file/runtime condition.

Do not add provider execution merely to obtain a live label. An inert owned Runtime with the candidate's actual presentation events is sufficient if it truthfully exercises the live-source branch.

## Dispositions

Allowed terminal states:

- `PASS_BOUNDED_NATIVE_AND_MOUNTED_UX`
- `PRODUCT_FAIL`
- `APPARATUS_FAIL`
- `BLOCKED_SOURCE_CUSTODY`

If one route (pointer or keyboard) passes and the other fails at apparatus, return APPARATUS_FAIL with the passed partial evidence preserved; do not collapse partial success into full PASS.

A product failure requires verified delivery/entry into the relevant product path.

## Non-claims

This apparatus does not establish:

- provider completion;
- provider turns;
- installation behavior;
- production release;
- unseen/read cursor semantics;
- true last-output-update time;
- generated synopsis;
- tabs/splits/pop-outs;
- #128 composition;
- independent/context-free qualification.
