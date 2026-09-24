# Slice 11 capacity and concurrency qualification v1

## Decision

Determine whether Conduit's current runtime/control-plane design can sustain 4, 6, and 8 simultaneously active OpenCode turns without unacceptable responsiveness, resource, event-lag, failure, or cleanup behavior.

This procedure does **not** preselect a new shipped concurrency limit. The shipped Session API live-task limit remains 4 until evidence supports a separate engineering decision.

## Candidate identity

Run each tier against one exact immutable PR head. Record:

- PR number;
- full commit SHA and tree;
- macOS / Xcode / Swift;
- Conduit app build identity;
- OpenCode version and selected model;
- project slug;
- qualification environment.

Do not compare tiers run against materially different candidate trees as though they were one experiment.

## Qualification aperture

Normal Conduit Session API admission remains capped at 4.

The Slice 11 candidate may expose a qualification-only aperture when **both** environment variables are set before the app starts:

    CONDUIT_QUALIFICATION_MODE=1
    CONDUIT_QUALIFICATION_LIVE_TASK_LIMIT=<4|6|8>

Only 4, 6, and 8 are accepted qualification tiers. Unsupported values fall back to the shipped limit.

The effective limit is not inferred from the environment. The runner must confirm it from the live Fleet snapshot before creating work.

This aperture is research infrastructure. A successful 6- or 8-turn run does not itself authorize changing the shipped default.

## Hard protocol

For each tier:

1. Use the same exact candidate tree.
2. Use the same OpenCode version, model, prompt shape, hold duration, sampling interval, and project unless a deviation is recorded.
3. Begin from zero used Conduit task-control slots.
4. If the global provider-reported active-turn total is known and non-zero at baseline, stop as contaminated. If it is UNKNOWN because the provider inventory is larger than the detailed Fleet page, preserve that UNKNOWN rather than pretending the historical remainder is inactive.
5. Create only qualification-owned tasks and identify their exact provider-session bindings from the Fleet snapshot.
6. Establish the requested tier only when every qualification-owned task has one exact provider association and each associated provider session reports `active`.
7. Do not modify project files from the workload.
8. Preserve every failed or incomplete tier.
9. Close all qualification-owned tasks, verify Conduit task-control occupancy returns to zero, and directly observe the exact provider session IDs until each reports `inactive`.
10. Do not convert provider completion into task completion, verification, or objective acceptance.
11. Do not convert provider-reported active turns into provider-neutral execution-slot occupancy. The Fleet snapshot intentionally reports the latter as UNKNOWN.

Avoid unrelated OpenCode work during a decisive tier. If other live provider work is observed and its resource effect cannot be mechanically excluded, classify the tier as contaminated. A global active-turn total that remains UNKNOWN solely because historical provider inventory exceeds the detailed Fleet page is retained as a limitation; it is not rewritten as zero.

## Workload

Default runner:

    python3 scripts/concurrency-qualification.py \
      --target <4|6|8> \
      --project <project-slug> \
      --agent OpenCode

Each task asks OpenCode to run a bounded sleep and then return one token. The sleep is used to create an overlap window without mutating the project.

Default timing:

- hold: 45 seconds;
- active-tier acquisition timeout: 75 seconds;
- overlap sampling: 15 seconds;
- sample interval: 1 second;
- cleanup timeout: 45 seconds.

Change these only as a recorded successor/deviation if they materially affect the result.

## Automated observations

The runner records:

- effective Conduit task-control limit;
- task-control slots used;
- pending create reservations;
- queued prompt reservations;
- discovered provider sessions;
- supervised provider sessions;
- global provider-reported active-turn count when the full authority is knowable;
- exact provider-reported state for every qualification-owned task/provider-session binding;
- exact provider session IDs used for post-close reconciliation;
- provider host count;
- observed live child-process count;
- explicit UNKNOWN state for provider-neutral execution-slot occupancy;
- Fleet snapshot RPC latency;
- Fleet snapshot age;
- Conduit whole-process CPU;
- Conduit RSS;
- create latency and failures;
- close latency and failures;
- cleanup reconciliation.

Whole-process CPU is not main-thread CPU.

Session API latency is control-plane responsiveness, not GUI responsiveness.

## Main-thread and GUI evidence

Issue #44 remains a live risk. For each tier, record GUI responsiveness manually while the overlap window is active and through provider completion.

At minimum record:

- whether the main window remains interactive;
- whether switching/opening a task remains responsive;
- whether a post-completion pin occurs;
- whether closing a task changes the symptom.

The runner samples Conduit whole-process CPU. If it crosses the configured threshold, it invokes macOS sample and preserves the output beside the JSON receipt. Inspect that artifact for the main-thread stack.

If the historical pin reproduces, preserve the sample before changing code. Do not infer that non-reproduction proves #44 fixed.

A future successor may add numeric main-thread CPU instrumentation. Until then the numeric main-thread CPU field remains UNKNOWN.

## Tier disposition

A runner may report PASS_FOR_TIER_OBSERVATION only when:

- the live Fleet snapshot reported exactly the requested qualification limit;
- the clean Conduit task-slot baseline was established and no known background provider turn was active;
- all qualification-owned tasks were created;
- every qualification-owned task resolved to one exact provider session and every one of those sessions reported `active` during the overlap window;
- the overlap window was sampled;
- cleanup returned Conduit task-control occupancy to zero and direct observation of every qualification provider session reported `inactive`;
- no harness failure occurred.

This is only a tier-observation disposition. It does not select a production limit.

FAIL_OR_INCONCLUSIVE includes:

- effective limit mismatch;
- contaminated/non-zero baseline;
- known background provider activity at baseline;
- create refusal/failure before the tier is reached;
- missing, duplicate, or non-active exact provider binding for a qualification-owned task;
- provider-session state becoming materially unknown at the decision boundary;
- cleanup not reconciling both Conduit task slots and exact provider-session inactivity;
- transport failure preventing measurement.

## Slice 11 decision record

After 4, 6, and 8 are run, compare:

- GUI responsiveness;
- main-thread sample evidence when triggered;
- peak/shape of Conduit process CPU;
- peak Conduit RSS and available-memory trend;
- provider-host count;
- child-process count;
- create/failure/timeout rate;
- Fleet RPC latency and observation age;
- cleanup/recovery behavior;
- any #44 reproduction.

Select a maintained limit only in a separate bounded engineering decision after the evidence is reconciled.

A higher tier passing does not require raising the limit. A lower tier exposing a meaningful failure may justify keeping or reducing the current limit.

## Non-claims

This experiment does not establish:

- universal concurrency across all providers;
- provider-neutral execution-slot occupancy;
- absence of the intermittent #44 defect when it does not reproduce;
- correctness of agent outputs;
- objective acceptance;
- CAL Pipeline readiness.

Slice 12 remains separate.
