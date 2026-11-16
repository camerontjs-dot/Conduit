# Repaired owner: real-VM development result

The repaired owner passed the declared native campaign: five real VM boots,
eight stale/mismatched acknowledgement denials, and four further fresh-ticket
denials. The default owner emitted one timeout notification and exited by
SIGTERM. Its guest stop remains UNKNOWN and its slot stays held.

Tested source is unchanged [Draft #197](https://github.com/camerontjs-dot/Conduit/pull/197),
commit `7940d45de9fe2d812e026d7d6b5488d32701413e`, tree
`bdb6ba62f74c5db83f31d6029ffc76f7f1968597`. This record adds no product code.
The source manifest in the private protocol binds all 489 tracked inputs;
the [timeout witness manifest](timeout-witness-candidate-files.json) identifies
the repaired owner and 15 unchanged authority/denial/slot/oracle inputs.
VMRunner source SHA-256:
`9354533a1ab863bcc6f20f9a4016a44236e2231928c9587cefe0e14a7bc0e819`.

## What ran

This was source-exposed development testing on arm64 macOS 27.0 / 26A428,
with Swift 6.3.3 and explicitly selected Xcode/SDK. A fresh ConduitCore build
produced 115 objects from the exact source. It reused copied, pinned
dependencies. Only owned fixture actuators received the virtualization
entitlement; no app was built, installed or launched.

The diskless Linux Bash/grep fixture retained its existing profile: one CPU,
128 MiB VM memory, 32 MiB job memory, 16 job tasks, declared CPU/wall/output
budgets, and no NIC, disk, host share or socket device. Guest policy and
denial controls were byte-identical. The permitted workflow inspected,
searched, edited and checked the disposable project, then inspected the
result. It returned stdout `sample check passed\n`, empty stderr and exit 0.

| Operation | Host result | Native owner result | Guest stop / slot |
| --- | --- | --- | --- |
| Completion control | Exit 0; cleanup observed | Exit 0 | Observed / slot unused |
| Older acknowledgement control | Timed out; cleanup observed | Exit 124 | Observed / acknowledged |
| Current acknowledgement control | Timed out; cleanup observed | Exit 124 | Observed / acknowledged |
| Matching acknowledgement admission | Timed out; cleanup observed | Exit 124 | Observed / acknowledged |
| Default owner loss, last | Timed out; cleanup observed | Signal 15 | UNKNOWN / held |

All four timeout notifications reported the matching owner/PGID/nonce while
the VM was running. Each cooperative callback observed native `.stopped`
before writing its acknowledgement. The three TERM-to-stop observations were
about 7.27, 5.33 and 3.64 ms; these are local observations, not a benchmark.
Every native child was reaped with both stream EOFs and complete capture.
All five raw captures passed the unchanged 29-condition guest oracle.
Those 145 condition observations are not 145 independent trials.

## Acknowledgement controls

One new private slot served the four timeout operations. After two genuinely
observed stops, the unchanged matrix tested missing-current acknowledgement
with an older record present, older bytes at the current name, a wrong
operation, and a wrong initramfs digest. Each condition refused twice before
VM configuration/start. Only restoring the genuine current native-produced
record admitted the same waiting ticket and runner once.

Default owner loss then wrote no stop acknowledgement. Host capacity was
released, while host receipt retries returned the original operation and
the exact native ticket was refused. Two distinct fresh native tickets each
refused twice, with zero new configuration/start/claim and unchanged slot
records. These last four attempts exercise the direct native gate; they do
not constitute another adapter campaign. The new slot retains seven
records and one unmatched claim. Prior held slots are unchanged.

## Failures, checks and limits

The first preparation attempt stopped before compilation/VM execution
because copied dependency metadata retained read-only permissions. A
separate copied environment corrected only its owned metadata; the failed
setup remains retained. A post-run reporting assertion initially compared a
native-capture digest with an executable digest. The retained failure and
corrected join now check executable, native capture and serial identities
separately. Neither correction changed the tested source or denial oracles.
An initial custody diagnostic also flagged its own new receipt directory;
the failed diagnostic and exact ownership-accounting correction are retained.

Twelve unchanged receipt regressions passed using the fresh completion
capture. Full local XCTest/Python/package suites were not rerun for this
documentation-only follow-up; exact #197 hosted CI passed and remains
separate source/package evidence. Source-exposed engineering review found
no material source or evidence concern; it is not independent qualification.
All original D11 failures and D12 no-VM results remain unchanged.

The bounded M2 native development gate passes this campaign. The original
VM failure's precise cause and cross-run failure frequency are not
established by one repaired campaign. Final live guest-job reaping remains
unobserved. Exact acknowledgement matching assumes a trusted same-user host;
it does not authenticate stop against a compromised host.

Operator app/config, public `execution_authority_unavailable` guard, frozen
candidates and original work remain unchanged. Product profile approval,
independent/installed acceptance, #168 → #123 → #128, #142 HOLD and #174
remain separate. Review the exact source/evidence before any promotion.
No installation, merge, release, old R3 trial or M3–M6 work follows.
