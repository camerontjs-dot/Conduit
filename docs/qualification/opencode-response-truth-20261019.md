# OpenCode response truth: bounded source repair

2026-10-19. Development evidence only; not independent qualification or approval.

## Source custody and scope

Branch `repair/opencode-response-truth-20261019` started clean at exact parent
`f8bc0ccf054549a4c2f51e7a0f80e821dc1f2e70`, tree
`d561a5e4e74f695a293e1696615a6f397403815e`. HEAD and index remain unchanged;
this repair is an uncommitted worktree. Original source is preserved in a local
parent archive, SHA-256
`abd8e7f338595a319442f2bac757081127bdd800b164886f86f12c9f76a2e002`.
Raw logs, the first failing test patch, offline invocation wrapper, and source
manifest are retained under ignored `.build/repair-evidence/` in this worktree.

## Changes and boundaries

- A: `OpenCodeEventMapper.accept` binds the exact assistant identity, then records
  a non-null response `info.error` as an identified failure and closes that
  message. The client emits it before replay, retaining prompt/session/message
  identity. HTTP 2xx still means transport delivery; application failure does
  not become HTTP refusal. No response text or completion is synthesized.
  Buffered and subsequent completion cannot override this error.
- B: `TerminalRuntime.wireStructured(OpenCodeHTTPClient)` guards `onExited` with
  the same current-client instance check as effects. The synthetic lifecycle
  fixture invokes the actual captured callback after replacement, verifies a
  running replacement and live output remain unchanged, and checks that the
  current client's exit still works.
- C: the URLSession stream now uses the same byte ingress as native fixtures.
  `OpenCodeSSELineDecoder` rejects byte 2,097,153 before UTF-8 decoding, discards
  its accumulator and remains failed. LF, CRLF, CR, Unicode text and the final
  unterminated line are tested. Overflow invalidates event authority, clears
  pending events and reports UNKNOWN. The existing 2,048-event / 2 MiB pending
  JSON limits remain. This is a Conduit accumulator bound, not a bound on
  URLSession internal buffers or HTTP response bodies. No reconnection or new
  multiline SSE assembly semantics are introduced.
- D: no exact delta deduplication claimed or implemented. Read-only inspection of
  the local embedded OpenCode schema found
  `message.part.delta` fields `sessionID`, `messageID`, `partID`, `field`, `delta`;
  none identifies an individual increment. Binary SHA-256:
  `8825dddf0c894be1afd7abe574da8d399eba268e93d43e3242eb0ba3d7086e41`.
  Native regression preserves two identical `ha` deltas as `haha`. A provider
  event ID/offset/replay authority contract remains unresolved; schema inspection
  is not proof of live delivery behavior.

Existing early buffering, P1/P3 isolation, exact message/session binding, and
origin/approval separation continue through the native regression suite.
CHANGELOG and D-065 record the semantic changes. The conformance catalog changes
only two source hashes; no provider capability or qualification claim is upgraded.

## Execution, including first failures

All SwiftPM resolution used local mirrors of existing pinned Git checkouts:
SwiftTerm `58915b1010d7dbc86d0e79dc2c40f0c183ccaf5b` and swift-argument-parser
`6a52f3251125d74daf04fcbd5e6f08a75d074382`. Package manifests and lockfile are
unchanged. Xcode was selected through `DEVELOPER_DIR`; the compiler module cache
was under `.build/`. The local `swift` wrapper adds `--disable-sandbox
--skip-update` to the script's Swift invocations. No network dependencies or
provider processes were used.

1. Before production edits: `swift test --disable-sandbox --filter
   OpenCodeSSEIdentityTests` ran four tests, six failed assertions. A replayed
   buffered output as completed despite HTTP `info.error`. The initial B fixture
   was idle and its positive control failed; that original log/patch is preserved.
2. After marking the synthetic adapter hosted/running, still before production
   edits: `swift test --disable-sandbox --skip-update --filter
   OpenCodeSSEIdentityTests` ran four tests, seven failed assertions. A reproduced
   false completion; B reproduced the stale exit changing lifecycle. This is the
   behavioral RED used for A/B.
3. `python3 -m unittest discover -s Tests -p test_opencode_response_truth.py`
   failed both new contracts before implementation. C's first native decoder run
   failed compilation because the decoder did not yet exist; this is explicitly
   a compile RED, not an oversize behavioral RED.
4. Initial `swift test --disable-sandbox --skip-update --filter OpenCode`:
   39 executed, 36 passed, three live-fixture skips, zero failures.
5. First `./scripts/test.sh`: 569 selftests passed, then two Python failures due
   to stale source artifact hashes. Preserved before refreshing only those hashes.
6. Full `./scripts/test.sh`: 569 selftests and 29 Python tests passed. XCTest:
   762 executed, three skips, two failures in the single local socket test:
   `ShellTelemetrySocketServerTests.testPrivateZshHooksAuthenticatePeerAndRejectForgedOrOutOfOrderFrames`.
   First failure: `posix("bind", 1)` (EPERM); second: unwaited expectation
   `validated shell events`. This full run is **not green**.
