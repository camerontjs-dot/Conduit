# Durable Context Set owner boundary

This slice advances #58 / #60 Phase A with a maintained Core/store API for
editable operator Context Set definitions. It preserves the already qualified
compiler representation and the existing actual-handoff snapshot store.

`ContextSetStore(directory:)` never chooses an ambient state location. Reading
a missing store creates no file. An explicit `save` with no expected revision
creates an identity; later saves require its exact current revision.
`retire` appends a tombstone retaining the definition and rules. Historical
records remain available, and a retired identity cannot be reused.

Fixed entries use the existing `ContextSetEntry` and `AgentContextItem`
authority, representation, disposition and freshness fields. Dynamic rules
retain an explicit source kind, scope and optional query. They are not run by
the store. The `compilerInput` projection keeps their unresolved prerequisites
visible and does not append retrieved entries or mark them delivered.

The complete ledger must parse and replay. Malformed/torn records, duplicate
decoded JSON members, identity collisions, unknown schema versions and wrong
revision/sequence lineage refuse read and write. Store operations neither heal
history nor adopt a valid prefix. Actual cooperating writers serialize on the
ledger inode, check its named directory/file binding and fsync each append.
Symlinks, hardlinked files, nonregular ledger nodes and nonprivate directory or
ledger file permissions are refused. An append whose custody or durability becomes
uncertain returns UNKNOWN with its attempted revision identity.

The initial owner source failed two meaningful physical controls: a refused
edit created an absent empty store, and a writer waiting on an inode later
moved out of the store returned success after appending to that old file. Both
source versions, binaries, fixtures and traces are preserved; the repaired
source handles those controls without changing either protected ledger.
An additional private-directory control preserves the first source that
accepted an existing same-UID world-writable directory, even though it created
an owner-only ledger. The repaired source requires owner-only directory
permissions and refuses without changing an existing directory's permissions.
Native Core pressure also covers restart, same-revision conflicts, two actual
distinct writers, lock-owner exit, invalid input and byte preservation.

Run `scripts/test.sh --filter ContextSetStoreTests`, the full maintained test
command and `scripts/build-app.sh` on the exact candidate. The selftest has
matching lifecycle/provenance/refusal checks. Preserve actual native process
and file traces as a separate evidence layer; repository tests and hosted CI
are not independent qualification.

The file lock is advisory. Serialization applies to cooperating Conduit
writers. The exercised replacement control detects a moved named inode; it
does not establish authenticity or protection against every same-UID actor
ignoring the lock and modifying bytes in place. A syntactically valid ledger
does not authenticate source facts, nominations or its authorship. Those
authorities remain separate, and external tamper authenticity is UNKNOWN.

The slice changes no AppModel, RootView or Session API caller. It does not
mount a Context Set editor, bind a manifest to a real worker turn, resolve
dynamic rules, evaluate retrieval quality, send context, install a build or
qualify the whole Context Compiler. Mounting depends on the qualified isolated
state root and the owning cross-surface/AppModel integration boundary. Fresh
independent qualification is required before promotion.

## Owner evidence at source freeze

The exact base is main `d10ec1c90c835e8b210a4e27e7333fd8e436bd7a`,
tree `d76aa2957d69b86b3eb2f7b17cbd5d5abfdea010`. This owner used inherited
implementation context. None of these results is an independent acceptance.

The native Core store source SHA-256 is
`71742c6249bfc89b6033902987a12140a3159deb574efc69162ae17c38d0c6ea`.
The standalone fixture binary SHA-256 is
`02ee505a21b73b051a7ff648884248d07482608d31271a82c9a1d6ff8a128d24`.
It was physically compiled with an explicit `arm64-apple-macos13` target.
The fixture invokes the maintained Core API in separate processes; it does
not emulate the store or consult a real provider.

The repaired source passed 42 physical controls across 66 native process
commands. Receipt SHA-256:
`c5f3c600cbf37f38eaade793184697cc57b1ef1222e74618fa37622aaf481dd2`.
Malformed and unsafe ledger fixtures use private directories so the directory
permission guard does not mask their intended controls. A separate moved-ledger
control passed three checks across four native processes. Receipt SHA-256:
`ad8ffa6e3c729833ed7d5936a459e5a59597c122050ea1cb451fb80e7d0ca21f`.
All qualification-owned processes exited. Their generic fixture files, native
binaries, stdout/stderr and earlier failed source snapshots remain preserved
in the local evidence archive.

The ten provider-conformance contract tests passed without invoking a provider.
The working tree and its 696-commit history passed the repository leak scan.
Full maintained native tests and the uninstalled package build are pending the
serialized owner build slot. Fresh independent qualification is NOT_RUN.
Those gates must be reconciled against this frozen candidate before promotion.
