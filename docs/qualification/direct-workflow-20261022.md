# Direct project workflow development successor · 2026-10-22

Disposition: **development candidate; production execution unavailable**.
Owner [#60](https://github.com/camerontjs-dot/Conduit/issues/60), direct loop
[#170](https://github.com/camerontjs-dot/Conduit/issues/170), human/remote
isolation [#174](https://github.com/camerontjs-dot/Conduit/issues/174).
Exact frozen source and tree are recorded in `CANDIDATE.json`.

## Reconstruction and reuse

Current main was `49d4f448910f8ef19c4f3b95fc15a9b91ed70df5`, tree
`e545427257712ab56e22e848906b539234ccad70`. Merged #183–185 remain in its
ancestry. The revision-feed and in-process read-service implementation is
retained, not rebuilt. The ordinary checkout was dirty and an installed app
and provider process were active. Development used a new isolated native
worktree. No active UI, installed listener, provider, settings or write gate
was operated.

The existing changes were applied as source deltas, preserving their history
as evidence rather than treating old tests as qualification of this assembly:

| Source | Exact source used | Prior result boundary |
| --- | --- | --- |
| #175 | `2958b285310a3f882deeffe3ea36a9786661a6fe` | Original direct/file stack; failed review retained |
| #177 → #178 → #180 | `a4b656283b7e8c74bddb16175b667944a5a255fa` | Durable retry/admission repairs; behavioral acceptance blocked |
| #179 → #181 → #182 | `828498adcccea5ee9acee403a888c037337701dd` | Prompt/output ownership repairs; bounded source result only |

The first delta is from #175's base `10a8d03852b1589a98f212d317c26463cda93c76`
through #180. The output repair delta is from #177's
`64d6b7c810f381fdf0f046f8dc100da0df535413` through #182. Integration preserves
main's numeric-argument and redaction fixes and combines both selftest groups.
The colliding output-ownership ADR number becomes D-079; the bearer-admission
D-064 keeps its identity. Historical qualification records keep their original
candidate/result scope. No previous failure, Draft, merge, release or mounted
qualification state is promoted by this local assembly.

## Ordinary workflow gaps

| Workflow need | Existing implementation / exact gap | This candidate |
| --- | --- | --- |
| Inspect a project | Direct root-relative file read and exact-project literal search exist; bounded search can be partial | Reused; no model or indexed substitute |
| Make one scoped edit | Hash/identity-checked UTF-8 replacement, exclusive create and durable replay exist | Reused; stale-hash refusal and duplicate retry exercised over HTTP parser/dispatch |
| Run an ordinary check | Native asynchronous runner exists but production has no enforceable authority | Guard retained; internal disposable fixture only |
| See the final error | Prefix-only retention loses final diagnostics; repeated status repeats large output | Optional 64 KiB suffix and ≤16 KiB byte pages per stream; explicit missing middle |
| Wait for a build | Hard 120-second cap rejects otherwise valid longer checks | Up to 3,600,000 ms accepted; actual 121-second fixture completed; default 10 seconds unchanged |
| Interpret outcome | Spawn/queue acknowledgement is not exit; nonzero must survive transport | Typed exit 23, timeout, cancellation and UNKNOWN semantics retained/tested |
| Cancel noisy work | Output drainage can compete with cancellation; process group is not descendant confinement | Continuous-output cancellation regression; original ownership limits retained |
| Recover lost response | A different ID can duplicate side effects; reconnect must not start a task/provider | Same-ID replay across new server/client identity; one check marker and one file effect |
| Recover app ownership loss | A persisted PID cannot safely supply ownership | Fresh reader derives UNKNOWN for live unowned operation; no recovered-PID cancellation |
| Preserve human work | Selected project/task/surface and drafts are presentation state, not remote scope | Source isolation checks plus existing draft regressions; mounted UI NOT_RUN |
| Use a real toolchain | Fixed PATH/LANG, no stdin, HOME/cache policy, explicit toolchain or network authority | Unresolved by design; no environment passthrough or credential expansion |

File replacement is optimistic conflict detection, not an atomic compare-and-swap
against external editors. It does not see unsaved editor buffers. Work on a
separate disposable project for acceptance, preserve unrelated dirty bytes, and
refuse a stale hash. Read paths remain relative to the configured root; write,
search and command scope use the exact project slug. Those are distinct APIs.

The suffix is not a complete log, a live tail subscription, or a permanent
stream snapshot. While running, older suffix bytes can disappear before a slow
reader consumes them. Byte pages can split UTF-8; base64 remains authoritative.
The one-hour schema ceiling is not evidence of a one-hour test. Capacity remains
two concurrent commands by default, at most four; a proposed narrower profile
can select one. No capacity or deadline claim implies an OS resource quota.

## Smallest enforceable profile recommendation

Start with one **offline project check** in an isolated project and scratch
directory. The profile is operator-owned and immutable for an operation: exact
root identities, toolchain revision/executables, working directory, environment,
deadline and retained-output quotas. The request may choose none of those
authorities beyond its already validated command fields. Refuse work that
needs additional access rather than broadening the profile at runtime.

| Control | Required enforcement | What exists / evidence |
| --- | --- | --- |
| Filesystem | OS denies content reads outside explicit project/toolchain/system roots and writes outside project plus scratch/cache | Development policy probe passed allowed controls, outside read/write, parent traversal and symlink denials; app runner has no OS filesystem restriction |
| Network | OS denies network, including loopback; no dependency download or provider endpoint | Native TCP loopback positive control then policy denial passed; no network profile is enabled in app |
| Subprocess executables | OS restricts executable paths; descendants inherit the policy even after changing process group | Allowed `/bin/echo`, denied `/usr/bin/true`; detached `setsid` child still denied outside write in probe |
| Environment | Fixed explicit values, disposable HOME/TMP/cache, no inherited credentials | Runner currently supplies PATH/LANG only; scratch HOME/cache needs a reviewed profile implementation |
| Lifecycle/resources | Track owned direct child and original process group; one admitted check, finite deadline; refuse uncertain recovery | Native ownership, timeout and receipt limits are application controls; no hard CPU/memory/fork-count limit or complete descendant cleanup claim |
| Audit | Durable exact request, status, exit facts, gaps and retry identity | Logging/replay evidence; neither OS permission nor proof of confinement |

An executable allowlist alone is insufficient: an allowed interpreter can run
arbitrary code. OS filesystem/network restrictions must persist through every
child. A working directory, an isolated Git branch, a process group and a log
do not enforce those restrictions. Linked Git worktrees may need access to Git
metadata outside their root; use a standalone acceptance clone or explicitly
review that additional read scope, never grant the whole parent silently.

The development probe uses macOS `sandbox-exec` with default deny and only
named grants. The local manual marks it deprecated. Its private profile
language is a platform-version risk; it is a feasibility instrument, not a
production backend. It permits global metadata reads and listing `/`, plus
system library content reads; it does not promise path-name secrecy. The
tested executable set is the tiny native fixture and `/bin/echo`, not Swift,
Git, package managers, arbitrary shell projects, or a build toolchain.

For a supported product architecture, evaluate a separately sandboxed helper
with explicit file grants and constrained IPC. Apple's
[App Sandbox guidance](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)
and [helper inheritance documentation](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app)
describe OS enforcement and inherited child restrictions; they do not establish
that Conduit's current signing, entitlements, toolchain or command runner meets
them. The exact production mechanism and resource/cleanup bounds require an
owner decision and separate implementation/review. This candidate installs
neither mechanism and retains `execution_authority_unavailable`.

## Evidence ledger

Raw machine logs, result JSON, source inventories and hashes are retained in
the private dated receipt packet. `CANDIDATE.json` binds their digest identities
without publishing private machine paths. Each result is scoped to its layer.

| Layer | Result / limit |
| --- | --- |
| Integration baseline | 77 selected XCTest passed, repository selftest/Python gates passed before the new feature |
| Regression first failure | New workflow tests failed against inherited API; original red log preserved |
| Focused native source | 30 tests passed after the repair |
| Real extended-duration workflow | 9 tests passed, including 121-second owned child and HTTP parser/dispatch file→check→inspect loop; no listener or UI |
| Full native source | 587 self-checks and 33 Python checks passed; XCTest 812 executed, 4 skipped, 0 failures. One skip is the separately passed 121-second fixture; three require installed/provider fixtures |
| Local release package | Build and ad-hoc signature verification passed; not launched or installed. Exact bundle/binary identity is in the frozen manifest |
| Policy probe 01 | BLOCKED: allowed process aborted during dyld startup; denial cases not evidence |
| Policy probe 02 | 11/11 PASS_BOUNDED after adding literal `/` read required by dyld; exact policy/script hashes retained |
| Hosted candidate CI | NOT_RUN; local branch not published; main's prior hosted results do not transfer |
| Installed candidate | NOT_RUN; installed app not replaced, launched, queried or driven |
| Fresh ChatGPT client | NOT_RUN; no connector refresh, model turn or new chat |
| Mounted human selection/drafts | NOT_RUN; source guards and file sentinels are not mounted observations |

No independent reviewer or subagent was launched for this candidate. No blind
qualification, production readiness, merge, installation or enablement claim.
The [acceptance packet](direct-workflow-installed-acceptance.md) has a guarded
track for this candidate and a separately blocked execution track. An owner
decision is needed only for that future profile, exact installation and
installed experiment; source development did not wait on those decisions.

Reproduction from this repository uses `scripts/test.sh --jobs 2`, then
`CONDUIT_LONG_COMMAND_TEST=1 scripts/test.sh --jobs 2 --filter ConduitDirectWorkflow`
for the additional real-duration fixture, and `scripts/build-app.sh` for a local
package. These commands do not run installed-client acceptance. The actual
extended-duration run used Xcode's `swift test --jobs 2 --filter
ConduitDirectWorkflow` with the opt-in environment flag; its raw invocation is
retained separately. Run `python3 scripts/probe-direct-execution-policy.py
--output-directory <new-owned-directory>` only for the synthetic OS probe.

The first separate signature-inspection attempt used a relative bundle path
and returned `No such process`. An absolute-path invocation verified the same
bundle bytes without rebuilding or resigning; both observations are retained.
Existing compiler warnings remain in the build log. GitHub owner/PR updates
were not posted; this record is the prepared local reconciliation.

R2 corrects only that Python invocation after R1 was frozen. Its 298 source,
test and script files match the tested R1 source byte-for-byte. The original
test executions and packaged binary stay bound to that source commit; R2
records the exact comparison rather than claiming a new native run or build.

> **Binds:** this development record and the linked deferred acceptance packet.
> **Tier:** T0 documentation; machine tests enforce only the cases they run.
> **Check:** frozen source, test logs, policy receipts and candidate manifest.
> **Escape:** retain NOT_RUN/BLOCKED/UNKNOWN at the owning evidence layer; do not infer an execution grant from a pass.
