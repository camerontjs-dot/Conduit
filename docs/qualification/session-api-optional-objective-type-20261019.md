# Session API create-task optional-objective validation

Date: 2026-10-19. Source-only engineering test and review handoff, not a
release, installed execution, or independent approval.

Frozen original independently failed commit:
f647c84819f32ecbbdb5e96d2021434279718308
(tree 840e7120f5029d36af2440c1f8947eb1ff6983cf).
Astra source-review report SHA-256:
41bc2a2e95be30cf2de020280bdd00950c80cf6ad2599df89146abb59afda6ae.

The MCP tool schema declares objective to be an optional string. Its parser
previously used objective.stringValue ?? "", turning a supplied numeric,
boolean, null, object or array into a valid omitted objective. A valid
agent/project then reached task creation. This is distinct from omitting the
optional objective, which must remain a supported empty string.

A new in-process HTTP/MCP transport XCTest uses an injected handler (never
starts a real task), supplies five wrong-type objective values, and requires
every response to be an MCP error with no handler invocation. It also
checks that an omitted objective still creates an empty-objective command.

RED on the frozen parser: one XCTest executed, 12 failing assertions.
Raw log SHA-256:
9b7d93efc4091464f6ed2e3e45ce081c27743bff0597b48afc5f227f8b40e1b6.
GREEN after smallest parser guard: same test passes, raw log SHA-256:
a8f246fbb51895c0bb06838562637e6226647bf59183f140c7063d5c33c33a68.
Surrounding SessionAPIReplay native suite: 21 passed, raw SHA-256:
9c1a9b60929d9be8bf4fe247d8276e91a43ebfa24e0a334129ae75442698d731.
Python contracts: 30 passed, SHA-256:
d0caf3a725487a92056c0756ced0078732c5afa50c50090872bc49c95a2279bb.
Existing native selftest: 559 passed, SHA-256:
ddb1659bd561b75d1476a7103ca9a923dd2611f6e935561b4f61a05cc720674b.

Tests ran offline in an ignored disposable SwiftPM package with physical
source/test copies. Raw traces are kept outside tracked source. No full native
suite or release build was rerun after this narrow parser correction; GitHub
exact-head CI and a fresh independent reviewer are required. Original
capacity/unknown-replay failures remain preserved in prior records. Real
operator projects, provider work, installed Conduit UI, authenticated hosted
client, power-loss cases, signing, merge, installation and release are NOT_RUN.
