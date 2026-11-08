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