7. `./scripts/test.sh --skip
   ShellTelemetrySocketServerTests.testPrivateZshHooksAuthenticatePeerAndRejectForgedOrOutOfOrderFrames`:
   569 selftests and 29 Python tests passed; 761 native tests executed, 758 passed,
   three skipped, zero failures. The final lifecycle fixture waits for observed
   HTTP acceptance rather than a fixed number of task yields.

8. `swift build -c release --disable-sandbox --skip-update`: passed in 97.98s.
   Release executable only; no app packaging, explicit codesign or installation.
   `.build/release/Conduit` SHA-256:
   `e597952a690a22131c0674d07badcc73ff782075386a11c4909aff8c2d5949c8`.
9. `git diff --check` passed. Added-line scans found no host paths or credential
   patterns (bounded pattern check, not a secret-scanner certification). HEAD and
   index are unchanged.

The three opt-in skips are the installed OpenCode authority journey, installed
OpenCode persistence, and live shell/OpenCode correlation. Their qualification
flags and isolated fixture prerequisites were deliberately not provided.

## NOT_RUN / disposition

No GitHub reconciliation (explicitly prohibited), commit, push, merge, approval,
installation, explicit bundle signing, running API/tunnel/write-gate/credential mutation, live
provider call, live provider project, or installed-app verification. Standard
`build-app.sh` is not run because it signs a bundle. Exact-head macOS CI and
independent installed/runtime qualification remain NOT_RUN. Source fixtures do
not establish real provider ordering, restart behavior or app usability. D's
replay identity boundary remains unresolved.

## Payload and raw-log hashes

The manifest below identifies the final source/test/documentation payload used
for the bounded full rerun and release compilation, excluding this receipt itself.
Manifest SHA-256: `fe72f9666cf763798fb997135e42cb1b001a4b8173421241733384d2f48d26ad`.

```text
f856ed77503ce4cc9af0d4a7fba7586409a7498493b74741e808a3a104ba0aa8  CHANGELOG.md
b9374a706386a716f4214928f4284188d9da4d57b25e554b5501a4490d523740  DECISIONS.md
05d49862984083c9dd2e73c299cbef819e13a8007a8ea7af0289695e0866f651  Sources/Conduit/AppModel.swift
df4dea63b5592533fb5ad254c3297d1c732d1d970e49b9ecff02fa00eda20f81  Sources/Conduit/OpenCodeHTTPClient.swift
1ed81f3caa006e0c4dbd9282907cf861b3dfa1592632063b6106eafa20aa668f  Sources/ConduitCore/OpenCodeHTTPProtocol.swift
edc10803399c5e4916071600bc75bf582edb526ac730fa5a29245702135a580c  Sources/ConduitSelfTest/OpenCodeIdentityChecks.swift
d7d29ffd2b1536161f9a49f4ef9b748b6f4e9ccd032975ca4c0eb3ba5954f9de  Tests/ConduitCoreTests/OpenCodeIdentityTests.swift
8c3a2ee76d507ca7544df8731c1779e0235cf4315c8312c385957e604a4d95df  Tests/ConduitCoreTests/OpenCodeSSELineDecoderTests.swift
5353e3b785be96eb105ef59887fb2ee480bd0def005f4c6bbd714b410bfa3482  Tests/ConduitSessionAPITests/OpenCodeSSEIdentityTests.swift
709844a59337cac4d0958d80109d902e6bd8fa423a45ad1138f9d660c4b6d020  Tests/test_opencode_response_truth.py
29282cc9a259dd7b7d5cf23c9157504e65e6c99da71208e74e91f4da37f09734  docs/qualification/provider-conformance-v1.json
```

Local raw-log SHA-256 receipts (logs retain the original machine diagnostics):

| Log | SHA-256 |
| --- | --- |
| 01-red.log | `87ff85c2dbe5b5f6f61ce9259d80e4c63f55aae37b31136d00332d993bb2d931` |
| 02-red-contract.log | `7cdf39591f14b886c740dd09ef53d900aa1450dbfd402a673da68ce296baa048` |
| 03-red-native.log | `e9711e08a72558dfe4741547a38585983c3b0147b16c43e28b27c6cad5276673` |
| 04-red-decoder-compile.log | `b0e41b9cfb33bd06f1e87d3c7dfc8a6505938b879ae453caadfc836d052e9a1a` |
| 05-focused.log | `699db3d8f4eb8b7ba90839b086cd71e8464e43682d733ee4047e8ab938bb62be` |
| 06-full-suite.log | `b11523f59948b6c5f667f66e1a0792e58d36e9a2deb34e60c71e935d7024512c` |
| 07-full-suite.log | `56770d419a0d507b2bf297b292ee71b6a9f1aa0cf4fd8acdf2fab11509aac55b` |
| 08-suite-excluding-blocked-socket.log | `a49c9af62aed04df0d591c95c1780359fc1eae9418d585f66851ee4e86f80477` |
| 09-unsigned-release.log | `367294649dd9bf9f297b5a1ddc5967eeceeb95a99ca6ca2d0aef8f00fad75844` |
