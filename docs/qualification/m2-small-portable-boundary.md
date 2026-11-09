# M2: one portable offline check on macOS

Development evidence for #170, 2026-11-08. This fixture uses supported Apple
and Linux interfaces. It does not establish production isolation, independent
qualification, installed acceptance, or macOS/Xcode toolchain equivalence.

## Decision and scope

Reuse the preparation CLI and the exact D3 sample script and arguments. Keep
inspection, search, hash-checked replacement, reinspection and export on the
host's disposable stage. Boot only the resulting fixture and its toolchain.
The permitted guest action is `/bin/bash /work/project/scripts/test.sh --jobs 2`.
The run inspects the edited message and an owned scratch artifact afterward.
No input option selects an ordinary project or another command.

The smallest complete route tested was a Linux kernel and an initial RAM
filesystem booted through [Apple Virtualization](https://developer.apple.com/documentation/virtualization/running-linux-in-a-virtual-machine).
It has one CPU, 128 MiB RAM, no disk image, host share, NIC or guest socket
device. The console only returns bytes to the host. The selected boot inputs
total 37,957,828 bytes; the signed native actuator adds 94,480 bytes. The cross
compiler, package archives, and retained failures are development inputs and
evidence, separate from guest storage. No macOS restore or storage reclamation
is needed for this portable check. This is the smallest complete configuration
tested here; no lower RAM limit or global minimum is asserted.

## Authority and enforcement

The trusted host harness issues a fixture grant bound to the profile, staged
input, nonce, and current native actuator, kernel and initramfs digests. It
refuses absent, forged, wrong-operation, altered and stale grants before
launch. The actuator independently requires the exact fixture capability on
an inherited pipe, verifies both boot assets, and persists an exclusive claim
before constructing the VM. A compiled digest binds that capability to this
one owned build. Reuse refuses even after a successful stop. The trusted host
owner, compiler, kernel and package provenance are part of the test setup;
these are not credentials for a product or an untrusted same-user host client.

Inside the VM, trusted PID 1 starts the payload as UID/GID 1000 with no inherited
console or listener descriptor. The environment is `PATH=/usr/bin:/bin`,
`LANG=C`, `HOME=/work/scratch`, and `TMPDIR=/work/scratch`. The project is read
only; scratch permits bounded reads and writes. Both are 1 MiB tmpfs mounts
with 128 inodes and `nodev`, `nosuid` and `noexec`. The kernel
[Landlock rules](https://docs.kernel.org/userspace-api/landlock.html) cover
path operations including file execution. Only the pinned Bash, grep, musl
ELF loader, and the development probe receive execute permission. Only the
required libraries are included; optional Bash loadable builtins are omitted.
The declared script is interpreted by Bash. This is not a general prohibition
on executing interpreted or anonymous code in an arbitrary shell workflow.

[Seccomp](https://docs.kernel.org/userspace-api/seccomp_filter.html) rejects
socket creation and selected privilege/namespace operations; no NIC exists to
reach the host or internet. A disposable loopback listener makes the network
control meaningful. [cgroup v2](https://docs.kernel.org/admin-guide/cgroup-v2.html)
holds descendants, including a reparented process after `setsid`. Limits are
32 MiB job memory, no swap, 16 tasks, and 20 ms CPU per 100 ms period. The job
deadline requests group kill at 1.5 s and requires reaping, pipe EOF and zero
group tasks. A 15 s VM deadline requests stop. Each job stream retains at most
4 KiB, with a 64 KiB kill threshold and measured pipe/drain overshoot; the host
retains at most 256 KiB per native stream. The working directory, environment,
claims and receipts contribute no filesystem or network confinement.

> **Binds:** the two standalone owned fixture probes and the fixed Linux suite.
> **Tier:** T2 for launch admission in the owned Linux harness; observed kernel controls apply to this test image and payloads.
> **Check:** `scripts/probe-small-linux-boundary.py` requires the native refusal results, complete nonce-bound frames, exact exit/stream facts, group cleanup and observed guest stop.
> **Escape:** missing assets, contradictory evidence, unsupported policy or an unavailable claim refuse or fail the run. Lost ownership stays UNKNOWN; do not infer effects, recovery or replay authority.

## Native results

On Apple silicon macOS 27.0 (26A428), the [App Sandbox](https://developer.apple.com/forums/thread/793310)
probe passed its native grep control and tested file/network denials, but
`/usr/bin/true` still executed. The earlier unbundled probe failed to initialize
its code identity. App Sandbox alone is rejected for this exact executable
policy. Custom Seatbelt profiles and privileged Endpoint Security were not
used in this supported-mechanisms slice.

The first full Linux suite started and stopped, but denied Bash's ELF loader;
the permitted check returned 126. Declare and pin the loader as a dependency,
then test execution and executable mapping of an otherwise valid ELF in the
outside, project and scratch locations. The ambient loader control succeeds;
outside access fails and both data mounts deny executable mapping. This repair
preserves the executable denial requirement.

The final suite passed 29 guest conditions and 12 grant/claim controls. The
unchanged check exited 0 with 20 stdout bytes (`sample check passed` and a
newline), zero stderr bytes and an observed empty job group. The postcheck
inspection found `after`, the expected scratch artifact and no escape files.
Outside access, traversal, symlinks, undeclared execution, network and a
detached orphan's outside write were denied. Ambient controls reached the
same sentinels, ELF and listener. CPU throttling, memory kill, task limit,
scratch exhaustion, output limit and deadline used actual kernel observations.
The native framework observed guest stop after about 2.9 s. Raw local receipt
SHA-256: `eb7a515179f60feb9fb86ceb337b3d16a398cf7f0c7d67cafa40df244a1e2aa1`.

## Reproduce in an owned development directory

The [asset pins](../../scripts/small-boundary/assets.json) identify Alpine
3.23 aarch64 packages and Zig 0.17.1. Prepare these separately in a private
directory. Match the listed archive digests. For each APK, verify the vendor
RSA signature over its compressed control member and the signed `.PKGINFO`
data hash against the compressed data member. Extract the listed regular
files and relative library links without running package scripts. Derive the
ARM64 `Image` from the bounded gzip member of `boot/vmlinuz-virt` as described
in the pins. Keep the key, packages and verification logs private. Prepare
the Zig compiler by checking its vendor archive digest and extracting it
locally; the runner checks the selected kernel, compiler executable and guest
file digests again. No package fetch, global install or fallback occurs in
the execution harness.

Use the development preparation CLI from this stack and local Xcode. Point
the command at prepared assets and a new private run directory:

```sh
python3 scripts/probe-small-linux-boundary.py \
  --kernel "$OWNED_KERNEL" --rootfs "$OWNED_APK_ROOT" --zig "$OWNED_ZIG" \
  --preparation-cli "$OWNED_PREPARATION_CLI" --evidence-dir "$NEW_OWNED_RUN"
python3 scripts/test-small-boundary-receipts.py --receipt "$NEW_OWNED_RUN/RESULT.json"
```

The native App Sandbox falsification can be repeated with
`scripts/probe-supported-native-boundary.py --evidence-dir` and a different
new private directory. The Linux `init.c` capability probe is a boot-only
diagnostic; it does not execute the check. Each attempt keeps its sources,
builds and observations. The receipt tests exercise rejection of incomplete
or contradictory observations using a local run; they are not OS tests.

Only the owned native actuator is signed for virtualization. No product
target, app entitlement, preference, task, connector or effective grant
changes. Production stays `execution_authority_unavailable`. A future owner
review can decide whether another declared check is portable; a macOS-only
toolchain needs its own supported boundary decision and evidence. The frozen
R3 experiment and #168 → #123 → #128, #142 HOLD and #174 remain separate.

## Supervised development check

D7 runs the same fixed guest suite through the internal development
initializer of `ConduitDirectCommandService` and the existing CDS1 helper.
The fixture driver is linked to an owned debug build of ConduitCore. The
driver takes no arguments. Its build pins the fixture path, ticket and
executables. It requires the exact ticket on an inherited pipe before
constructing the service. The original native one-use gate still controls
the VM. Both gates assume a trusted development owner.

The bridge forwards the exact check bytes and observed exit code after a
correlated guest result and native stop. The supervisor applies its
five-second host budget. The fixture's own stop request is due after four
seconds. A host root or group observation supplies only host cleanup
evidence. A missing guest stop stays UNKNOWN.

| Owned run | Guest observation | Supervisor receipt |
| --- | --- | --- |
| Ordinary completion | Exit 0, 20 stdout bytes, empty stderr, stop observed | `exited`, code 0, both stream EOFs, root and original group cleanup observed |
| Host timeout control | Same exit and streams, guest stopped before the deliberate hold | `timed_out`, SIGTERM, no exit code, root and original group cleanup observed |

Both runs retained the 29 guest checks and 12 D6 authority controls,
including the actual guest wall-limit kill and reaping. The new driver
refused absent and forged tickets before a store or launch claim appeared.
The public service initializer also refused before a write hook or store
creation. Live and completed retries and a fresh read-only service returned
the original operation. A changed request with the same ID refused. Each
run admitted and entered the bridge once, and the receipt store and native
launch claim matched before and after retry.

The host timeout control holds the bridge after confirmed guest stop.
An in-flight loss of VM ownership needs its own experiment. These results
cover one portable development fixture and its typed receipts.

Use the D6 asset inputs above and a new private run directory. Build
`ConduitCore` in an owned SwiftPM debug scratch directory and compile
`Sources/ConduitCommandSupervisor/main.c` with the local Xcode macOS SDK.
The proof driver is linked and bound to the current fixture at run time.

```sh
python3 -B scripts/probe-supervised-small-boundary.py \
  --core-build "$OWNED_BUILD/arm64-apple-macosx/debug" --supervisor-helper "$OWNED_HELPER" \
  --kernel "$OWNED_KERNEL" --rootfs "$OWNED_APK_ROOT" --zig "$OWNED_ZIG" \
  --preparation-cli "$OWNED_PREPARATION_CLI" --evidence-dir "$NEW_OWNED_RUN"
```

For the host timeout control, add `--timeout-after-stop` and choose another
new evidence directory. The original D6 runner retains its default VM
deadline. The fixture driver, helper and bridge remain development tools.

### Host deadline with a live guest

D8 keeps the same guest suite. After its 29 cases and postcheck inspection,
an additional confined pause job keeps the guest running. Trusted PID 1
reports the job's presence. The native owner records the VM state and its
own process group when it receives TERM from the supervisor.

| Native response to TERM | Host observation | Guest observation |
| --- | --- | --- |
| Explicit framework stop | `timed_out`, root exit and original group absence | Running at TERM. Stop completion and `.stopped` observed 12.8 ms later |
| Default termination after recording state | `timed_out`, root exit and original group absence | Running at TERM. Stop evidence unavailable, so guest state UNKNOWN |

The host budget is five seconds. The additional pause job has a
three-second bound. The original 29 guest cases retain their existing
limits and denials. Both final runs passed them and the prelaunch authority
controls. The first 3.5-second attempt stopped the VM but interrupted a
denial receipt before the suite and live witness were complete. That
attempt is retained separately.

The confirmed VM stop uses the [Apple Virtualization stop API](https://developer.apple.com/documentation/virtualization/vzvirtualmachine/stop%28completionhandler%3A%29).
It ends VM execution abruptly. The last guest witness still showed the
pause job, and final guest process reaping is unobserved. A host capacity
acknowledgement is scoped to host process ownership. The default
termination case supplies no VM capacity or replay authority.

Use `--live-timeout cooperative` with a fresh owned directory to observe
the explicit stop. Use `--live-timeout default` for the termination
control only after the first VM stop is confirmed. The default case ends
the run sequence with guest stop UNKNOWN. The original supervised
completion and post-stop hold modes keep their behavior.

### Guest slot after a missing stop acknowledgement

D9 gives the owned campaign one shared guest slot. The signed runner binds
the slot directory identity, takes its lock and persists the attempt claim
before constructing a VM. The same owner can add the matching stopped
record after observing the VM stopped. The records are exclusive and
append only. Another launcher checks them after acquiring the lock. An
unmatched claim keeps the slot blocked across native process exit.

| Attempt | Observed outcome |
| --- | --- |
| Explicit VM stop | The runner persisted the matching stop record. Its original ticket still refused one-use replay. A fresh operation started through the same slot. |
| Live timeout without native stop acknowledgement | The host group cleared and host capacity was released. The guest slot retained one unmatched claim. Both host receipt retries returned the same operation with one bridge entry. |
| Native retry and fresh admission | The old ticket, a distinct valid ticket, and its repeat all returned `guest_slot_stop_unacknowledged` before creating a new native launch claim or configuring a VM. Slot bytes matched before and after. |

Both actual VMs ran the original 29 guest checks. Zero VM starts followed
the missing acknowledgement. The stopped record reports VM stop only.
The fixture makes a separate observation of host cleanup and leaves the
unacknowledged guest UNKNOWN.

Use an owned private campaign directory with an empty private
`guest-slot` subdirectory. Use the same preparation and build inputs from
the supervised fixture commands. Pass `--shared-guest-slot` for three
fresh evidence directories under that campaign. First run
`--live-timeout cooperative` and verify its stop record. Then run
`--live-timeout default` and verify the unmatched claim. Finally run
`--check-blocked-guest-slot` to exercise the valid fresh ticket. The
campaign retains the slot and all original attempts.

This gate covers one trusted development campaign. The evidence covers
process exit and fresh launcher admission with retained files. Product
authority and power-loss recovery require separate evidence.
