# Local Operator lock-reader successor

This is a successor to frozen [Draft #133](https://github.com/camerontjs-dot/Conduit/pull/133)
under [#51](https://github.com/camerontjs-dot/Conduit/issues/51). The predecessor
head is `b5cf3e3e32dbd684d787372f39dd53f5179be4a0`, tree
`169f390d6b37bc8ffc200b8182d911d5fde92809`. D-066 remains proposed.

The predecessor's full native, package, CI and recovery checks remain evidence
within their executed scope. Subsequent source-exposed supervisor pressure
demonstrated that `records()` blocked beyond two seconds when an owned copy's
`.writer.lock` was a FIFO. The unchanged healthy control recovered both records
in 0.016 seconds. The owned blocked reader was terminated and reaped. The
[failure receipt](https://github.com/camerontjs-dot/Conduit/issues/51#issuecomment-5964899745)
is preserved; it was not independent qualification or a mounted HTTP experiment.

## Acceptance boundary

Both read and append open the lock with `O_NONBLOCK` and refuse a nonregular,
multiply linked, nonprivate or foreign-owned lock. The opened regular lock must
remain the `.writer.lock` named by the exact opened private receipt directory.
Descriptor and named directory/lock identities are checked around nonblocking
flock acquisition and before returning a result. Missing read state is not
created or repaired. Busy locks return unavailable; shared reads remain reads,
and stale/duplicate revisions cannot replace immutable records.

This changes lock availability and identity checks only. Boundary/mode,
authorizer, expected revision, exact task/attempt/operation identity, protected
files, record validation and acceptance semantics retain the predecessor's
contract. A filesystem conflict is unavailable evidence, not a new writer grant.
It does not establish authenticated custody against another process of the same
OS user, an atomic filesystem transaction, Shell command safety, task completion
or objective acceptance. A concurrent append may leave preserved bytes if an
external rename is detected after the write; the error must not imply rollback.

## Evidence burden

Owner controls must physically exercise healthy recovery, malformed FIFO reads
and append attempts, directory/symlink/hardlink lock objects, nonprivate state,
missing read state, distinct-process lock contention, stale revision and replay.
Opened lock/directory replacement is also tested against actual held descriptors.
Healthy original receipt and unrelated protected bytes remain unchanged; negative
objects and output are retained. A timeout is a failure, not a refusal or pass.

An early small native probe may compile the exact changed primary Core file
against all candidate Core source and link unchanged predecessor Core objects.
That is a bounded mechanical control with explicit source/object custody. It
does not replace full candidate SwiftPM, native XCTest/selftest, maintained
release/package, CI or fresh independent qualification gates.

## Executed owner checks

The successor's full native owner check passed 490 selftests, 10 Python contract
tests and 644 XCTest cases, with three existing installed/provider opt-in cases
explicitly skipped and no failures. All 40 Local Operator cases ran. The app and
server rebuilt against the changed Core source. The maintained release and
uninstalled package passed signing, resource and macOS 13 metadata checks;
the release selftest passed all 490 checks. The initial manifest-sandbox failure
is retained with tests not run, followed by the separately recorded native run.

A distinct-process native probe also passed 24 healthy, malformed-state,
contention and revision controls. That early probe used the exact changed
primary file and 95 source-identical predecessor Core objects; it has its own
source/object custody receipt. The full native run subsequently rebuilt the
candidate without substituting those objects. Both receipts are owner evidence.
The frozen predecessor's FIFO failure remains a failure.

Exact source identity, receipt hashes, executed checks and remaining gates are
recorded in [`local-operator-lock-owner-20261003-v1.json`](receipts/local-operator-lock-owner-20261003-v1.json)
and the successor Draft PR. A passing build does not grant writer authority or
establish independent or mounted runtime qualification.

The mounted AppModel/HTTP/Shell path and all eight remaining #51 runtime cases
remain subject to qualified [#87](https://github.com/camerontjs-dot/Conduit/issues/87)
isolation. Normal operator state, apps, listeners and provider sessions remain
protected. No provider turn, spending, account/auth/default change, installation,
release or whole V1 qualification is authorized by this source repair.
