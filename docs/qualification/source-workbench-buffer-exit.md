# Source Workbench buffer-exit boundary

This Draft extends the frozen #129 Explorer Quit candidate for the separate
Source Workbench edit session authorized by #54, under #50 and #60. Its parent
is `0bc997d43b06b81867c9f7236c69493d585dbd00`, tree
`8f353046c6aba9dd4a71972ac5a520f9f7eba069`. Frozen #119, #124 and #129 remain
preserved. D-067 is Proposed.

Done, ordinary native Close and application Quit use the existing application
exit owner. One native Save/Discard/Cancel decision is pending at a time.
Successful Save uses the existing exact-file writer; failed Save retains the
buffer, current disk bytes and an explicit native failure notice. Quit makes
separate decisions for retained Explorer and every dirty source window. Native
Close waits for its exact decision sheet to end. A dirty source registration
retains its native close guard even if the guard representable dismantles.

## Evidence and falsifiers

Owner component hosts used the actual source-edit session, SwiftUI TextEditor,
close controller, native close guard and shared application delegate. Native
text insertion physically changed their bound buffers. Alert decisions used
visible enabled native controls, and checks read exact selected and adjacent
file bytes. Each disposable host had its own files and process; Cancel and
failure observations preceded exact owned process teardown. The hosts target
macOS 13 explicitly; native build metadata records that target on the macOS 27
host.

Before edits, frozen #129 allowed both native source-window Close and Quit to
terminate with a dirty Source Workbench buffer. The first repair wrote the
selected file correctly after Save but did not complete native Close while its
sheet remained attached. That failed source and trace were frozen before the
sheet-teardown successor.

An actual guard-representable removal exposed another defect: native Close hid
the dirty window before a decision, then last-window Quit reopened it and
presented a Quit sheet. An early broad outcome receipt passed because Cancel
ultimately preserved the buffer. Its raw trace and original receipt remain
preserved, with an explicit claim-boundary correction. The stronger frozen
control checks immediate dirty-window retention and exact Close sheet identity;
it failed on that source and passed after the registration retained its exact
native close owner. No oracle was weakened to obtain that successor result.

Final owner control groups are recorded separately in the machine receipt:

- Source window/Done/Quit: 220 checks across 31 physical scenarios.
- The unchanged guard-removal counterexample: 10 checks in one scenario.
- Additional guard-removal actions: 63 checks across six scenarios, including
  Save, Discard, failed Save, Cancel and Quit during a pending Close.
- Inherited Explorer native regression: 63 checks across eleven scenarios,
  using unchanged inherited controls on the successor source.
- Primary native Close composition: 49 checks across four scenarios, with two
  unrelated dirty source windows kept open for Save, Discard, Cancel and
  conflicted Save. Each decision used exact Explorer Close authority.

The broader source controls include clean exits, conflict/missing-file/symlink
Save refusal, repeated Close and Quit, failed-Save retry, wrong unregister,
window collisions, two source windows, and two source windows plus retained
Explorer. Original failed native attempts, nested sandbox refusal, signing
errors, disk-full attempts and their source identities remain preserved.

Repository-native `scripts/test.sh` passed 466 selftests, ten Python contracts
and 623 XCTest cases with zero failures and three explicit optional live-provider
skips. The two-job release build and unchanged maintained packaging script
passed. The uninstalled ad-hoc bundle passed deep strict signature verification
and records macOS 13 minimum deployment. Documentation was refined during the
first release compilation; every compiled source hash matched, and the later
maintained package run recorded stable documentation and source bytes.

[Machine receipt summary](source-workbench-buffer-exit-owner.json) binds the
owner groups, failed source snapshots, raw receipt hashes, compiled-source
hashes, repository commands and signed bundle identity. The raw failed debug
signing binary and all first failures remain in the private evidence store.

## Acceptance limits

These are owner component results. The full Source Workbench view, its Done
button, production WindowGroup, ConduitApp/AppModel, private MainFrame and
provider/runtime state were not mounted in these hosts. The Done control calls
the actual production close controller; it is not a claim about a mounted
button or keyboard binding. Guard representable removal is distinct from full
Source Workbench view or model dismantling.

Installed keyboard/Dock journeys, full view lifetime/context changes, restart
and integrated #87 isolation remain NOT_RUN/UNKNOWN. Fresh independent oracle
freeze and qualification remain separate required gates. Provider calls were
NONE; operator state, listeners, authentication and model defaults were not
used. Building a signed disposable bundle does not install or release it.

The candidate cannot close #54 or establish system-journey acceptance until
those separate gates have exact receipts. The raw evidence index is the
`source-workbench54-*` group in the private programme-run evidence store;
public metadata contains hashes and bounded dispositions only.
