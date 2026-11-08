# M1 disposition and first M2 development slice

M1 produces a reviewable source successor to the preserved D1 supervisor.
The bounded M2 result is one offline project check through CDS1 and a real
macOS OS policy, with explicit fixture grants and denial controls. It is
source-exposed development evidence. Production execution remains
`execution_authority_unavailable`; independent and installed acceptance are
NOT_RUN.

## Source identity and custody

Maintained main was rechecked at `49d4f448910f8ef19c4f3b95fc15a9b91ed70df5`.
The source base is frozen R3 `382290bded447ea805ac71ed7d57bebeaf65f471`, tree
`0f9f7c174665a09eb0c6fc213d893e3be3111b79`. The proposal is stacked on R3;
it changes neither R3 nor the separate metadata repair #188. The current
`CANDIDATE.json` identifies this successor, rather than repeating R3's identity.

D1's HEAD is R3, but its uncommitted contents have 429 inputs identified by
manifest `35abf570434e1d8e5ee5f602ff15dbf4ad9863f60073d998a95d374d877db1c9`.
All were rehashed before source assembly. D2's 432 inputs at manifest
`cabb947f0b41ed58e7202794086f101f09f6ef8c721ea2d74da9dc447ed34d5e` were
copied into an owned successor. D3's 452 inputs at manifest
`50b23e2d6fd4dc7bb63c19695996cae608d1162ebfe7b7602922cb2c4dc9e117` were
also verified; only its two recovery guards and corresponding tests were
selected. D3's guest implementation remains a separate unpublished prototype.
The historical D1/D2 file maps describe those old snapshots, not this tree;
their exact bytes remain in private custody and are not republished here.

## Reuse, repair and defer

| Mechanism | Disposition and reason |
| --- | --- |
| Direct read/search/hash-precondition edit and durable file retry in R3 | Reuse. No replacement filesystem implementation is justified. This pass's native fixture preparation is not an installed file-API journey. |
| D1 sole-waiter C supervisor and private CDS1 pipes | Reuse for owned development fixtures. The app owns S; S alone owns/waits for R. No persisted numeric PID grants signal authority. |
| Stable reservation, exclusive launch claim, separate root/cleanup/output/persistence facts | Reuse. Unknown attempts cannot silently launch again; a failed final save retains capacity. |
| D1 deadline attribution and claim-only lookup | Repair by reusing D2's existing source and regressions. An observed exit no longer becomes a timeout during the late-cancel window. Missing outcomes remain missing evidence. |
| Switching fixture executors around an old launch claim; inconsistent v2 capacity acknowledgment | Reuse D3's repairs. Every fixture executor respects prior claims; a disk v2 capacity acknowledgment of true is corrupt. |
| Production authority | Absent. The public constructor has no grant or restricted launcher, and AppModel still selects it. The write switch cannot supply that authority. |
| Filesystem, network and descendant execution confinement | D1 supplies none. The M2 probe adds a separate deprecated development OS policy; it does not change what CDS1 guarantees. |
| Guest runtime, ordinary Swift toolchain, supported product backend | Defer runtime claims. D3's configuration/source and preparation checks are not guest execution evidence. |
| Recovery execution, packaging the supervisor, human/API independence and installed acceptance | Defer. Existing formal review/isolation requirements and #168 → #123 → #128 / #142 HOLD remain. |

Historical crash evidence stays bounded: the ten-case D1 synthetic campaign
passed its declared checks; the separate integrated crash attempt stopped at
its first startup failure; a later successful timing diagnostic did not explain
that earlier delay. No old failure, missing binary receipt or NOT_RUN case is
relabelled by this successor.

## First executable development profile

The probe creates one project, one sibling scratch directory, one private
ledger and owned outside sentinels under a new output directory. It accepts
no ordinary project, arbitrary command, app setting or product grant. Its
in-memory fixture authority issues exact operation grants; request-like data
cannot mint a trusted grant. Validation precedes operation-directory creation,
launch claims and process launch.

The grant binds the operation, project inode/content map, scratch/ledger
identity, check bytes, environment, budgets, policy and actual executable
hashes. It is a development capability held by that harness, not a capability
of the operator app. Same-user hostile replacement and atomic preflight-to-exec
integrity are outside this trusted-fixture scope.

