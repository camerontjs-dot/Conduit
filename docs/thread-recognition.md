# Retained thread recognition: UX-A source slice

Owner: #49, coordinated through #60 and its adopted UX Slice A.

Base: `b53c38ed303b2a6e7fb4de8936c04ed56da891ed`, tree
`3308565e9fbc35f8541911cea9a38b4e1b251260`.

Status: **UNCOMPILED / NATIVE NOT_RUN / NOT MOUNTED**. The source and test
cases have been prepared for review. No runtime behavior or acceptance is
established by their presence.

## Problem and scope

The task rail has durable task metadata, pinning and availability. Its combined
conversation timestamp cannot identify the latest prompt and output separately.
Administrative task activity can also advance its general activity timestamp.

`ThreadRecognition.project` produces a pure, bounded recognition summary from
the existing retained `SessionPresentationEvent` contract. It keeps the latest
prompt, latest output block and latest conversation-event origin in supplied
retained order, and supplies exact leading excerpts for recognition. Opening and
interrupt boundaries do not become conversation turns. No task-log, conversation
log, event schema, AppModel, UI, runtime or provider behavior changes.

## Caller boundary

The caller must establish that the source belongs to the supplied `TaskSessionID`.
Events must already be the retained projection: unique event IDs in file order,
with the latest valid revision for each ID. The source coverage has no default.
Declare either the complete retained timeline or a bounded retained window.
Neither asserts complete provider history.

Use an unavailable source state for data that has not loaded, is missing, is
unreadable or has unresolved source diagnostics. An unavailable source suppresses
all supplied events, including stale cached events. The pure projection cannot
authenticate a source or detect a caller that supplies the wrong task's otherwise
valid events. The mounted caller retains that identity and custody obligation.

Duplicate event IDs, invalid existing authority/kind combinations, nonfinite
event times or an invalid preview limit make the summary unavailable. The input
source is never repaired or reordered. A new presentation-event kind must be
handled explicitly when this slice is later composed with another candidate.

## Meaning of the facts

`latestPrompt` retains prompt submission time, origin and delivery state. A
ChatGPT, phone or forwarded prompt does not establish a human's latest action.
Queued and failed submissions remain visibly queued and failed. The preview
uses the retained prompt text, and reports attachment count separately without
expanding the rendered delivery payload.

`latestOutputBlock` retains its original `occurredAt`, extraction, authority,
capture state, prompt reference and truncation flag. An output block can acquire
later revisions without changing `occurredAt`. `lastOutputUpdateAt` is therefore
explicitly unavailable under this input contract. Raw-derived text remains
raw-derived. A closed capture does not establish provider-turn completion.

Latest means last matching event in retained order, even if the clock moves
backward or several events have the same time. This follows the existing log's
ordering contract. It is not a wall-clock maximum or a proposed cross-thread
sorting policy. Absence from a bounded window remains distinct from absence
from the complete retained timeline.

Previews preserve a leading sequence of complete Swift `Character` values and
exact UTF-8 bytes. They do not normalize text, add an ellipsis or synthesize a
summary. Preview clipping and source truncation have separate flags. A zero-byte
limit suppresses text explicitly; limits outside 0...4096 refuse the projection.
The result text is byte-bounded. No total-input CPU or memory bound is claimed.

## Validation and remaining work

Prepared checks include prompt/delivery/origin distinctions, output authority,
clock regression, equal-time order, boundary exclusion, source coverage and
unavailability, duplicate revisions, invalid authority/time, UTF-8/grapheme
clipping, attachment-only prompts, invalid limits and deterministic replay.

The focused XCTest file and registered selftest checks require actual execution.
This authoring environment has no `swift` executable. No Swift compilation,
XCTest, maintained selftest, native package build or mounted acceptance ran here.
Those gates remain NOT_RUN. Source inspection is not a substitute for them.

UI timestamp reveal/settings, a role-specific last-update source, unseen cursors,
task-rail refresh scheduling, hover/focus mounting and resource acceptance remain
ordinary UX-A work. Existing task pinning stays authoritative; no new star or
priority semantics are introduced. Mounted code must retain the sidebar's narrow
refresh boundary and must prove that inspection has no runtime side effects.

Frozen #128 event/log work and #130 input-target UI work are unchanged. Their
later composition requires a new compatible source identity and checks.
