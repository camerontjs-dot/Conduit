# Slice 11 fourth-turn serialization boundary v1

## Work class

Research. This is the controlled successor owned by issue #76 after the terminal tier-4 result on closed Draft PR #74.

This record does not reopen PR #74, raise the shipped concurrency limit, authorize tiers 6/8, or authorize Slice 12.

## Decision

Determine where the observed fourth-turn delay is introduced for the tested four-session workload:

- Conduit task/control scheduling;
- OpenCode;
- the selected model/provider path;
- or another runtime boundary that remains unidentified.

The experiment may narrow that location. It does not need to produce a new concurrency limit.

## Starting evidence

OBSERVED:

- PR #74 is terminal and closed, not merged.
- Frozen terminal candidate: `22c8761ca355e22df50666703c54d4c46f0508d1`.
- Frozen terminal tree: `ca6c0a58b10bd2daeaff9dbb4928881689e397f8`.
- Slice 11 protocol at that candidate: `docs/qualification/concurrency-qualification-v1.md`.
- Protocol SHA-256 recorded by the terminal receipt: `8083c47ebc62733bfa6d1018a9f51e4a46c02a3218bd815423c43ebe2fddce36`.
- Terminal receipt: PR #74 comment `5826117332`.
- Four Conduit task creates succeeded.
- Maximum exact simultaneous provider-reported active sessions observed was 3/4.
- Post-close exact provider-session inactivity remained UNKNOWN.
- Tiers 6/8 were not run.

INFERENCE:

- The tested run did not support a four-way active-turn claim.
- The run did not identify which scheduling/runtime layer caused the fourth session not to be observed active.

UNKNOWN:

- Whether direct OpenCode with the same workload/model also fails to reach four simultaneous active sessions.
- Whether an alternate independently usable provider/model reaches four under the same workload.
- Whether the original fourth-turn observation is stable on reproduction.

## Frozen comparison

Run the smallest comparison that can discriminate issue #76.

### Arm A — Conduit path

Reproduce the four-session Conduit → OpenCode → Muse workload using the frozen PR #74 research apparatus and its existing tier-4 settings.

Keep:

- target = 4;
- hold = 45 seconds;
- streamed response = 160 numbered lines;
- active acquisition timeout = 75 seconds;
- overlap sample window = 15 seconds;
- sample interval = 2 seconds;
- no repository mutation by the workload.

Do not run 6 or 8.

### Arm B — direct OpenCode path

Remove Conduit as scheduler. Start four independent OpenCode sessions directly, using the same project/workload/model/provider and timing as Arm A as far as the provider interface permits.

Record exact provider session identities and timestamps for:

- session creation;
- prompt acceptance;
- first assistant activity;
- tool/sleep start if observable;
- provider active/busy transition;
- completion/idle transition;
- cleanup.

Do not infer an active state from process existence or quiet output.

### Arm C — provider/model discriminator

Only if an alternate provider/model is already independently usable without changing account/authentication policy, repeat the four-session workload through the Conduit/OpenCode path while holding the protocol constant as far as practical.

If no such provider/model is available, record Arm C as unavailable. Do not create credentials or change product defaults to manufacture this control.

## Hard protocol

1. Preserve PR #74 and its receipts unchanged.
2. Use qualification-owned tasks/sessions only.
3. Do not stop, mutate, adopt, or reuse unrelated operator/provider sessions.
4. If unrelated active work cannot be mechanically excluded from the tested resource/provider path, mark the affected arm contaminated.
5. Pin the exact Conduit commit, OpenCode version, selected model/provider, project/cwd, and any temporary harness before each decisive arm.
6. Keep the workload and timing fixed across A/B except where the removed Conduit layer makes a field inapplicable.
7. Preserve provider state, process state, Conduit task state, and objective acceptance as separate authorities.
8. Missing provider state stays UNKNOWN.
9. Preserve the first result of every arm.
10. Do not modify the apparatus after seeing a decisive result and count the repaired run as the same arm.
11. Do not run tiers 6/8.
12. Do not change the shipped live-task limit of 4.
13. Do not change CAL contracts or start Slice 12.

## Operator-process isolation

A live operator Conduit instance or unrelated live OpenCode work is not experiment apparatus.

Do not terminate or repurpose it merely to free `:8750` or execution capacity.

If Arm A cannot be isolated without touching unrelated operator work, report `BLOCKED_OPERATOR_ISOLATION` for the decisive comparison. A later clean execution is a new run, not a continuation hidden inside the blocked attempt.

## Interpretation

- If Arm A reproduces max 3/4 and Arm B also fails to reach four under the paired workload, the result is evidence against Conduit task scheduling as the sole limiting layer. It does not by itself distinguish OpenCode from the model/provider.
- If Arm A reproduces max 3/4 while Arm B reaches four exact simultaneous provider-active sessions, investigate the Conduit adapter/control path.
- If the Muse path fails to reach four while a controlled alternate provider/model reaches four, the constraint localizes toward provider/model-specific behavior or provider-specific OpenCode handling.
- If Arm A itself reaches four, the prior fourth-turn phenomenon did not reproduce in this run. Do not retrofit a bottleneck conclusion; preserve the non-reproduction.
- If active-state authority is missing or contaminated at the decision boundary, the arm is inconclusive.

## Required receipt

For each arm preserve:

- exact code/apparatus identity;
- environment and runtime versions;
- exact provider/model identity;
- exact task/session IDs;
- start/end timestamps;
- per-session state-transition timestamps;
- maximum exact simultaneous provider-active count;
- process observations where relevant;
- contamination/deviation record;
- cleanup result;
- raw artifact hashes;
- bounded arm disposition.

Then write one comparison conclusion with OBSERVED / INFERENCE / UNKNOWN / NON-CLAIMS.

## Terminal states

Allowed states:

- `SUPPORTED_WITH_BOUNDS` for a localization claim that the paired arms actually discriminate;
- `INCONCLUSIVE`;
- `BLOCKED_OPERATOR_ISOLATION`;
- `CONTAMINATED`;
- `NEW_EXPERIMENT_REQUIRED`.

A result is not permission to change the shipped concurrency limit.
