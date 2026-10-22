# Direct command API candidate

This source candidate introduces a typed native command runner and durable
operation receipts for issue #170. **Production execution is unavailable.**
Conduit has not yet implemented an operator-granted execution profile that
enforces the intended OS authority. Enabling the Session API write switch does
not supply that authority. The application can expose the contract and read
receipts, but a new production execution receives
`execution_authority_unavailable` before write-rate admission, receipt creation
or process creation.

The internal disposable-fixture initializer exists for development tests. It
is inaccessible to the application target and cannot be selected by request
fields, settings, environment variables or a caller-provided approval boolean.
It is an ordinary native process executor with the test controller's OS
permissions. A nominated working directory does not confine filesystem access,
network access, subprocess creation or inherited OS privileges.

## Tool contract

| Tool | Classification | Inputs |
| --- | --- | --- |
| `conduit_run_command` | Write | `operation_id`, `project_slug`, `argv`; optional `cwd`, `timeout_ms`, `max_output_bytes` |
| `conduit_command_status` | Read | `operation_id`, `project_slug` |
| `conduit_cancel_command` | Write | `operation_id`, `project_slug` |

The server binds execute/status/cancel; a JSON argument cannot change the
operation. The server resolves and authorizes the exact project. Requests
cannot nominate a root, an environment, an approval profile or a shell mode.
Execute and cancel retain the existing authenticated Session API write gate.
The shared write-rate/resource callback runs after request validation,
idempotency and command-authority checks, before a new admitted operation.
Status performs no write admission or persistent recovery mutation. Lookup and
cancellation verify the receipt's canonical project-root path and device/inode
against the currently authorized root, so remapping a slug cannot expose or
stop an old root's command. Cancellation does not require the old cwd to remain
in place: the owned child can still be stopped after its cwd moves.

| Field | Contract |
| --- | --- |
| `operation_id` | Required, 1–128 ASCII letters, digits, `_` or `-`; globally unique in this store |
| `project_slug` | Required, exact nonempty slug, at most 128 UTF-8 bytes, no NUL |
| `argv` | 1–128 literal strings; at most 65,536 UTF-8 bytes including string terminators; no NUL |
| `argv[0]` | Absolute executable path, at most 4,096 UTF-8 bytes; no implicit PATH search |
| `cwd` | Default `.`; ordinary project-relative directory, at most 4,096 UTF-8 bytes; no parent/empty/dot components, excluded names or symlink traversal |
| `timeout_ms` | Default 10,000; integer 10–120,000 |
| `max_output_bytes` | Default 128,000; integer 1–524,288, independently for stdout and stderr |

`argv` is passed directly to POSIX spawn. Shell syntax has no interpretation
unless an explicitly authorized future profile permits a shell executable as
the command itself. The development tests use explicit shell fixtures only
where a disposable script is needed to produce process outcomes. There is no
agent, PTY, interactive stdin or implicit shell initialization. Stdin is
`/dev/null`; the executor supplies only a fixed PATH and LANG environment.
On macOS, close-on-exec-by-default also excludes unrelated inherited file
descriptors.

## Receipt and retry behavior

A durable receipt binds an operation ID to the full typed request, canonical
project root and working directory, and the observed device/inode identities of
those directories. Reusing an ID with changed arguments, limits, project root or
directory identity refuses without launching another process. A matching retry
returns the existing receipt and `idempotent_replay: true`. Cancellation and
completed retries do not consume new write-rate admission.

An immutable `.reserved` marker and the accepted/queued receipt are synchronized
before spawn. A reserved ID whose JSON is missing remains unavailable and
cannot execute again. Every record update
writes a private temporary file, synchronizes it, atomically renames it and
synchronizes the directory. Reads and owner writes use a pinned directory
descriptor with no-follow leaf opens and descriptor-relative atomic renames.
Creation requires an already-existing application parent outside the command
project. It creates only the private receipt leaf and synchronizes that entry
in the pinned parent before acceptance. Missing application ancestors are not
created recursively. Subsequent admission and observation refuse a renamed or
redirected parent/store; ongoing receipt updates remain attached to the
original directory descriptor. These rules prevent a path alias from quietly
moving the receipt store into a different directory.
A nonblocking store ownership lock permits one
command manager to launch from that store. Capacity is separate from agent task
capacity: two concurrent commands by default, capped at four. The store retains
at most 1,000 operations within a 64 MiB global byte budget, reserving the worst
case two-megabyte receipt growth for every active operation before accepting
another. It refuses further acceptance rather than silently deleting history.
A corrupt or unreadable existing receipt prevents reuse of its operation ID.