| Boundary | Declared behavior |
| --- | --- |
| Check and toolchain | Explicit `/bin/bash --noprofile --norc --posix <pinned-check>`, with the host Bash hash. The check reads the edited value, emits distinct stdout/stderr, returns an observed exit and writes one scratch artifact. No package manager or Swift build runs inside this profile. |
| Environment | Exactly `PATH=/usr/bin:/bin`, `LANG=C`; null stdin; no shell startup, inherited credentials or loader overrides. |
| Launcher | CDS1's root execs the fixture budget launcher, then `sandbox-exec`, then the exact Bash command. Resource setup or policy failure has no unconfined fallback. Launcher/supervisor bytes are hash-bound. |
| Reads | Project/scratch data, exact approved executables and declared system runtime roots. Global file metadata and sysctl reads are permitted by this development policy; it is not a metadata-confidentiality profile. |
| Writes | Scratch only during the command. The scoped project edit occurs in native fixture preparation before launch. Outside reads/writes, check-time project writes, traversal and symlink-outside data access are denied by the OS policy. |
| Executables and descendants | Only Bash, the pinned native diagnostic probe and `/bin/echo` execute after the boundary. Fork is allowed; the owned child's outside write remains denied after `setsid`. This is separate from original-group cleanup. |
| Network | No network permission. An owned loopback TCP endpoint provides an ambient success control followed by an actual denied connection and no accepted denied request. Other transports are not individually qualified here. |
| Budgets | One sequential operation; active deadline 4 seconds from GO, existing finite CDS1 setup/cleanup windows, 15-second controller bound; per-process CPU 2 seconds, 64 descriptors, per-file size 1 MiB and core dumps disabled; retained output 4 KiB per stream with explicit truncation/EOF. These are not hard scheduling or filesystem-latency guarantees. |
| Missing limits | No demonstrated aggregate memory/disk/CPU quota, task process-count bound, hostile same-user isolation or production support. The tiny reviewed fixtures do not justify general command admission. |
| Lost ownership | Missing FINAL/EOF/reap/group facts remain UNKNOWN. No PID adoption, claim retirement, automatic new-ID retry, capacity recovery or inference from quiet output. Any adverse case stops dependent probes. |

Apple's installed manual marks `sandbox-exec` deprecated and directs developers
to App Sandbox. Apple's [helper documentation](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app)
describes sandbox inheritance within a sandboxed application; it does not
establish that this unsandboxed app can grant an ordinary project toolchain a
supported restricted profile. This development launcher is therefore excluded
from product activation.

## Executed development evidence

Host: macOS 27.0 / 26A428 arm64, Xcode 26.6 / 17F113, SDK 26.5,
Swift 6.3.3. Toolchain selection was per command. Exact receipt digests and
build identities are in the [evidence catalog](m1-m2-development-evidence.json); raw logs, grants, private paths,
frames and owned fixture bytes remain private.

- First native attempt: nine authority controls passed, then the permitted
  `/bin/sh` check failed because this host selected `/bin/bash` as its variant.
  The OS refused that undeclared executable. Later native denial cases were
  NOT_RUN in that attempt. Its original source, binaries and result survive.
- The successor names Bash directly. The final native attempt passed 24
  conditions: nine application refusals, eleven commands under the actual
  boundary and four ambient controls. Exit 0 returned `checked`/`diagnostic`
  on separate streams plus the exact artifact; controlled exit 23 remained
  nonzero. Outside data, traversal/symlink, executable, detached-child write
  and loopback denials returned actual errno/exit evidence.
- An absent native helper returned BLOCKED, exit 2, without operation effects.
  No engine failure was converted into a synthetic pass.
- Focused XCTest: 34 passed. Selftest: 601 passed. Python contracts: 33 passed.
  Full XCTest: 837 reported, four explicit skips, zero failures. The skips are
  the opt-in 121-second command and three installed/provider cases.

The fixture inspect/search/edit → check → result inspection chain ran through
native tools and the development launcher. It does not establish the installed
authenticated Conduit journey, ordinary Swift-check parity, full logs, human
presentation preservation or independent qualification.

## Supported product recommendation and next boundary

For ordinary repository checks, retain the earlier single-project, offline
disposable macOS guest recommendation. Reuse D3's source before adding another
backend. Its proposal binds a staged project and pinned check/toolchain to a
local grant, no NIC or host directory shares, one VM/operation, 2 CPUs, 4 GiB,
600-second command budget, bounded RAW disks and bounded batch output/export.
These are source/configuration limits, not observed guest confinement.

The smallest next packet is exact guest/platform/boot/exchange/toolchain asset
custody and offline readiness for that D3 design, followed by separately scoped
runtime authority. No candidate installation or old exact R3 trial follows.
If the intended goal is deliberately reduced to data validation, a separately
sandboxed byte-only checker is the narrower alternative; it would not satisfy
the ordinary-project-check goal. No broader product privilege is selected here.

> **Binds:** this source proposal and its fixture-only development runner.
> **Tier:** T1 for the declared native development conditions; product
> recommendations and limits of inference are T0.
> **Check:** `python3 scripts/probe-offline-development-profile.py --output-directory NEW --supervisor BUILT_HELPER`,
> `scripts/test.sh` and `git diff --check`, with machine receipts and the source
> identity catalog. No installed or independent gate is claimed.
> **Escape:** preserve failures and UNKNOWNs; keep production refused when the
> supported boundary, assets or runtime authority are unavailable.
