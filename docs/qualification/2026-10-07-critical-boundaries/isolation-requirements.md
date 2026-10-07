# Isolation subject: requirements for independent oracle derivation

Decision: whether the unchanged #123 candidate provides a bounded foundation for
isolated native qualification without displacing or adopting the operator instance.
This is not an operator installation, release, provider acceptance or #128 composition.

## Input and launch authority

An experimental launch is explicit: `CONDUIT_QUALIFICATION_ROOT` and
`CONDUIT_SESSION_API_PORT` form a pair. The root is an absolute canonical path outside
the operator's normal Conduit state. The port is an unambiguous decimal integer in
18750...18849. Partial, malformed, unsafe or conflicting configuration must fail
closed rather than fall back to ordinary settings, state or the operator port.

The root must be new/empty or carry the correct typed ownership marker for that
canonical root. Foreign state, mismatched identity, unsafe symlink/hardlink paths or
incorrect ownership must not be adopted. A second simultaneous application must
not acquire the same root. Root inspection is bounded to 10,000 entries rather than
recursing without a limit. File/state identity and permissions must be meaningful,
not an assumed consequence of a directory name.

## Isolation and readiness

Qualification state, settings, preferences, conversations, task logs, API token and
other Conduit writes must remain under the explicit owned root. HOME/CODEX_HOME are
not reassigned. The operator's preferences, bookmarks, tasks, sessions and workspace
must not be imported into a fresh root. Restarting an owned root may recover its own
settings; it must not recover unrelated work.

No automatic provider health probes, provider turns, tunnels, session restoration,
MainFrame discovery or external bookmark resolution may run merely because the
qualification app starts. Missing configuration remains missing. Source-reviewed
launch traps and bounded protected-state inventories must expose unintended work;
absence of a provider response is not evidence that no call was attempted.

With API disabled in a fresh root, do not infer that a listener exists. With the
owned API explicitly enabled, bind only the reserved port. An occupied port must
not cause a fallback bind. A listener is not the same as configured readiness.
An absent MainFrame configuration must remain unavailable; a valid synthetic
MainFrame fixture explicitly inside the owned root should be available. A configured
external fixture must be rejected, not silently adopted. The read surface must not
expose operator tasks. Keep the API write gate disabled and verify that a write
request cannot create a task.

## Required strength of evidence

Exercise an actual separately built application/owned listener for these properties,
not only the configuration parser. Include controls that distinguish empty, owned,
foreign, malformed, occupied, conflicting and unavailable states, plus an ordinary
valid positive. Preserve exact source/build/configuration/fixture/port/PID identities
and raw responses. A control whose condition was not actually established is not a
passing negative. Teardown must release only owned processes and resources.

Report the defined protected-state comparison, not an unsupported whole-machine
noninterference claim. Any unintended operator adoption/write/provider launch,
identity drift, unsafe fallback or incorrect readiness weakens or falsifies the
corresponding property. Missing authority, invalid apparatus or unavailable isolation
blocks the affected claim. Passing does not qualify another source tree.
