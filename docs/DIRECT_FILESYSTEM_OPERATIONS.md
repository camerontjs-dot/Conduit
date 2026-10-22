# Direct bounded filesystem operations

This source slice implements one exact UTF-8 file create or replacement for the
ChatGPT-first Local Operator direction in [#51](https://github.com/camerontjs-dot/Conduit/issues/51#issuecomment-6158659475).
It adds durable operation identity to the exact-file/conflict model used by
[Explorer #54](https://github.com/camerontjs-dot/Conduit/issues/54). It does not
establish installed-app or fresh-ChatGPT acceptance.

## Write and status contracts

`conduit_write_file` is a **write** tool. Its exact arguments are:

| Argument | Contract |
| --- | --- |
| `operation_id` | 1–128 ASCII characters from `A–Z`, `a–z`, `0–9`, `_`, `-`; keep the same ID when retrying the same operation. |
| `project_slug` | Exact registered project identifier, 1–128 UTF-8 bytes. The application resolves and authorizes it. |
| `path` | Literal project-relative file path, at most 4,096 UTF-8 bytes and 64 components. |
| `text` | Requested exact new UTF-8 text, including any intended BOM and line endings; 0–512,000 bytes. |
| `expected_absent` | `true` for creation; cannot appear with `expected_sha256`. |
| `expected_sha256` | Lowercase 64-digit SHA-256 of the exact existing raw file bytes for replacement; cannot appear with `expected_absent`. |

Extra fields, root overrides, absolute paths, parent or dot components, empty
components, NULs and unsupported text/control bytes are rejected. New content
is encoded exactly as supplied; the service does not normalize line endings,
strip a BOM or infer an encoding conversion.

Use `conduit_read_filesystem` to obtain the current bytes' SHA-256 before a
replacement. A successful read is an observation at that time. The write
rechecks the current file before acting; a historical read receipt does not
give authority to silently overwrite a newer file.

The read tool's path is relative to the configured MainFrame root; this write
tool's path is relative to the exact project. Establish the project's root
location through filesystem observation when forming the read path. Search
results likewise use project-relative paths and hashes of observed source bytes.

Creation example:

```json
{
  "operation_id": "create-summary-1",
  "project_slug": "example-project",
  "path": "outputs/summary.txt",
  "text": "Observed result\n",
  "expected_absent": true
}
```

The containing directory must already exist. This slice does not recursively
make directories or provide rename, move, copy, delete, glob replacement or a
shell escape. Search is the separately bounded `conduit_search_files` tool.

`conduit_file_operation_status` is a **read** tool taking only `operation_id`
and `project_slug`. It returns a retained operation receipt, not a new file
observation. A status lookup and an exact replay never create receipt storage,
write a target file or consume another write admission.

## Authority and protected paths

The Session API authenticates the request and supplies an exact, unique,
authorized project root. The MainFrame root itself is not an eligible project.
The request cannot select another root or state directory. The service calls
the existing write/resource admission gate only after strict argument, path,
idempotency and current-byte preflight checks. A duplicate operation is looked
up before another admission is requested. A second app process racing to
create the first store can consume an admission and then discover the existing
receipt; it still does not execute the operation again.

The current shared bearer/caller label is not independent authentication for
each ChatGPT client. This service adds no stronger client identity claim.

The initial editable-path policy is deliberately narrow:

- Hidden path components are refused, including `.git`, `.agents`, `.codex`,
  `.aws`, `.env` and their children.
- `AGENTS.md`, `CLAUDE.md` and `HARNESS.md` are refused case-insensitively in
  any path component.
- Known binary/media formats, non-UTF-8 files, NUL/control-byte content,
  directories, special files and oversized content are refused.
- Existing files must be writable and owned by the application user, have one
  hard link, and carry no setuid/setgid mode bits. On macOS, filesystem flags,
  extended ACLs and every extended attribute except the exact
  `com.apple.provenance` name are refused. Staging also refuses unsupported
  inherited metadata.

The OS-supplied `com.apple.provenance` value is treated as opaque bytes, with a
4,096-byte limit for its value and the complete attribute-name list. The service
checks the complete list before and after reading the value; errors, truncated
lists, additional attributes and observed changes refuse the operation. Absence
and a present empty value are distinct observations. A replacement preserves an
existing value on its staged inode and verifies exact readback before flushing;
a setter's success return alone is insufficient. If the source lacks this
attribute, the writer retains any OS-supplied value on the new inode. It never
removes or strips an attribute. An unsupported or unpreservable value is a
refusal, not permission to discard metadata.

These exclusions describe this feature's support boundary. They are not a
classifier for every possible credential, policy or consequential source file.
An allowed filename is not an assertion that its contents are harmless. Broader
operator-control mutation requires a separately designed authority surface.

Path resolution reuses Explorer's root validation, then uses held directory
descriptors and `openat`/`O_NOFOLLOW` for every relative component and file.
The service rechecks parent identity before commit. A symlink cannot nominate
an arbitrary outside file. The operating system's ordinary file permissions
still apply; this is not a general process or operating-system sandbox.
The canonical project path is also reopened and matched to its original
device/inode identity before staging/commit. Moving the entire root, replacing
it with another directory or redirecting its canonical path through a symlink
does not leave the previously held root descriptor as sufficient authority.

## Commit and conflict behavior

Creation stages the bounded bytes in the checked containing directory and
publishes with an exclusive `linkat`. If another writer creates that name,
creation fails without replacing its file. The temporary link is removed and
the containing directory is flushed before the success receipt is saved.

Replacement checks raw bytes and file identity before admission and again
before commit. It preserves the observed preimage in private receipt storage,
stages the new bytes, preserves owner/group and POSIX permission bits, and
commits through descriptor-relative `renameat`. A known stale precondition or
observed parent/file change refuses the operation. Adjacent user files are not
edited, and the service never commits, resets, stashes or cleans Git state.

**Replacement is optimistic concurrency, not an atomic compare-and-swap
against an uncooperative external writer.** A writer can change the destination
after the final check and before `renameat`; a directory can also move during
that interval. Held descriptors continue to identify the already-opened
directory object. The preserved preimage contains the bytes actually observed
during preflight, not any possible external bytes written after the last
observation. This source slice must not be described as preventing every
external race. A stronger replacement protocol needs a separate implementation
and qualification decision.

After commit, the service checks the named file identity, bounded bytes and
opaque provenance against the final staged observation. A changed postcondition or unconfirmed
durability produces `unknown`, with the mutation observation and receipt
reason, rather than success or an automatic retry. Unsaved human editor
buffers are not disk bytes; this service neither inspects nor mutates UI
selection, focus or drafts. Their own save path must continue detecting
external conflicts. Git dirtiness is not silently discarded: replacement
requires the caller's exact expected on-disk bytes and retains that preimage.

## Durable receipts and recovery

The application injects a private receipt directory outside the target project.
Its parent must already exist. The service creates the directory with owner-only
permissions only after a new write is admitted, and never changes permissions
on an existing directory. File content is not embedded in the public receipt;
the bounded before-byte copy stays in this private directory.

The service opens and retains the state parent before admission, then uses
descriptor-relative `openat`/`mkdirat` for the receipt directory. It rechecks the
parent's configured canonical path and device/inode identity after admission;
an observed store is also retained by descriptor and identity. Redirecting the
parent or replacing that store during admission refuses the operation before
reservation, preimage or target staging. Every admitted store open flushes the
containing parent before an intent can be recorded, including a first creation
by a racing process. Flushing only the new receipt directory would not establish
durability of its own directory entry in that parent.

Each admitted operation reserves its ID before target staging, then persists
an intent. The fingerprint binds the project slug, canonical root path and
device/inode identity, literal path, expected precondition, new byte count and
new SHA-256. Reconfiguring a project root cannot make an old ID write to a new
location. Conflicting reuse refuses without changing files.

The intent and outcome are written through exclusive temporary files, flushed,
then atomically renamed and directory-flushed. Independent reservation markers
keep a missing outcome receipt from appearing to be a new operation. Corrupt
receipts, missing reserved receipts or an interrupted intent refuse reexecution.
An interrupted intent returns `unknown`: target mutation may already have
occurred. The receipt records the project-relative staging name so an operator
can inspect a possible leftover without guessing. Recovery does not silently
delete that staging file or replay the operation.

Retained JSON must also satisfy the versioned operation-state contract. Unknown
state names, inconsistent success/refusal/intent outcomes, missing or malformed
hash/size pairs, and request fields that disagree with the reserved fingerprint
are corrupt receipts. Successful decoding alone does not turn them into trusted
outcomes; mutation and lookup both preserve an unknown historical disposition.

Receipts distinguish `succeeded`, `refused` after a persisted intent and
`unknown`. Argument/path/precondition/admission refusals before a durable intent
are immediate responses and do not reserve an ID. `before_bytes_preserved`
becomes true only after the before-byte file was successfully flushed. A
completed receipt's hashes describe its historical observations; use another
read to establish current file bytes.

`current_call_mutation_observed` describes only the current call. A receipt
retrieval failure is not evidence that an earlier admitted operation did
nothing: missing/corrupt/unavailable receipt results report
`mutation_observed: null`, `mutation_possible: true` and an unknown historical
outcome, while separately recording that this call made no target mutation.

The default cap is 1,000 retained operation IDs, with a hard 32 MB storage budget,
a 32,768-byte receipt limit and a 512,000-byte content limit. New operations are
refused when capacity is reached. IDs and old preimages are not silently pruned.
Interrupted temporary files count toward the budget. Storage loss of the entire
state directory is outside this persistence guarantee; restore preserved state
and inspect files before submitting replacement IDs. A future retention/export
operation must explicitly preserve or retire retry authority.

## Development verification boundary

`ConduitFilesystemMutationTests` uses real disposable files for exact create and
replace, raw BOM/CRLF identity, preserved preimages/mode, adjacent-file safety,
current-byte refusal, concurrent creation, symlink/parent/entire-root swaps, protected
paths, unsupported types, read-only/hard-linked files, admission refusal,
concurrent same-ID instances, restart replay, root remapping, interrupted intent,
missing/corrupt/oversized/nonregular receipts and reservations, state-parent and
store-directory rebinding, opaque system-provenance preservation, metadata added
during admission, metadata refusal and retention capacity. The real macOS
fixtures do not assume that arbitrary or empty values can be assigned to
`com.apple.provenance`; the OS may return success while retaining its existing
value. A module-internal
parent-flush fault fixture uses real directories and injects a flush failure to
check that no intent, preimage or target staging occurs; this is an ordering and
refusal test, not a simulated power-loss qualification.

These are source development tests. Native macOS execution, integration with
the authenticated HTTP/MCP write gate, an actual connected ChatGPT loop,
installed-app noninterference and independent qualification require their own
exact receipts. Their results belong in the owning issue/PR; this document does
not convert unrun checks into acceptance.
