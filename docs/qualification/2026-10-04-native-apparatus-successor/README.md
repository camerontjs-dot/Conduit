# Local native apparatus successor — 2026-10-04

Work class: **Research Infrastructure / qualification apparatus**.

This packet does not change Conduit product behavior. It freezes one bounded successor apparatus for the two exact product candidates whose first full-native attempts stopped in the same existing Unix-socket test for environment/apparatus reasons.

## Decision

Determine whether #150 and #151 pass the maintained full-native/package gates when the known local Unix-socket apparatus hazards are removed without changing either candidate.

A successful apparatus run supports only the tested candidate and gate. It does not create independent qualification, mounted acceptance, provider behavior, release readiness, or acceptance for another branch.

## Frozen subjects

### #150

- PR: https://github.com/camerontjs-dot/Conduit/pull/150
- commit: `09833f6a2631675d6b1cb9863229f10a821d1d5b`
- tree: `454afd8bc7a2c0e4ea2db1aaa35e7efc83b28b37`
- first focused result: 14 XCTest / 0 failures
- first SelfTest result: 593 / 0 failures
- Python contracts: 10 / OK
- consumed full-native attempt: exit 1 after 660 XCTest / 3 explicit skips
- preserved apparatus failure: `socketPathTooLong` plus consequent unwaited expectation in the existing ShellTelemetrySocketServer test
- local return receipt SHA-256: `d876cacbf684a1e07b2dbc5efa60e039e6c382090b85276c54c5bc563f2621f1`

### #151

- PR: https://github.com/camerontjs-dot/Conduit/pull/151
- commit: `0ef7979f16ade58fc1146125b808876096510935`
- tree: `4a35035c040b1dd097e579edf04c195ba0c9e119`
- first focused result: 8 XCTest / 0 failures
- first SelfTest result: 468 / 0 failures
- Python contracts: 10 / OK
- consumed full-native attempt: exit 1 after 611 XCTest / 3 explicit skips
- preserved apparatus failure: default local sandbox refused owned Unix-socket `bind` with `posix("bind", 1)`, plus consequent unwaited expectation
- local return receipt SHA-256: `237b0c53f575fabdbe88b1159f58177647bdb04c6d7c11a13ec480a3a08897fa`

The failed attempts remain evidence. This packet does not relabel or replace them.

## Hard apparatus boundary

For each subject:

1. Verify exact commit, tree and tracked source before execution. Dirty, mismatched, missing or unreadable source is BLOCKED.
2. Use a fresh, owned, **short** temporary/build/cache root whose resulting Unix-domain socket paths remain below the platform path limit.
3. Keep operator Conduit state, installed app state, provider sessions, credentials, account configuration and unrelated worktrees outside the apparatus.
4. The local operator may use the same **bounded sandbox escalation already used successfully for the owned Unix-socket tests in #152/#153**. The escalation is apparatus authority only:
   - it applies only to the owned candidate build/test process and owned Unix-socket fixture;
   - it grants no provider, network, account, installation or operator-state authority;
   - record the exact command/flag/environment that implements it.
5. Do not change product source, tests, fixtures, expected results or the frozen subject after execution begins.
6. Preserve stdout, stderr, exit status, process wait, source pre/post custody and owned teardown.
7. Each subject receives **one successor full-native attempt under this apparatus identity**. Do not loop or silently alter apparatus after observing its result.
8. Run package/release/signature checks only if that subject's full-native gate passes. Preserve the first release-producing bytes before packaging where the maintained procedure makes that distinction material.
9. Do not install or launch the app. Do not execute a provider turn.

## Interpretation

Classify the successor result as one of:

- `PASS_BOUNDED_NATIVE_AND_PACKAGE` — full native passes and the bounded maintained package/signature checks pass.
- `PRODUCT_FAIL` — the exact candidate violates a maintained assertion or behavioral gate under a valid apparatus.
- `APPARATUS_FAIL` — the apparatus/environment prevents the intended measurement.
- `BLOCKED_SOURCE_CUSTODY` — exact source identity cannot be established.

An `APPARATUS_FAIL` ends this packet. Preserve it and return the smallest raw reproducer. Do not create a third attempt under this apparatus identity.

A `PRODUCT_FAIL` returns to the GitHub implementation lane. The tested candidate stays unchanged.

## Required return

For each subject, return:

- exact candidate commit/tree tested;
- source pre/post custody result;
- actual toolchain/environment relevant to the gate;
- exact commands/argv and material environment;
- full-native counts, skips, failures and exit status;
- package/release/signature results if reached;
- first release/package artifact hashes if reached;
- owned process waits and teardown;
- any deviation from this packet;
- bounded disposition above.

This is source-exposed owner qualification apparatus. It does **not** claim fresh independence.
