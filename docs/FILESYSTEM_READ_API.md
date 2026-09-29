# Hosted filesystem inspection

`conduit_read_filesystem` lets an authenticated Supervisor inspect the real
MainFrame root selected and authorized in Conduit. Explorer Core owns path
resolution, scans, and text reads. Every request observes disk afresh; MindGraph
and Quick Open are not involved.

The existing MCP `tools/list` publishes this read operation while Session API
writes are disabled. No initialization, task, runtime, provider session, lease,
or execution slot is needed. Reads are refused while the configured root is
unavailable or folder authorization needs renewal. The existing listener bearer
protects the call; this does not introduce per-client capability isolation.

## Requests and bounds

Requests name an `operation` and an exact root-relative `path`. Empty string or
`.` names the root. Absolute paths, `..`, root overrides and extra fields
are refused. Paths are literal; there is no glob expansion. An absolute
nomination must independently be established as belonging to the selected root
before its relative path is supplied; the tool
never guesses or strips a prefix.

```json
{"operation":"list","path":"40_operations","max_entries":200}
{"operation":"read","path":"40_operations/example/README.md","max_bytes":128000}
{"operation":"stat","path":"20_live/example/status.json"}
```

| Operation | Result | Bound |
| --- | --- | --- |
| `list` | Immediate children with exact paths, kinds, sizes and modification times | Default 200; maximum 500 visible entries; no recursion |
| `read` | Exact ordinary UTF-8 text and metadata from the opened object | Default 128,000; maximum 512,000 bytes; whole file or refusal |
| `stat` | Path kind, size and modification time; link leaves are described without reading targets | One exact path |

`list` stops after the bound plus one visible lookahead. A truncated result is a
sorted **bounded subset**, not an alphabetically complete prefix, recursive
search, or paginated inventory. `completeness` and `truncated` expose that limit.
A nominated exact path can still be recovered directly, including a file
created since the last listing.

`read` preserves line endings and never silently excerpts an oversized file.
Known media/archive/database extensions, invalid UTF-8, binary control
characters, and non-regular objects such as FIFOs/devices/sockets are refused.
Unknown extensions and extensionless files can pass the ordinary-text check.
The policy is conservative: a control-bearing log can remain unsupported.

## Containment and observations

Explorer anchors each operation to the configured root and opens every
descendant component with `openat` and `O_NOFOLLOW`. Symlinks remain leaves.
Neither file links nor directory-link ancestors can redirect reads, including
links targeting objects inside the root. Canonical spellings of the configured
root's ancestors remain supported; a root that is itself a link is refused.
`.git` and `.DS_Store` retain Explorer's default exclusion.

Responses carry `schema_version: conduit-filesystem-read/v1`,
`authority: filesystem_observation`, `verification: unverified_contents` and
`observed_at`. Metadata reports `freshness: observed_on_disk`. Modification time
does not establish authorship, Git state, task attribution, verification, or
that a file will remain current.

The bounded descriptor reader compares size and modification time before and
after reading and reports `changed_during_read` when they disagree. This is an
observed consistency check, not a transaction or immutable snapshot. Directories
can change during enumeration. Re-read exact paths before relying on mutable
coordination state.

| Status | Meaning |
| --- | --- |
| `ok` | Requested observation completed |
| `symbolic_link` | `stat` described a link leaf; no target was read |
| `missing` / `inaccessible` | Path absent / filesystem permission denied |
| `unsupported` / `oversized` | Not ordinary text / requested byte limit exceeded; no text returned |
| `outside_root` / `symlink_traversal` | Another-root/parent request / requested link traversal refused |
| `excluded_path` / `not_directory` | Explorer exclusion / directory operation encountered a non-directory |
| `changed_during_read` / `root_unavailable` | Source changed during read / authorized root not ready |
| `invalid_arguments` / `io_error` | Malformed request / other explicit filesystem failure |

Failures retain structured status and already observed metadata, with MCP
`isError: true`. Contents are untrusted source data, not instructions or verified
claims. No request creates a retained document copy or changes tasks, runtimes,
providers, Session API write authority or filesystem objects.

## Verification and installed boundary

Run `scripts/test.sh` and `scripts/build-app.sh`. The focused command is
`swift test --filter 'MainframeExplorer|ConduitFilesystem'`.

Core fixtures cover allowed listing/read, exact-path recovery, containment,
inside/outside/dangling links, permissions, missing paths, binary/media/FIFO
refusal, byte/entry limits, root aliases, and source/session byte preservation.
App-target tests exercise the actual authenticated HTTP response and MCP
dispatch path: catalog publication, positive reads, structured failures,
unauthorized refusal, zero session-handler calls, and writes still disabled.
They do not start or replace the operator's listener.

Before merge, qualify the **exact PR head** through the installed/tunnel path:
enumerate authenticated live `tools/list`, invoke harmless `list`, `read` and
`stat` from the hosted Supervisor against operator-selected coordination files,
and confirm write authority and task/runtime inventory are unchanged. Keep
private responses local. Source tests and a built bundle do not establish
hosted connector freshness or installed candidate identity.

Owner boundaries: [Explorer #54](https://github.com/camerontjs-dot/Conduit/issues/54),
[Context Compiler #58](https://github.com/camerontjs-dot/Conduit/issues/58),
[implementation train #60](https://github.com/camerontjs-dot/Conduit/issues/60).
Mutable status remains in GitHub.