After any uncertain transport or persistence response, inspect the same
operation ID. Do not invent a new ID to retry execution whose outcome has not
been observed. A client never treats queued delivery, a PID or a successful
spawn as a successful command exit.

| Phase | Meaning |
| --- | --- |
| `accepted`, `queued` | Durable request claim; no exit conclusion |
| `started` | Launch attempt recorded; successful spawn still requires a PID observation |
| `running` | Native child created; exit not yet observed |
| `cancel_requested` | A cancellation request was durably accepted; cancellation is not yet established |
| `exited` | Direct child's zero exit and absence of its original process group observed |
| `nonzero` | Direct child's nonzero exit or external terminating signal observed; original group absent |
| `timed_out` | Execution deadline exceeded, termination requested, direct-child exit and original group absence observed |
| `observed_cancelled` | Cancellation observed before spawn, or owned child terminated after cancellation and original group absent |
| `launch_failed` | Native launch failed; no successful child creation reported |
| `unknown` | Missing ownership/exit evidence, persistence failure or unresolved original process group; no success inference |

Receipts retain argv/cwd, limits, acceptance/launch/end timestamps, phase
transitions, service-instance identity, PID/process group, real exit code or
termination signal when observed, and capacity-release facts. Result text is
command output, not trusted instructions or a verification judgment. Nonzero,
timeout and cancellation outcomes are returned as structured results rather
than MCP transport errors that could encourage an unsafe retry.

## Output and process boundaries

Each stream independently retains its first bounded bytes and counts all bytes
actually drained. `bytes_base64` preserves exact binary and invalid UTF-8 bytes.
`text` is present only when the retained bytes form UTF-8 without NUL;
`retained_bytes_are_utf8_text` describes those retained bytes, including any
partial UTF-8 suffix caused by the byte boundary. `truncated` explicitly marks
overflow. `reached_eof` distinguishes complete drainage from a bounded stop.
Reading continues after the retention limit so ordinary pipe backpressure does
not deadlock a producing child.

Spawn uses a dedicated process group and a descriptor pinned to the observed
working directory identity. Timeout/cancellation signals target that owned
group only while the direct child remains unreaped. After a grace period the
runner escalates to SIGKILL. It never sends signals after reaping the original
child or losing child ownership. If cleanup is not observed within its bounded
budget, the receipt becomes unknown and command capacity remains occupied.

Process groups are not a containment boundary. A command can deliberately
create a different group or session; absence of the original group cannot prove
that such descendants stopped. This is one reason the fixture runner does not
establish a production execution policy. The receipt states
`descendant_containment: not_enforced` explicitly.

## Restart semantics

Initialization and status lookup are read-only. A fresh service returns
persisted terminal receipts unchanged. For a nonterminal receipt that it does
not own, it derives `unknown` while preserving the stored historical phase and
transition list. It does not rewrite history, respawn the request, adopt a PID
or guess an exit status from later process disappearance. Cancel refuses with
`process_ownership_unavailable`. PID reuse therefore cannot turn a recovered
receipt into authority to signal another process.

An operation left by a prior manager without confirmed capacity release also
blocks acceptance of a different new operation ID. The new manager does not
reset unresolved process capacity to zero just because its in-memory table is
empty. Later PID disappearance does not release that retained uncertainty;
operator reconciliation requires a separately defined authority and evidence
contract.

## Development verification and remaining authority

The core test suite covers literal argv, separate streams, nonzero exits,
binary/overflow handling, deadlines, cancellation, concurrent same-ID requests,
capacity and store-owner contention, pre-side-effect refusals, directory
replacement, application-parent redirection, corrupt history, terminal recovery
and a macOS test-host restart.
The selftest covers the production authority refusal and read-only surface.
Executed results belong in the owning PR's exact-source verification receipt;
the presence of these tests is not evidence that they ran or passed.

Before production execution can be enabled, the owner must choose and the
implementation must enforce a bounded execution profile: which operations and
arguments can run, which filesystem/network/process effects are permitted, how
consequent local changes acquire authority, and what process containment and
cleanup can actually be observed. That work also needs independent review and
the separately authorized installed authenticated HTTP/fresh ChatGPT loop.
This candidate supplies runner behavior and honest unavailable admission; it
does not complete issue #170's production acceptance or authorize an installed
app replacement.
