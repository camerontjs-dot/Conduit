# Owned qualification instance

This #87 source successor allows a disposable Conduit app to use its own state
and loopback listener. Ordinary launches retain `~/.conduit`, ordinary UI
preferences and port 8750. Qualification is selected only by the paired variables:

```bash
CONDUIT_QUALIFICATION_ROOT=/private/tmp/example-owned-root \
CONDUIT_SESSION_API_PORT=18750 /exact/candidate/Conduit.app/Contents/MacOS/Conduit
```

The example paths are placeholders. A real receipt records the exact checkout,
source head/tree, built artifact, PID, state root and selected port. Do not assign
HOME or CODEX_HOME for this mode. The port must be a canonical decimal integer in
18750–18849. Invalid, missing or mixed configuration exits 78 before operator
fallback. A listener collision reports failure and does not choose another port.

The root must be an absolute POSIX-canonical path, separate from the operator
home and `.conduit` tree, with no symlink ancestors. A new or empty owned root is
marked with `qualification-root.json`; a reopened root needs the exact typed
marker, UID ownership and regular, unlinked artifacts. Inspection has a 10,000
entry bound. Foreign state, a symlink or a hard-linked file is refused. A process
lease prevents a second qualification app from adopting the same marked root.

Settings, preferences, API token, adapter thread records, task and conversation
logs, worklog, attachments, context bundles and snapshots stay under that root.
UI preferences use the same private file-backed UserDefaults interface as
AppModel. A configured fixture MainFrame directory must be inside the owned
root and directly readable. It is activated without a security bookmark; copied
bookmarks and automatic session restoration are disabled.
A fresh root has no MainFrame configuration and no listener until its own
settings explicitly enable the API. The separate API write gate stays off by
default.

Qualification startup skips login-shell environment probing, shared tmux
inventory, provider health/account/model/resource probes and automatic tunnel
control. Slash-command home fallback, MindGraph cache/binary fallback, Grok home
dotenv access and OpenCode default database discovery are isolated or refused.
An OpenCode observation requires an explicitly selected regular owned database
inside the root. These settings authorize no real provider turn, account access,
credential change, installation or release. Later provider execution requires its
own isolated session, authority and spending decision.

## Evidence and lineage

Frozen #91/#92 supplied predecessor port/isolation experiments at older objects;
those objects are not modified or consumed as current-source qualification. The
first maintained candidate `cc531dbcda2ec6b192b419cfec4b34e5e7a05020` failed actual
startup with a valid pre-created root because Foundation normalized a canonical
`/private/tmp` path to `/tmp`. Its source and failed receipt remain preserved in
`receipts/isolation87-initial-native-fail.json`. The separate POSIX successor adds
an existing-marker reopen regression, keeps its first red result and refuses a
boolean schema marker rather than coercing it to integer authority.

The POSIX predecessor `da336dbe8fbbdd26e862c72b83f898672865f411` then
failed the owned-fixture readiness check: the listener was reachable but `/readyz`
returned `503 mainframe_authorization_required`. The separate bootstrap successor
uses only the already validated directly readable fixture and requires the native
`200 ready` response plus its project inventory. See
`receipts/isolation87-posix-bootstrap-fail.json`; the earlier twelve passing
controls do not supersede this wider-boundary falsifier.

Repository-native tests, strict signed build and disposable actual-app checks
are implementation-owner evidence. The exact frozen successor still needs a
fresh independent qualifier with its own oracle. This seam alone makes no
provider lifecycle, task completion, HTTP write acceptance, cross-lane composition
or release claim. Repeated runs use new evidence files and exact owned teardown;
a failed candidate is repaired in a separately identified successor.
