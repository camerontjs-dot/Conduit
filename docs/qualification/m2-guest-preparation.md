# M2 offline guest preparation — 8 November 2026

This is bounded source engineering and native development testing. It advances
M2 preparation from Draft #189. **M2 supported guest execution remains BLOCKED.**
M1 and its deprecated-backend development evidence remain as recorded in #189;
this slice does not promote that backend or qualify the operator installation.

## Source disposition

The owned successor starts from #189 head
`533b5fd7254b19efd0ce126e93ebfd36f4041c8d`, tree
`4e3cedbd81cda97ee7c7e0dbe5b1d640d64d2bf1`. Frozen #187 stays
`382290bded447ea805ac71ed7d57bebeaf65f471`; main stays
`49d4f448910f8ef19c4f3b95fc15a9b91ed70df5`. #188 is separate.
The final source commit/tree and local receipt hashes are catalogued in
`m2-guest-preparation-evidence.json`; raw receipts remain private.

Reuse D3's existing descriptor-based workspace, fixed profile, configuration
factory, job/output data and 13 tests. Its original private content digest is
`50b23e2d6fd4dc7bb63c19695996cae608d1162ebfe7b7602922cb2c4dc9e117`,
independent of its R3 HEAD. Keep the original unpublished working tree intact.
Repair the sample CLI's request/replacement input reader to reject actual
oversize before reads and refuse aliases. Reuse its three closed-profile
self-checks. Add eight focused preparation tests.

The first sample check itself needs only the guest Bash and grep plus the
worker. Its toolchain inventory can pin those built-ins; full guest Xcode or
Python is not an implicit requirement for that check. D3's nominated environment
is a source contract, not evidence that any guest tool is installed.

Defer D3's untested batch actuator, guest worker, bootstrap, grants, ledger,
mounting, installation, boot and export. The sample's `run` entrypoint always
refuses. No app setting or fixture initializer is exposed to product users.
The operator app and its effective grants/write gates are unchanged.

## Explicit development choices

D-082 records the reversible preparation choices. An owned, copied CLI is ad
hoc signed with only `com.apple.security.virtualization` for actual Apple
restore metadata. The product app gains no entitlement. Apple requires this
entitlement to load a restore image; signing is not command authority or
filesystem/network confinement. The native API and Apple HTTPS HEAD request
are metadata preparation traffic, separate from the future offline check.
No IPSW payload is downloaded by this source slice.

The proposed storage rule budgets the full 64 GiB boot-image ceiling, 256 MiB
exchange image, 8 GiB offline payload staging, 8 GiB host reserve and observed
restore size. This is a conservative development proposal, **not** an
established minimum macOS disk requirement, physical reservation or disk quota.
Unknown size remains unknown; even sufficient capacity never admits allocation
or execution. The fixed guest CPU/memory profile is not silently enlarged.

## Native evidence and first failure

Native host: macOS 27.0 / 26A428, arm64, 8 CPUs, 24 GiB physical memory;
per-command Xcode 26.6 / 17F113. The default developer selection remains
Command Line Tools; a bare `xcodebuild -version` refused for that reason.
No global toolchain selection changed.

The first unsigned catalog request returned `sample_failed`: restore catalog
could not load. It produced no platform packet. That failure is retained.
After signing only a private development CLI copy with the documented
entitlement, the actual native API retrieved restore 27.2.0 / 26B123:

- Native minimum: 2 CPUs and 4,294,967,296 memory bytes. Fits the fixed D3 profile.
- Apple HTTPS Content-Length: 25,595,669,503 bytes. This is metadata, not a verified local IPSW hash.
- Actual supported hardware-model bytes SHA-256: `18d57e0cfa40f7af63bb38c801a03bde06d00b281554b926128828a7ca0d9a2e`.
- Proposed total capacity: 111,763,450,879 bytes, about 104.1 GiB.
- First signed observation: 36,838,625,280 bytes available, about 34.3 GiB.

Only three small exclusive files were written: preparation JSON, actual
hardware model and generated machine identifier. The raw machine-specific
packet is private. Its report explicitly lists insufficient capacity,
unreserved storage, missing guest assets/offline toolchain and unavailable
execution authority. No VM object, guest disk, auxiliary storage, grant or
fixed job ledger was created. No external data volume was observed; existing
compatible assets outside the bounded local search remain UNKNOWN.

The retained controller's final native run passed 13 declared controls:
host/capacity observation, real invalid-IPSW native parser rejection,
application refusals for symlink/hardlink images, linked packet parent,
existing packet and `run`, plus staging → inspect/search → scoped edit →
inspect and traversal refusal. The native parser returned VZErrorDomain 10004
with underlying NSPOSIXErrorDomain 79. Other path controls are application
refusals, not observed OS guest denials. Actual metadata packet hashes/readback
passed. Mocks are not substituted for native framework calls.

## Checks and remaining gap

The first focused run passed 20 XCTest (before the final bounded-input case).
Final full run: 604 self-checks, 33 Python checks and 858 XCTest reported,
four skipped, zero failures. Skips retain the opt-in 121-second process case
and three isolated installed-provider/telemetry qualification cases. No live
provider case was enabled. Local release-package and signature results are
recorded in the evidence catalog; no package is installed or launched.

No supported guest check, stdout/stderr/exit result or confinement evidence is
established here. Outside-file, traversal/symlink, executable, network and
descendant controls **inside the proposed guest remain NOT_RUN**. Host cwd,
environment filtering, metadata receipts and process groups cannot fill that
gap. The CPU/memory numbers above are native restore requirements and source
profile values, not observed guest resource enforcement. Guest disks and
output/export need their own bounded runtime controls.

## Smallest next step

Select an owned storage location that can hold the declared preparation budget,
or supply an existing compatible guest/restore asset inventory for inspection.
Do not reclaim unrelated storage or reduce the disk budget to obtain a pass.
Reconcile actual full asset hashes, platform tuple, offline toolchain and worker
before preparing any runtime admission. Lost ownership remains UNKNOWN; do not
replay from old identifiers or infer cleanup from receipt absence.

Keep #168 → #123 → #128, #142 HOLD, exact reviewer/isolation requirements in
#174 and the old exact-R3 guest trial separate. No merge, release, installation,
paid infrastructure or M3–M6 work is part of this proposal.

References: Apple's [restore image API and entitlement](https://developer.apple.com/documentation/virtualization/vzmacosrestoreimage),
[installation requirements](https://developer.apple.com/documentation/virtualization/installing-macos-on-a-virtual-machine)
and [minimum memory requirement](https://developer.apple.com/documentation/virtualization/vzmacosconfigurationrequirements/minimumsupportedmemorysize).
