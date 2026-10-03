# Exact-file context candidates

`ContextFileSourceAdapter` binds explicit file references to physically observed
bytes before composing them with the existing Context Set compiler. It is a
Core source stage for #58/#60 Phase A. The app, runtime handoff and MainFrame
session-entry adapter do not call it in this slice.

The caller supplies an explicit root and structured references for objective
files, selected files, operator pins or required contracts. The adapter does not
parse prose for guessed paths, expand retrieval nominations, scan adjacent files,
or infer required contracts from a filename.

```swift
let batch = ContextFileSourceAdapter().observe(
    root: selectedRoot,
    requests: [
        ContextFileSourceRequest(relativePath: "README.md", origin: .objective),
        ContextFileSourceRequest(
            relativePath: "docs/design.md", origin: .operatorPin, lineRange: 3...8
        )
    ],
    observedAt: Date()
)
// Inspect observations, including every unresolved request, before handoff.
let set = try batch.makeContextSet(id: "review-context", objective: "Review the source")
```

Each successful observation carries an absolute canonical source reference, the
SHA-256 of the full source bytes, the exact represented bytes and their separate
digest, and the caller's observation timestamp. `revisionIdentity` is namespaced
as `sha256:`. It is not a Git blob, Git HEAD or receipt identity. Byte-derived
token estimates remain estimates. Persisted candidate freshness is `unknown`;
the observation does not promise that a later path read will match.

The reader anchors traversal to an open root descriptor. It rejects descendant
symbolic links, including links to another file inside the root, and reuses
Explorer's excluded-name policy. A link used as the root itself is rejected;
ancestor aliases of the explicitly selected root are canonicalized. Paths are
exact relative descendants: empty components, `.` and `..` are refused rather
than silently normalized.

Files must be regular UTF-8 files within the per-file and total byte limits. The
reader compares two bounded read passes, file identity, size and modification
state, and checks that the named root, ancestors and file still bind the observed
objects. Observable mutation or replacement produces a failure. This detects
the exercised races; it is not an atomic filesystem transaction, permanent
freshness guarantee, or proof against a writer restoring all observable state.

Line selections are one-based and delimited by LF. CR bytes and terminators are
preserved. An empty file has line 1; a trailing LF adds an empty final line. Every
requested line must exist. There is no partial excerpt disguised as a complete
selection. Distinct exact ranges use the existing compiler's structural
source/revision/range identity, including when two ranges have equal bytes.

The batch exposes failures and unresolved requests. Missing, stale-expected,
oversized, malformed or unsafe sources produce no admitted candidate. A
completed read that fails UTF-8, expected-identity or line-range checks retains
its observed source digest as negative evidence. A failed mutation check makes
no hash claim about a complete stable read. Full-file byte budget is reserved
before each distinct read, including a read that subsequently fails. Duplicate
references share one bounded file read. Limits apply to unique source bytes; two read
passes and EOF probes use additional bounded physical I/O.

`makeContextSet` refuses any incomplete batch. This includes unresolved objective
references, pins and contracts, so available candidates cannot silently become
a complete handoff. The caller can inspect partial results, but must resolve
the failure or explicitly revise the request. Pins remain source-backed items
with an operator-pin reason. The existing compiler merges reasons and aliases,
keeps pins mandatory, and reports hard-context budget conflicts. Its existing
manifest delivery metadata does not establish provider input, turn delivery or
worker acceptance.

Observation batches encode for receipts but do not decode into active handoffs.
A serialized observation does not replay read authority; a fresh `observe` call
is needed to construct another complete batch.

## Source-stage inventory

| Source stage | Current boundary |
| --- | --- |
| Explicit objective, selected, pinned and contract file references | This adapter physically reads exact bounded bytes and composes complete batches with the existing compiler. |
| Lexical search and authored links/backlinks | Explorer indexes and search/link helpers exist; their exact source candidate adapter remains adopted actionable work. |
| Git changes, untracked and conflicted files | Read-only Git inspection exists; the candidate adapter and cross-source identity reconciliation remain actionable. |
| Task artifacts, qualification/test receipts, PRs/issues, prior snapshots, task/runtime and lifecycle/project records | Existing references and observations are not proof that all source adapters are implemented. These remain separate adopted source stages. |
| MainFrame staged entry/resume | The system adapter is gated on the upstream MainFrame entry authority. This exact-file slice does not satisfy it. |
| Semantic retrieval | A nomination is not read authority. Expansion and source reconciliation retain their separate governing gates. |

## Verification and promotion

The maintained XCTest suite covers actual temporary files, changed/deleted
sources, malformed inputs, byte/request limits, symlink and outside-root
refusals, exact line ranges, reason union, collisions and deterministic ordering.
It physically interposes same-length writes, replacement, deletion, truncation,
ancestor/root changes and link substitution between read passes. The selftest
covers the public adapter and compiler composition without that internal
interposition point. The owner pressure protocol preserves its first apparatus
compile failure and separately identified successor.

Owner checks and hosted CI qualify only their executed boundaries. Independent
qualification, mounted product composition, runtime delivery and installed-app
qualification are separate gates. D-072 remains a proposed architecture note.

> **Binds:** consideration of this adapter for the adopted #58/#60 source stage.
>
> **Tier:** T0, proposed architecture guidance.
>
> **Check:** deterministic tests check read and composition behavior; they do not enforce adoption, useful independence or product acceptance.
>
> **Escape:** incomplete observations refuse handoff; unavailable qualification or upstream authority remains explicit while other source stages continue.
