# Native portable offline launcher — development result

The fixed portable check can run through a native bridge and the existing
command service. The complete integration campaign remains **partial**: its
last owner-loss control failed closed on repeated native timeout events.
The operator path still returns `execution_authority_unavailable`.

This is bounded source engineering and development testing. Independent and
installed qualification are NOT_RUN. It does not change the R3 trial,
#168 → #123 → #128, #142 HOLD, #174, merge or release authority.

## Source and profile

The successor starts from D10 proposal
`acd80989d95d33f361bafbea143f4ddddc968706`
(tree `0f206d83760e73431ecf8cf2344ca87510eb4f16`).
The repaired native campaign exercised
`0a45535644f6db8705a3dd64ba07c49bc53f2561`
(tree `96f22f2d8863e111e3ae20565971d4c50e793090`).
The later observation-only retry and exact-permit admission repairs have
separate component/package and retained receipt evidence; they were not
another successful five-boot campaign. Final source checks exercised
`6d559cc341a4acb0f46c33f3a2f47a0b748ec40e`.

`ConduitPortableOfflineProfile.v1` describes this development check under
`conduit-portable-offline-check/v1`. The existing macOS preparation profile
keeps its identity, two CPUs and 4 GiB fields. This portable profile uses:

| Resource | Fixed scope |
| --- | --- |
| Check | `/bin/bash /work/project/scripts/test.sh --jobs 2` |
| Guest | One CPU, 128 MiB, no NIC, disk, host share or guest socket |
| Payload | Pinned Bash, grep, musl loader and declared libraries/probe |
| Data | One staged disposable project; 1 MiB project and scratch mounts |
| Job | 32 MiB, 16 tasks, 20% CPU quota, 1.5-second deadline |
| Output | 4 KiB retained per job stream; 64 KiB kill threshold |
| Native capture | 256 KiB per serial/diagnostic stream, continuously drained |
| Deadlines | Five-second host; four-second normal VM; 5.75-second live control |
| Environment | Explicit PATH/LANG; guest HOME/TMPDIR in owned scratch |

The kernel, loader and toolchain are bound transitively by the exact pinned
initramfs bytes and the unchanged preparation inventory. The boundary uses
Apple Virtualization plus the existing Linux Landlock, seccomp and cgroup
rules. Native macOS/Xcode workload equivalence is NOT_ESTABLISHED.

## Authority and ownership

The internal fixture issuer creates an opaque, non-Codable grant. It binds
the operation, nonce, fixed profile, staged manifest and directory identities,
slot identity, helper, worker, kernel, initramfs, environment, budgets and
expiry. A fresh per-fixture key is compiled only into private fixture pins.
Domain-separated authentication protects the issued permit and guest result
from caller-supplied JSON. Both adapter and bridge check current scope before
new execution, including exact submitted/stored permit equality. No secret
is passed in argv or the environment.

The host is trusted and owned by the same user. Compiled fixture keys and
exact stop-record matching do not defend against a compromised host owner.
There is no public issuer, product setting or execution-capable app constructor.

The native bridge is CDS1's root process. It spawns one exact native VM owner
in its existing process group, resets child signal dispositions/mask, supplies
the existing capability on FD3 and closes unrelated child descriptors. It
drains bounded private capture and reaps only its own child. It never signals
a recovered PID or a reaped child. CDS1 and its reserved descriptors are
unchanged.

The bridge authenticates and rechecks its permit before creating its one-use
claim. The native VM owner retains its existing gate and slot validator.
Only that live owner's matching observed stop can acknowledge guest capacity.
Host root/group cleanup and a released host slot cannot supply missing stop
evidence. Lost guest ownership stays UNKNOWN.

Typed guest results contain the declared check's exact exit and streams,
capture digests, native child identity and distinct guest-stop/slot facts.
They are authenticated and correlated with the existing host receipt. The
full 29-condition verdict remains the unchanged external oracle's job; a
typed result explicitly says `external_oracle_required`.

Exact existing-operation retries authenticate the same original permit and
return an observation. Expiry or changed input cannot authorize a new
operation. An observation does not reacquire execution or signalling custody.

## What ran

The development host was arm64 macOS 27.0 (26A428), with explicitly selected
Xcode 26.6 (17F113). Core and the separately linked bridge retain the macOS13
deployment target; the reused native VM probe retains its existing macOS14
target. Older-runtime behavior was not exercised.

