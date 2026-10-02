# Issue #114 explicit native thread identity freeze

Product source commit: `e401e486d955823f0ffebe07a7b2f7bfb8df984a`. Product tree: `b2cc2b2a2288137c0dacf84434cc765e6a75b88a`.

The final metadata commit adds only this freeze note. Sources and Tests must match the exact owner-tested inventory. The owner receipt is `docs/qualification/receipts/issue114-explicit-thread-owner-native-v1.json`, SHA256 `5ae18a489a33a41d11b8c117b343dc58ed2978f06188f90478930516ecdeac2f`.

Owner controls passed: 33 actual-client turn/replay controls and 12 returned-thread identity controls; all 45 fixture processes absent. Native gate: 480 self-tests, 10 script contracts, 637 XCTest cases with three explicit optional environment skips and no failures. Maintained release/package/strict signature passed; no launch or installation.

Frozen failed Draft #115/#116/#118 and owner phases `49c1ca09e2babb29262edd057737183e7f85ac86` / `f0932075d401fcec0038427bac9ba27d5d9a85c8` remain preserved. Their failures are not converted into this candidate's acceptance.

Fresh independent qualification: NOT_RUN pending private-source CLI authority. Actual AppModel/HTTP task/runtime binding and cross-lane composition: NOT_RUN. Hosted CI is a separate post-push gate. This is a maintained Draft, not merge-ready or released.
