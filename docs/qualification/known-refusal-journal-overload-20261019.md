# Known no-effect journal refusal: public-overload follow-up

Date 2026-10-19. Source-only developer verification, not independent or installed qualification.

Frozen predecessor: cc927780f875d783131f5f113f1a2f8bd656859e.
Original journal capacity RED (2048/2049 refusals) and successful typed production fix
remain recorded in the prior commit and in
docs/qualification/known-refusal-journal-capacity-20261019.md.

Independent Astra reviewed that exact predecessor and returned FAIL_SOURCE_REVIEW:
the old public action-only perform helper synchronized durable intent before
the caller's admission/refusal logic. Its report SHA-256 is
86c768ba6a0ac29ba54abde57dec90c4b7379b3599410fcb62ee6b872b21a15e.

This follow-up removes that unsafe public convenience overload altogether.
All repository fixture/selftest callers now use the explicit typed admission
callback and invoke beginDispatch immediately before a simulated first effect.
The AppModel production typed call path is unchanged. No old helper remains
available for future journal users to silently accept a refusal as an effect.

Re-executed source checks after the overload removal and fixture migration:
- All 30 Python source contracts PASSED, exit 0, raw log SHA-256
  f27e612b5906b8273660b64f1885f425d0bf1e28a9b8a439933508b05301a10c.
- Native SessionAPIReplay filtered XCTest: 20 PASSED, exit 0, raw log SHA-256
  8d0892cb023f4b005ffbe368cfa56777ee6962325213085b2d6e5a895251de29.
- Direct conduit-selftest: 559 PASSED, 0 failed, exit 0, raw log SHA-256
  ddb1659bd561b75d1476a7103ca9a923dd2611f6e935561b4f61a05cc720674b.

The full native suite has not been rerun after this follow-up; prior complete
local run had the unrelated socket-bind EPERM environmental failure and three
explicit live-fixture skips. This new exact source must pass macOS GitHub CI and
a fresh independent reviewer. Accepted or uncertain intent is never auto-pruned;
physical crash/kill, installed native/hosted two-client acceptance, provider
turns, permission changes, installation, release and merge remain NOT_RUN.
