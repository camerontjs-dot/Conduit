# Direct workflow R3 · independent review repair

R3 succeeds frozen R2 source `aaca420f47f1c6d9f824f12788a727b61b00c45c`
(tree `72e68483ce790dd7e6b723cfc8ac847965b7b2e1`). R2 remains unchanged.
Both retain main `49d4f448910f8ef19c4f3b95fc15a9b91ed70df5`, merged #183–185,
and the existing #175 repair implementation. R3's exact source, tested bytes,
local bundle and receipt digests are recorded in `CANDIDATE.json`.

**Development candidate only.** No merge, push, installation, production
enablement, privilege expansion or active UI operation is part of this work.
Hosted and installed acceptance remain NOT_RUN. The public command initializer
still refuses new execution as `execution_authority_unavailable`.

## Independent R2 review and repair

The explicitly requested reviewer was `gpt-6-luna`, high effort, with a fresh
context and separate source checkout. Actual runtime identity/usage are UNKNOWN.
The reviewer froze criteria before source/test-outcome inspection and retained
their hashes, original reproduction, logs and machine-readable review. This is
independent source review, not blind scientific qualification or installed
acceptance. The informed R3 follow-up is a separate read-only source review;
its author did not run the parent verification commands.

**R2-CMD-001, P2:** after cancellation, the direct child exited on TERM while a
same-process-group descendant ignored TERM and redirected its output. R2 reaped
the leader before escalation, stopped cleanup, returned terminal UNKNOWN and
retained capacity while the descendant still ran. The parent reproduced the
same defect for cancellation and timeout: three tests ran, the two descendant
cases produced eight failed assertions, and concurrent retries/cancellation
passed. Both first failures are retained; they were not replaced by green logs.

The repair keeps the child waitable through the existing 500 ms grace period,
using `waitid(WNOWAIT)` to check ownership without releasing its PID. KILL is
sent only while that check succeeds. After reaping, only read-only group checks
remain, within the original two-second cleanup budget. Capacity is released
only after direct-child exit and original-group absence are observed.
The child's actual TERM exit remains in the receipt even when its descendant
needs KILL. [POSIX wait](https://pubs.opengroup.org/onlinepubs/9699919799/functions/wait.html)
and [waitid](https://pubs.opengroup.org/onlinepubs/9699919799/functions/waitid.html)
describe child waiting and the non-consuming observation used here.

Three added native regressions check cancellation, timeout and concurrent
exact retries/cancellation, including one mutation, one cancellation admission,
retained outcome identity, cold-reader replay and actual capacity reuse.
The selected run passed 25 tests with one long-duration test skipped; the full
run enables that real 121-second fixture separately from this selected result.
The reviewer found the original defect addressed and no additional supported
repair or routing defect. The exact records are retained as `REVIEW.json`,
`FIX-REVIEW.json`, `cancellation-red-result.json` and
`cancellation-green-result.json` in the private review packet.

## ChatGPT command workflow

Authenticated MCP initialization now delivers compact direct-tool-first
instructions. Command and task descriptions repeat the routing decision for
clients that retain tool metadata. The instructions keep reasoning in the
current conversation, prefer eligible file/command tools for routine work,
give explicit output/page budgets and stable-ID recovery steps, and reserve
another model for work with a concrete reasoning or independent-review benefit.
An explicitly requested review does not need a failed shell attempt first.

The [client guide](../DIRECT_WORKFLOW_CLIENT.md) distinguishes the connected Mac
from cloud scratch and Shell PTYs from model sessions. It forbids routing around
an execution refusal through Shell, another model, a new ID or changed settings.
It does not replace the existing MainFrame direct-tool policy or add a policy
engine. Transport tests verify authenticated instruction delivery, authorization,
no dispatch/admission effects, compact size and references to real tools.
They do not prove ChatGPT consumes or follows those instructions.

## Evidence layers and remaining decisions

Local checks and their exact input-file snapshot are in
`full-native-result.json` and `full-native-input-files.json`; the build has its
own result and bundle inventory. The full run recorded 589 passed self-checks,
33 passed Python checks and 817 XCTest cases (814 passed, three optional
installed/provider cases skipped, zero failures), including the real 121-second
command. All 298 captured runtime,
test and script inputs were unchanged during the run. No source count is an
installed result.
The [installed packet](direct-workflow-installed-acceptance.md) has 16 NOT_RUN
cases, including fresh-client routing and the adverse descendant cleanup case.
It requires actual call sequences in three fresh ChatGPT sessions for routing
acceptance, not merely the presence of the MCP instruction field.

Current-tree path/secret checks and contract/diff checks passed. The separate
full-history leak scan still failed on six inherited local-path fixture strings
in historical commit `c2ec1dba2`; none is introduced in R3. No history rewrite,
waiver or push was performed. The failed scan is retained in the evidence packet.

The smallest proposed execution profile remains an offline project check:
one exact project plus disposable scratch, an explicit executable/toolchain
closure, no inherited credentials and network denial enforced by the OS.
The [R2 profile assessment](direct-workflow-20261022.md) distinguishes actual
filesystem/network/executable denials from logging, cwd and process-group
observations. Its disposable policy probe is not integrated into Conduit and
has not been rerun or promoted by this review. No new execution grant is added.

Owner selection of the supported enforcement mechanism/toolchain, its reviewed
implementation and actual-toolchain qualification remain prerequisites for a
new enabled successor. Exact installation and installed/fresh-client acceptance
need separate authorization. These decisions do not block the completed source
repair or client-guidance development.

Residual limits remain explicit: descendants leaving the group are not
contained; cleanup beyond two seconds or lost ownership can remain UNKNOWN
with capacity retained; cancellation after reaping cannot regain signal
authority. Injected persistence-failure coverage for each command transition
is still incomplete. The review does not establish all possible interleavings,
OS confinement, complete logs, mounted UI preservation or production readiness.

> **Binds:** assessment and use of the R3 development candidate.
> **Tier:** T0 evidence interpretation; runtime refusal and checks are separate mechanisms.
> **Check:** exact candidate manifest, retained raw test/review/build receipts and deferred installed case records.
> **Escape:** preserve UNKNOWN, NOT_RUN or BLOCKED prerequisites without substituting source results or expanding authority.
