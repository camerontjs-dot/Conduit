# Session API replay follow-up: independent source-review counterexamples

19 October 2026. Source implementation and negative-review record, not
installed qualification.

Frozen first repair commit: 58e095d6dd5a6cac2a3534c2ed9b6bcc063b1eea,
tree 0e5b9fa94e1395a1c9e9919d27a60b5120f9ee6b.
Original independent pre-source A1-A6 protocol SHA-256:
3a7f0be7b657cf6a859a6e9bf2854350da42284b90364beac329315e01bb2753.
Independent source-review FAIL report SHA-256:
14b2b1e1fa40072f37d7e0f34ec4d7df05fa5067e16d0a4ea921b9805f5d3e13.
Preserved GitHub review: PR #177 comment 6274450632.

The source review found that another client's initialize replaced
listener-global clientInfo. The journal used clientInfo as its caller identity,
so a lost-response keyed retry could miss the original receipt after that
second initialize. This follow-up binds journal replay to one immutable local
bearer authorization domain shared by clients of the same Conduit listener.
It does not claim authenticated per-client identity. Adversarial MCP parser
tests reproduce A initialize, accepted send K, B initialize, retry K, and a
changed-text conflict on K. No real project or provider participates.

The reviewer also found a ready structured-provider send failure recorded as
delivered false with no API error. A pure Core response helper now returns a
bounded error, immediate failed delivery marker and original event ID when
the structured adapter returns false; MCP marks the tool result an error.
Provider partial acceptance remains unknown. Inspect events before resending.
Pure Core and injected MCP transport tests exercise this response, not an
actual StreamJSON provider turn.

No installed-app acceptance, service restart, permission increase, merge or
release is authorized by this source repair. Preserve the old failed exact SHA.
