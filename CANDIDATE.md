# Frozen owner-native failed response-correlation phase

Issue #114; predecessor Draft #118 head `e6303d8bdc6b212304b1d44f4a1488b6bdc4f792`, tree `aa1c68d0e05a7f424aeee8b55641e42132ceb65d`.

This phase added exact registered thread request correlation. Two regressions were red before repair (five assertions); 62 focused native tests passed afterward. The expanded actual-client owner harness then returned FAIL: 14 malformed-stream controls reached ready with the correct thread in memory but emitted no thread identity effect for durable persistence. The 19 other controls passed, including foreign/duplicate/string/init response and resume pressure. This owner result is not independent qualification.

The native failure, fixture source, executable, logs and source custody remain preserved in append-only local receipts. This source phase is frozen in its commit and must not be repaired in place. The next branch moves the once-per-handshake thread receipt to the correlated native handshake boundary. #115/#116/#118 remain unchanged; no candidate in this lineage is merge-ready. Actual AppModel/HTTP, installed/operator, vendor, queue and objective acceptance remain UNKNOWN.
