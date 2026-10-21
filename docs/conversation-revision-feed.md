# Conversation revision feed

`conduit_session_events` keeps its `v1:<index>` timeline cursor. That cursor is
a presentation position: when an earlier event is revised (a queued prompt
becomes delivered, live output closes), the event keeps its position and the
cursor does not move. A reader that has advanced past the event never sees the
revision through the timeline.

The revision feed adds a second, opt-in cursor over the durable conversation
log so an independent reader can learn of every retained change, including
revisions of events behind its timeline position, tell what kind of source it
is reading, and recover text the page shortened. The feed returns each changed
event's latest value; it does not serve the intermediate values a streamed
output passed through.

Plan context: [T3 Code adoption plan](plans/t3code-adoption.md), Step 1.
Decision: D-077.

> **Binds:** Session API consumers of `conduit_session_events` and Core callers of `ConversationEventLog.readRevisions()`.
> **Tier:** T1, detected: Core tests and self-test checks exercise the cursor, coverage and expansion contract.
> **Check:** `ConversationRevisionFeedTests`, `runConversationRevisionFeedChecks` in `conduit-selftest`.
> **Escape:** a reader that receives `invalid` or `reconcile_required` keeps its applied state and restarts from an empty `changes_since`; on `unavailable` it keeps its cursor and retries. Nothing in the feed grants task, runtime or provider authority.

## Requests

All new arguments are optional. A request without them returns the same v1
page, with additive fields only: every record gains `text_capped` and
`source_truncated`, a capped record also gains `full_text_sha256` and
`text_continuation_offset`, and the app adds a top-level `timeline_source`.
No existing field changes meaning.

An older Conduit ignores the new arguments and omits `changes` and
`expansion`. A client must read a missing `changes` block as "not
supported", not as "nothing changed".

Arguments are validated, never silently dropped. A number that is
fractional, non-finite or outside the integer range reads as absent instead
of terminating the app. A `changes_since` or `expand_event_id` sent with a
non-string type is reported as invalid or not found, and a malformed
`expand_offset` as `invalid_offset`. JSON null reads as omitted.

| Argument | Meaning |
| --- | --- |
| `changes_since` | Revision cursor from `changes.next_change_cursor`, or `""` to start at the beginning of the durable log. |
| `change_limit` | Distinct changed events per page. Default 20, maximum 50. |
| `expand_event_id` | Event whose complete redacted text to return in slices. |
| `expand_offset` | Character offset to continue from. Default 0. |
| `expand_limit` | Characters per slice. Default 8,000, maximum 32,000. |

## Change feed

The feed reads only the durable log. Each valid JSONL record is one applied
revision with a 1-based `revision_sequence`. A page consumes revisions in
write order until it has `change_limit` distinct events, so a streamed output
with thousands of deltas uses one slot. It returns one record per changed
event, carrying that event's latest retained value and the
`revision_sequence` of that value, which can be later than the page's
`next_change_cursor`. A later page may therefore repeat a value; apply records
by `revision_sequence`, newer wins. Each record also carries its
`timeline_cursor` (the unchanged `v1:` position), `event_revision` (how many
valid revisions that event has had), `first_seen_in_page` and the log's own
`recorded_at`. Change records omit `turn_status`: it describes the live
runtime's current turn, not a retained revision. Use the page's `turn`
snapshot for that.

Values come from the request's single read of the log. A page never re-reads
or re-projects a prefix.

A cursor reads `r1:<sequence>:<byte offset>:<sha256 of that byte prefix>`. It
binds the exact bytes it covers. Append-only operation never changes them, so
a presented cursor is checked before any page is served:

| State | When | Reader action |
| --- | --- | --- |
| `ok` | Prefix, boundary and record count match. | Apply `records`, then store `next_change_cursor`. |
| `invalid` | Not the canonical form. | Restart from `""`. Nothing is silently reset. |
| `reconcile_required` | `source_shorter_than_cursor`, `prefix_digest_changed`, `prefix_record_count_changed` or `cursor_not_at_record_boundary`. | Restart from `""`; `head_change_cursor` shows the current head. |
| `unavailable` | The log could not be read. | Keep the cursor and retry later. |

`next_change_cursor` covers exactly the revisions the page consumed, so a
reader that stores it only after applying the page cannot skip one. The final
page covers through the last complete line, including rejected lines after the
last applied record, so each rejected line is reported once.

A trailing record without its newline is projected by the timeline but is
not delivered by the feed until the next append terminates it.

### Catch-up and the live timeline

The safe way to hold revision-complete history is to page the feed from `""`;
the feed is its own snapshot. `head_change_cursor` marks the durable head at
read time.

When the feed is requested, Conduit reads the durable log before it
chooses the timeline. With no live runtime it then serves that fresh read as
the timeline instead of the app's cached copy, which can lag the log while an
exited runtime's tab stays open. In that case the head cursor and the
timeline describe the same bytes.

A live runtime's in-memory timeline is normally ahead of the log, because the
app records each revision in memory before appending it. Catching up from the
head can then deliver a revision the timeline already showed, which is
harmless. The guarantee is only as strong as that write order: a runtime that
started from stale history would lack revisions the log has. A reader that
needs revision-complete history should page the feed rather than combine a
live timeline with the head cursor.

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
page and the expansion.

Expansion returns the redacted text, not the captured bytes: secrets and
reasoning lines stay replaced by `[redacted]` and `[redacted-reasoning]`.
Redaction runs over the whole text before any cap or slice, so the page's
capped text, without its trailing `\n[truncated]` marker, is an exact prefix
of the expansion. It repeats until nothing
changes, because one replacement can expose another token (a combining mark
left after `]` creates a word boundary). At most eight passes run. When the
eighth pass still changed the text, another token may have just been exposed,
so the whole text is replaced by `[redacted-withheld: redaction did not
settle]` with `redacted: true`. The page record, change record, expansion and
`sanitizeText` all use the same result, so none of them returns a partly
redacted remainder, and the cost stays bounded. The earlier export sanitized twice,
which caught that case by accident; it also sometimes redacted its own
`[truncated]` marker when the cut fell after a key name. The new export does
not touch the marker.

## Limits

- The feed and its sequence describe Conduit's durable log. They cannot invent
  a provider's native event identity or prove that identical upstream payloads
  are duplicates.
- Coalescing is a projection for transport. It does not delete or compact the
  log, and every revision stays in the file, but the feed serves latest
  values only: an earlier cursor returns the current value of each event
  changed since, not the value it had then.
- Cursors are unauthenticated query positions. They prove nothing about what a
  client applied.
- No reader path launches, resumes, prompts or reconnects a runtime.
- Each feed request reads and decodes the whole log once, and hashes up to
  three prefixes, on the app's main actor, as plain durable timeline reads
  already did. Large logs cost proportional time; no index or sidecar is
  introduced.
- Expansion redacts and hashes the event's whole text on each slice.
- Text whose redaction has not settled after eight passes is withheld in full,
  including the ordinary text before the first key. Seven chained keys still
  settle; eight do not, even though the eighth pass may have removed the last
  one.
- Already true before this change and not altered by it: structured adapter
  output is appended in full on every delta, so a long streamed reply makes
  the log grow with the square of its length; a delta record is applied to the
  last valid value without checking which revision it was computed from (no
  production writer emits deltas today); and without the feed, a plain read
  can serve cached history that lags the log while an exited runtime's tab is
  open.
- Mounted, installed-app and hosted-client behaviour were not exercised by the
  source tests.
