# Owned descendant cleanup owner controls

The maintained #78 successor composes frozen #84's owned-descendant boundary
with the unmerged #123 owned-instance dependency. It remains a Draft until
separate fresh qualification and executed hosted checks establish acceptance.
D-063 is proposed. An owner run is not independent qualification or release.

The operation is the existing explicit `stop_provider_host` surface. Before
mutation it declares exact task, runtime attempt, launcher PID/start identity
and descendant PID/start identities. Only task-created descendants established
before the stop are candidates. Wrong or unknown scope, duplicate identities,
partial coverage and unknown ownership refuse cleanup. Historical unbound
targets remain readable and grant no signal authority.

A parent that is still live permits no descendant signal. The issued stop can
retain its exact in-memory intent for at most two seconds of monotonic polling.
A replacement runtime, changed identity or unavailable observation refuses the
continuation. A duplicate request does not create another continuation. Once
parent exit is observed, the planner is checked again against the original
declaration, then each eligible target receives one PID-specific SIGTERM after
fresh kernel start-identity comparison. There is no descendant escalation.
Topology is reobserved and a surviving child remains incomplete residue.
Read-only status refreshes preserve the last cleanup receipt within its exact
binding without repeating mutation. Startup does not restore signal authority.

This is bounded libproc observation followed by a PID-specific signal. It does
not claim an atomic kernel incarnation handle, provider completion, task
acceptance, durable restart continuation or a complete view of processes never
observed within the declared scope. Observed PID reuse or ambiguous liveness
fails closed. Exact microsecond-bearing start values remain in receipt evidence
alongside the typed target binding; ordinary ISO date rendering is not the
mutation oracle.

Portable coverage lives in `ProcessTreeCleanupTests`,
`LifecyclePreflightPlannerTests`, `ProcessTreeReconciliationTests` and the
matching self-checks. The opt-in macOS owner test uses only disposable bash and
sleep processes, an actual orphan and an unrelated disposable decoy:

```bash
CONDUIT_CLEANUP78_NATIVE_OWNER=1 \
CONDUIT_CLEANUP78_NATIVE_EVIDENCE="$qualification_root/cleanup78-owner.json" \
CONDUIT_TEST_TMPDIR="$qualification_root/tmp" \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
./scripts/test.sh
```

Create the task-owned temporary/evidence directories first. Compiler/package
cache and configuration directories must also be task-owned when this is run
in the operator environment. Keep HOME and CODEX_HOME unchanged. The test is
skipped by default and reports that absence explicitly.

Actual app owner checks require #123's paired reserved loopback port and marked
owned state root, a separate qualification bundle identifier, directly readable
disposable MainFrame fixture, owned absolute-executable Shell profiles and exact
PID/start teardown. The only enabled write gate belongs to that fixture.
Operator state, sessions, credentials, provider calls and tunnel activity are
outside the experiment. Native pressure covers delayed parent exit, duplicate
stop, repeated reads, a SIGTERM-ignoring child and a child created after the
declared scope. The last two deliberately end as incomplete residue/refusal;
the harness tears down those exact owned children and records its own signals.

Failed maintained candidates are immutable ancestry: the initial scope
transfer, first orphan fixture and actual pending-stop orphan failure have
separate receipts under `docs/qualification/receipts`. Repairs use new branches
and objects. Frozen #84 and #123 are never edited, and no historical receipt is
used as current signal authority.
