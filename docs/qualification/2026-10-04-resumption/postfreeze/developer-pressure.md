# #128 post-freeze source-exposed developer pressure

Status: DESIGN ONLY / NOT_RUN. The author inspected candidate source and existing tests. Exclude these vectors and this source review from a fresh independent oracle author's prefreeze inputs. No executable or replacement harness has been written.

Candidate: `587be4267f7ef7e3a9e40eacf07aab334dcb59f4` / `6ceb4705cbdb27429dc088dc925ed2dc368084d6`.

## D1: Fractional JSON number rounded into a pending integer identity

Source:
- `Sources/ConduitCore/CodexAppServerProtocol.swift:28–32,59–65`: JSONSerialization result enters NSNumber conversion and explicitly becomes `.number(value.doubleValue)`. Even an NSDecimalNumber cannot preserve its exact decimal through this call.
- Same file `:89–93`: Int(exactly:) checks the resulting Double.
- `Sources/Conduit/CodexAppServerClient.swift:427–437`: matching pending turn/start ID plus parser-valid Error grants terminal failure authority.

Native developer check:
1. Feed the exact UTF-8 bytes below directly into the maintained parser. Do not first parse/re-encode them through a fixture JSON serializer:
   `{"id":3.0000000000000001,"error":{"code":-32602,"message":"synthetic rejection"}}\n`
2. Observe the parsed ID and whether the original nonintegral numeric value is rejected. Source analysis predicts that Double conversion yields 3 and permits the correlation. This prediction has not been executed on Swift here.
3. At the actual-client boundary, use the existing isolated offline fixture to establish a usable thread, observe the outgoing turn/start integer ID, and send the above bytes only when the captured request ID is 3. Otherwise explicitly construct and preserve a distinct fractional token that rounds to the observed integer; record the bytes and rationale.
4. Preserve the raw response, parsed delivery, active/failed state and durable receipt. Contrast the malformed fractional response with ordinary integer 3 (expected correlated rejection), representable 3.5 (expected refusal), and string "3" (must not correlate).
5. Never label this as native-confirmed until the actual unchanged parser/client execution occurs.

Existing test gap: `CodexTerminalReplayTests.swift:104–109` uses 3.5; `:122–128` covers huge, out-of-range and nonfinite Doubles. Neither passes a precision-collision decimal lexeme through the parser.

## D2: Missing or non-string completion status before a failed completion

Source:
- Exact base `d10ec1c90c835e8b210a4e27e7333fd8e436bd7a`, `Sources/ConduitCore/CodexAppServerProtocol.swift:284–296`, already defaults missing/non-string status to completed.
- #128 same path `:344–354` retains the fallback; `:373–375` retires the turn; later same-turn failed completion is rejected by `:347`.
- Issue #114 acceptance items 1–6 require the observed terminal failure to be truthful and durable but do not explicitly define precedence after a malformed completion. Do not infer an authorized compatibility change solely from the fallback's existence.

Native developer check:
1. Establish exact owned thread `developer-thread`, start `developer-turn`, and observe active state without assistant output.
2. Feed, in separate fresh cases:
   - `{"method":"turn/completed","params":{"threadId":"developer-thread","turn":{"id":"developer-turn"}}}\n`
   - same envelope with `"status":null` in `turn`;
   - same envelope with `"status":1` in `turn`.
3. Then feed:
   `{"method":"turn/completed","params":{"threadId":"developer-thread","turn":{"id":"developer-turn","status":"failed","error":{"codexErrorInfo":"unauthorized"}}}}\n`
4. Preserve each mapper/client effect and reconstructed state. Source analysis predicts that the first completion becomes completed and the second is discarded; actual native execution remains NOT_RUN.
5. Keep a direct matching-failed control (no preceding malformed completion) and an explicitly completed-then-failed control. Decide malformed-completion authority separately from valid first-terminal replay protection before any repair.

Existing controls:
- `CodexAppServerProtocolTests.swift:63–94`: explicit top-level completed with no IDs.
- Same file `:96–128`: explicit nested interrupted.
- `CodexTerminalReplayTests.swift:139–150`: explicit failed/completed/interrupted then duplicate start.
- `CodexTerminalRejectionTests.swift:245–269`: failed completion plus late output; unrelated late failure after completion.
- No inspected committed control covers missing/non-string status followed by matching failed completion.

These vectors may justify a separate developer reproduction or source successor. They do not change #128's frozen identity, current disposition, historical evidence, or independent native qualification status.