| Condition | Observed result |
| --- | --- |
| First native attempt | Guest stopped; bridge rejected serial CRLF and returned125; retained failure |
| Repaired native completion | Exit0, exact sample stdout, empty stderr, final inspection, native stop |
| Three cooperative live timeouts | Host timeout and native stop observed separately; final guest job reaping unobserved |
| Stale/mismatched stop matrix | Four conditions × two refusals; zero VM starts during denials |
| Genuine matching acknowledgement | Same waiting ticket and native runner admitted once |
| Default owner-loss control | Repeated timeout events rejected; no typed guest success; guest slot held UNKNOWN |
| Fresh issued adapter against held slot | Entered bridge once; native gate refused before construction/start; slot unchanged |
| Read-only retries after failure/expiry | Original v2 host receipts, zero hooks/writes/VM starts; no reader capacity authority |

There were six actual boots: one retained failed attempt, then a separately
recorded five-boot repaired campaign. All six raw guest captures passed the
original 29 guest-condition oracle. That narrower fact does not turn either
failed integration operation into a pass.

The existing outside-file, traversal, symlink, network, executable, loader,
mapping, descendant and resource controls were unchanged. Their ambient
positive controls remain part of the 29 conditions. Grant and slot refusals
are application admission checks; guest kernel controls supply the isolation
observations. Working directory, environment filtering and process groups
are not filesystem/network confinement.

The actual native mechanics probe also checked occupied parent FD3,
capability mapping, unrelated descriptor closure, signal/mask/environment,
same group, exact streams/EOF, nonzero child exit, lost wait custody,
post-reap signal refusal, pre-observed TERM refusal and actual TERM re-raise.
It did not force the narrow signal-during-spawn race or qualify a VM.

Full source checks passed: 611 self-checks, 33 Python contracts and 874 XCTest
cases reported, with four declared skips and zero failures. The skips cover
the opt-in long command and isolated installed/provider qualification cases.
Twelve receipt regressions passed on the new native completion capture.
The release package and strict deep signature check passed without launch or
installation; its load command records minimum macOS13 and SDK26.5.
One overlapping SwiftPM package invocation failed during plugin generation;
the retained failure was followed by a successful sequential package build.

The two failed native operations remain failed. After the final failure,
separate zero-boot diagnostics exercised a fresh genuine grant through the
current adapter/bridge to the unchanged held-slot gate, then replayed both
failed host receipts through a deny-only reader. The fresh native attempt
returned `guest_slot_stop_unacknowledged` before constructing a VM or writing
a native launch claim. The old slot records remained byte-identical. These
diagnostics do not replace the stopped campaign's full success criterion.

Reproduction uses separately verified local assets and fresh owned evidence:

```bash
python3 -B scripts/probe-native-offline-launcher.py \
  --core-build "$OWNED_CORE_BUILD" --supervisor-helper "$OWNED_HELPER" \
  --kernel "$PINNED_KERNEL" --rootfs "$PINNED_ROOTFS" --zig "$PINNED_ZIG" \
  --preparation-cli "$PREPARATION_CLI" --evidence-dir "$NEW_PRIVATE_EVIDENCE"
```

Live and acknowledgement modes reuse the previous probe's flags and require
the same pre-created owned slot. Keep generated Swift pins and keys private.
`NativeOfflineReplayFixture.swift` is linked only with the original private
pins and a deny-only receipt reader; it is not a product recovery API.

## Retained failure and next boundary

The first decoder used `String.last == "\n"`. Swift treats CRLF as one
extended grapheme, so actual serial output failed that check. The repair
checks the final LF byte, normalizes a terminal CR per frame and still rejects
missing terminators or embedded carriage returns. Synthetic CRLF regressions
and a retained-byte diagnostic passed before the fresh campaign.

In the repaired campaign's final default response, the unchanged VM owner
emitted seven `supervisor_term_received` events before observed signal15
termination. The strict decoder rejected the repeated lifecycle. The root
then exited125 under a `timed_out` host receipt, with EOF/group cleanup and
host capacity release observed. No guest result or stop acknowledgement was
created. The dependent sequence stopped; its unmatched claim remains intact.

The source suggests that the existing dispatch signal witness can re-enter
while attempting default self-termination. That is a diagnosis, not a proven
cause or permission to normalize away duplicate events. The next bounded
source proposal is an isolated timeout-witness repair and reproduction,
reviewed against the preserved first failure before another native campaign.
The current request keeps that VM owner/control unchanged, so the complete
native integration gate remains unresolved.

The operator installation, effective grants, write gates, tasks/providers,
preferences and connector/tunnel were outside this fixture. No candidate was
installed or launched. Frozen candidates, original dirty work, earlier failed
evidence and historical UNKNOWN guest slots remain preserved.

See [D-084](../../DECISIONS.md#d-084-bind-native-portable-development-execution-to-issued-fixture-authority)
and the [existing portable boundary record](m2-small-portable-boundary.md).
