# OpenCode SSE request identity source repair

Date: 2026-10-19. Source development receipt only; not independent or installed qualification.

## Behavior and authority

- Frozen parent commit eab7e63fd94b777d1eeb5f8e08f6a163dce42bc3, tree d292490121286b7597b2ed5d08806e0e18d380ff.
- Original source misattributed an older OpenCode assistant SSE message or completion to a newer pending prompt in the same session.
- The replacement binds output to the assistant message ID/session from the exact request HTTP POST response. Incoming SSE before HTTP is buffered to an explicit size/count bound, then accepted only when message and session identity agree. Wrong, missing, duplicate, stale, stopped or unproven identity means UNKNOWN; it never establishes the current prompt output or completion.
- HTTP 2xx is transport admission evidence only, not provider turn completion. Multi-message assistant turns remain unqualified rather than inferred from session or wall-clock ordering.

## Negative and positive execution evidence

- First offline native RED: one test, 11 assertions failed, first because delayed P1 output created P3 output.
- Final focused native: 24 passed, zero failures. Synthetic HTTP transport plus actual SSE parsing and mapper used.
- Selftest: 563 passed. Python source contracts: 27 passed.
- Full native: 753 executed, three opt-in skips, two failures from local socket bind EPERM and unwaited test expectation (preserved, not green).
- With only that exact blocked socket test excluded, 752 executed, 749 passed, three skipped, zero failures.
- Unsigned release build passed without app installation, code signing or provider launch.
- Initial source/test compilation failed because CodexJSON is not Encodable; corrected with its existing jsonObject representation. Initial SwiftPM network resolution was blocked and pinned offline checkouts were used instead.

## Local raw log SHA-256 receipts
- 02-red-native-offline.log: 327faf4bdb6de725c9028eeb15267243f4324672d9405ec63218b6696d0b0821
- 04-focused-native.log: e0c3eb71381794677f2e13c8c908d6c0a1a250913687a6e8b5aa9fbca33516e8
- 06-full-suite.log: 8b4e005dcff2b86709096fc4f3eba31e41a29a795623e58cddfd515ecfe912fb
- 07-final-suite-excluding-blocked-socket.log: d084f908a76da1d4f36959e04eeab1c562bff160dedbfeb5e0352f108fc14530
- 08-unsigned-release.log: 8e36c85b3b1ae98a3f729764743b7474d0826f098b0c3c88750b6c457479008c

## Explicit limits

Only the assistant message returned by the exact HTTP POST has output/turn authority. Other messages and unsupported response shapes remain UNKNOWN. No real OpenCode HTTP/SSE, actual provider turn or process restart, installed Conduit, Mac UI versus hosted ChatGPT two-client journey, physical power loss, provider lease contention, or mounted A1-A6 acceptance has been executed. This is a source/injected-fixture result, awaiting exact-head macOS CI and independent verification. No merge, release, installed app replacement, write gate or tunnel change was authorized.
