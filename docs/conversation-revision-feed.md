# Conversation revision feed

`conduit_session_events` keeps its `v1:<index>` timeline cursor. That cursor is
a presentation position: when an earlier event is revised (a queued prompt
becomes delivered, live output closes), the event keeps its position and the
cursor does not move. A reader that has advanced past the event never sees the
revision through the timeline.

The revision feed adds a second, opt-in cursor over the durable conversation
log so an independent reader can follow every retained revision, tell what
kind of source it is reading, and recover text the page shortened.

Plan context: [T3 Code adoption plan](plans/t3code-adoption.md), Step 1.
Decision: D-077.

> **Binds:** Session API consumers of `conduit_session_events` and Core callers of `ConversationEventLog.readRevisions()`.
> **Tier:** T1, detected: Core tests and self-test checks exercise the cursor, coverage and expansion contract.
> **Check:** `ConversationRevisionFeedTests`, `runConversationRevisionFeedChecks` in `conduit-selftest`.
> **Escape:** a reader that receives `invalid`, `reconcile_required` or `unavailable` keeps its applied state and restarts from an empty `changes_since`; nothing in the feed grants task, runtime or provider authority.

## Requests

All new arguments are optional. A request without them returns the same v1
page as before, plus two additive booleans on each event record.

| Argument | Meaning |
| --- | --- |
| `changes_since` | Revision cursor from `changes.next_change_cursor`, or `""` to start at the beginning of the durable log. |
| `change_limit` | Distinct changed events per page. Default 20, maximum 50. |
| `expand_event_id` | Event whose complete redacted text to return in slices. |
| `expand_offset` | Character offset to continue from. Default 0. |
| `expand_limit` | Characters per slice. Default 8,000, maximum 32,000. |

## Change feed

The feed reads only the durable log. Each valid JSONL record is one applied
revision with a 1-based `revision_sequence`. Several revisions of one event
inside a page coalesce into one record valued at the last of them, so a
streamed output with thousands of deltas uses one slot. Each record also
carries its `timeline_cursor` (the unchanged `v1:` position), `event_revision`
(how many valid revisions that event has had), `first_seen_in_page` and the
log's own `recorded_at`.

A cursor reads `r1:<sequence>:<byte offset>:<sha256 of that byte prefix>`. It
binds the exact bytes it covers. Append-only operation never changes them, so
a presented cursor is checked before any page is served:

| State | When | Reader action |
| --- | --- | --- |
| `ok` | Prefix, boundary and record count match. | Apply `records`, then store `next_change_cursor`. |
| `invalid` | Not the canonical form. | Restart from `""`. Nothing is silently reset. |
| `reconcile_required` | `source_shorter_than_cursor`, `prefix_digest_changed`, `prefix_record_count_changed` or `cursor_not_at_record_boundary`. | Restart from `""`; `head_change_cursor` shows the current head. |
| `unavailable` | The log could not be read. | Keep the cursor and retry later. |

`next_change_cursor` covers exactly the records returned, so a reader that
stores it only after applying them cannot skip a revision. The final page
covers through the last complete line, including rejected lines after the
last applied record, so each rejected line is reported once.

A trailing record without its newline is projected by the timeline but is
not delivered by the feed until the next append terminates it.

### Catch-up and the live timeline

When a runtime is live the timeline comes from memory and can be ahead of the
log. The handler reads the durable log before choosing the timeline, so the
returned `head_change_cursor` is never ahead of the timeline in the same
response. Catching up from that head can deliver a revision the timeline
already showed; applying it again is harmless. It cannot skip one.

`ConduitSessionChangeReplica` is the reference consumer: it applies a page
only when the page was read from its current cursor and advances only after
applying. A page from a cancelled or superseded reader is refused as
`staleSince` and cannot overwrite newer state.

## Source coverage

| Coverage | Meaning |
| --- | --- |
| `complete` | Every record was applied. |
| `partial` | At least one record was rejected (torn, malformed, wrong task, invalid authority or invalid revision). |
| `empty` | The log exists with no records. |
| `missing` | No log exists. Its cursor is the empty-prefix origin, which matches once the log appears. |
| `unreadable` | The log could not be opened or read. |

Coverage describes Conduit's retained log, not provider history. `timeline_source`
reports whether the page came from the live runtime, cached history or the
durable log, with the durable coverage when the log was read for the request.

`ConversationEventLog.read()` is unchanged: a missing and an empty log both
read as no events and no diagnostics. `readRevisions()` keeps them apart.

## Text expansion

`truncated` keeps its meaning (either cause). Two additive fields separate the
causes: `text_capped` means Conduit's export cap shortened `text`, and
`source_truncated` means the retained value was cut when captured. Only the
first is recoverable.

A capped record carries `full_text_sha256` and `text_continuation_offset`.
Expansion slices count Characters (extended grapheme clusters) of the redacted
text, so no slice splits a user-perceived character. Concatenating slices from
offset 0 until `complete` reproduces the text whose SHA-256 is
`full_text_sha256`. A different digest means the event was revised between the
page and the expansion. Redaction is applied to the whole text before slicing,
so the page's capped text is an exact prefix of the expansion.

## Limits

- The feed and its sequence describe Conduit's durable log. They cannot invent
  a provider's native event identity or prove that identical upstream payloads
  are duplicates.
- Coalescing is a projection for transport. It does not delete or compact the
  log; every retained revision stays readable from an earlier cursor.
- Cursors are unauthenticated query positions. They prove nothing about what a
  client applied.
- No reader path launches, resumes, prompts or reconnects a runtime.
- Each request reads the whole log once and hashes up to three prefixes. Large
  logs cost proportional I/O; no index or sidecar is introduced.
- Mounted, installed-app and hosted-client behaviour were not exercised by the
  source tests.
