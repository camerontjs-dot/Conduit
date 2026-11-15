# Isolated timeout witness — bounded source repair

Three no-VM runs of the original witness did **not** reproduce D11's repeated
timeout notifications. A minimal defensive repair now claims the existing
once-only state before either timeout branch logs or self-signals. Three
repaired runs retained actual signal 15 termination under one parent TERM.
This is not evidence that the original VM-context defect is resolved.

The source is a successor of [Draft #196](https://github.com/camerontjs-dot/Conduit/pull/196),
base `5c8f9610fe7ed53683dffe263b52a9647a79c274`
(tree `a56706f3493a587a4fc58018314fa83ae0b4a731`).
Tested repair source: `26756a5df3a3fba5a8622151f540f945e2f9d34f`
(tree `32db2751f457c4afa75461da8b26b1b061e92cc4`).

## What changed

`Owner.installTimeoutWitness` already guarded on `supervisorStopping`, but
only the cooperative branch set it. Move that assignment directly after the
event-handler guard, before logging and the default self-signal. The serial
main-queue handler then claims both handoff side effects once. The repair
does not merely filter repeated output or change the decoder's expectations.

Default termination still requests SIGTERM, and only observed native stop can
write a guest acknowledgement. The slot validator, kernel policy, guest
suite, denial oracles, CDS1 and public command guard are unchanged. No
operator app, entitlement, grant loader or product setting changed.

## Isolated method

The probe extracts the actual `liveEvent` and `installTimeoutWitness` methods
from the selected owner source into a native Swift wrapper. The wrapper has
no Virtualization import or VM object. Its unavailable-machine support
reports state `-1`; attempts to stop a machine or acknowledge stop fail
closed. It cannot supply a simulated VM-stop result.

Common instrumentation in both variants adds registration readiness and
records a self-signal request immediately before physically calling
`Darwin.kill`. Request logging is not a kernel syscall trace or proof of
delivery. The parent separately records actual POSIX wait status, exact
child identity, stdout/stderr EOF and capture completeness. This extra
instrumentation and absent VM context can change timing.

The parent waits for the registered source, sends one TERM to its exact
unreaped child and drains both pipes with 16 KiB limits. Each subject has a
five-second deadline and at most one second of failure cleanup. It never
signals after reaping or losing wait custody. A successful verdict requires
raw signal 15 wait status, matching exit evidence, complete capture, no
cleanup kill and one notification/request pair.

## Actual results

On arm64 macOS 27.0 / 26A428 with Swift 6.3.3 and explicitly selected Xcode/SDK:

| Source | Subjects | Notifications / self-signal requests | Actual wait | Disposition |
| --- | ---: | --- | --- | --- |
| Original D11 owner methods | 3 | 1 / 1 each | Signal 15 each | Duplicate NOT_REPRODUCED |
| Repaired methods | 3 | 1 / 1 each | Signal 15 each | No-VM termination contract preserved |

All six subjects had complete stdout/stderr EOF, one parent TERM and no
cleanup signal or ownership loss. Zero VMs started. Because the original
also passed these reduced runs, this experiment shows no before/after
efficacy improvement. The repair is justified by the missing state claim
and the separately retained real VM-context failure.

The complete repaired VM owner also compiled at its existing macOS 14 target
against the unchanged slot implementation and a private retained fixture
gate; that binary was not launched. The isolated wrapper compiled at macOS 13.
Forty Python contract tests passed, including seven new falsification checks
for missing backend, malformed/foreign/incomplete evidence, contradictory
wait status and extraction drift. Twelve unchanged receipt regressions
passed using a retained D11 completion capture. Those regressions are replay
evidence, not new VM execution.

## Limits and next step

D11's seven-event failure, failed typed join and held UNKNOWN guest slot
remain valid and unchanged. No acknowledgement was invented. The source-
exposed engineering review found no material issue in this bounded change;
it is not independent qualification. Full local Core/package checks were
not rerun for this standalone fixture change. Hosted source/package CI is
recorded separately on the Draft.

M2 native integration stays on hold. A later reviewed, separately identified
VM campaign must exercise default/cooperative timeout and missing/matching
acknowledgement controls through the repaired owner. Use fresh owned capacity
and preserve the old held slots. No operator activation, merge/release,
ordinary-project grants or M3–M6 admission follows from these results.

To reproduce the isolated signal check with fresh private evidence:

```bash
python3 -B scripts/probe-timeout-witness.py \
  --vm-runner scripts/small-boundary/VMRunner.swift \
  --evidence-dir "$NEW_OWNED_EVIDENCE"
```

The [Dispatch signal-source API](https://developer.apple.com/documentation/dispatch/dispatchsourcesignal)
describes signal monitoring; the native run receipts establish this fixture's
observed termination. No documented API behavior alone establishes the
cause of D11's repeated events.
