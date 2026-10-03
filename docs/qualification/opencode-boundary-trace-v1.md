# OpenCode boundary trace source qualification

The adopted next action in [#76](https://github.com/camerontjs-dot/Conduit/issues/76#issuecomment-5851111055)
is to instrument the Conduit adapter between local delivery, the HTTP prompt
response and exact provider observations at target four. D-077 remains
Proposed/T0. This document describes the source boundary; a later provider
experiment must freeze its own candidate, protocol and oracle.

`OpenCodeHTTPClient` owns one `OpenCodeBoundaryTrace`. `TerminalRuntime`
supplies its declared task session, runtime and runtime attempt. An absent
task session remains UNKNOWN. The client exposes a read-only in-process
snapshot and adds no UI, API, listener, file store or telemetry destination.

The measured local sequence is delivery, Task scheduling, Task entry, the
call to `URLSession.data(for:)`, then its response or thrown transport error.
One recorder-issued local UUID follows that invocation. Foundation's internal
redirects, retries, individual wire attempts and provider acceptance are not
observed by this boundary. The existing endpoint, JSON body, model, auth,
timeout and HTTP error-text behavior remain in the client.

SSE metadata is a separate observation stream. All supplied session identity
fields must agree exactly with the bound session. Supplied message and part
fields must also agree and satisfy their identifier kinds. Provider identifiers
are capped and exported as kind-tagged SHA-256 digests; this is an exact
discriminator, not authentication. Stop and rebind invalidate stream epochs
and local callback tickets. Missing, conflicting, foreign, malformed and stale
inputs produce finite refusals. The existing effect mapper remains unchanged.

Exact-session busy/idle reports, message snapshots, assistant completion
reports and tool-part states carry UNKNOWN provider turn identity and
freshness. SSE carries no local delivery UUID. Repeated reports are retained
as unsequenced reports; proximity to a send never supplies a join. HTTP 2xx,
provider completion and tool completion therefore provide no task completion,
verification or objective acceptance.

The recorder retains at most 256 records and 32 local request stages. Validated
provider identifiers have at most 128 UTF-8 bytes. Counters expose record,
request and clock loss. `completeRetention` describes those counters only; it
does not establish complete provider coverage or execution. Timing uses local
process uptime with a process clock identity and record sequence; values from
different processes have no global order. Snapshots can be encoded for owned
inspection, but decoded representation is not authenticated evidence.

## Source controls

`OpenCodeBoundaryTraceTests` exercises malformed and conflicting identities,
missing authority, stale epochs, foreign tickets, response ordering, duplicate
callbacks, replay, UNKNOWN correlation/freshness, privacy and retention limits.
`OpenCodeBoundaryTransportTests` physically calls Foundation transport through
an interceptor installed only on each owned ephemeral URLSession. Success,
HTTP 500, non-HTTP responses and thrown transport errors preserve original
bytes, response and error while checking callback order. The interceptor handles
every supplied request, so it has no provider or network fallback.

`ConduitSelfTest` includes matching bounded synchronous controls for portable
coverage. The owning issue/PR must record checks actually executed against the
exact candidate, including native failures or UNKNOWNs; authored tests alone
do not qualify a candidate. Complete actual source files are required for local
closure fixtures; substitute definitions cannot establish product wiring.

## Remaining qualification

Full native tests/build/package, fresh independent review where required and
the actual target-four experiment each retain separate receipts. A source
fixture does not establish a fourth-turn cause, provider-neutral slot occupancy
or the historical fourth worker's post-close inactivity. The frozen #74
cleanup failure and #85 research lineage remain preserved. Operator state,
unrelated sessions and installed builds are outside the fixture boundary.
Real-provider cost or account impact requires its own available authority.
