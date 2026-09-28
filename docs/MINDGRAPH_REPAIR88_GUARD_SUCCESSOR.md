# Guarded pair assembly: changelog-anchor successor

## Boundary and lineage

This is a source-only successor to Conduit #90 under #88, paired with the
unchanged MindGraph #29 kit under MindGraph #28. It is not an assembled app.
The exact successor commit/tree belong in the PR source receipt.

Preserved consumer kit: `b8011f96afda2a99e2b8722c06da63e351d2bd40`,
tree `34b989676114bfe3ef7daab69eaac67078a8ac77`.
Unchanged producer kit: `6f599a8531a6dafcdd8c76a86860f84020b97512`,
tree `71857afc9aade1b994e2b0fe1404e5e7d55bc000`.

The blocked local assembly reports remain unchanged:
- https://github.com/camerontjs-dot/Conduit/pull/90#issuecomment-5851939741
- https://github.com/camerontjs-dot/MindGraph/pull/29#issuecomment-5851940112

The inherited paired protocol remains at:
https://github.com/camerontjs-dot/Conduit/pull/90#issuecomment-5851866969
Read this addendum before that protocol: use the new consumer kit identity,
not #90's blocked head, and preserve the original kit branches. Nothing here
admits local assembly, product qualification, a merge, or research execution.

## Exact repair

The pinned changelog has six Fixed headings in Unreleased. The reviewed target
is the first Fixed block, beginning at line 108 of input Git blob
`60a0bc6a22f4c8aed312388ba0b80a401a78d65e`. Its opening Fleet inventory paragraph
is the content anchor. The line number is diagnostic, not a runtime selector.

The guard requires one line-exact Unreleased section and one complete named
anchor in the document. That anchor must be the first Fixed block inside the
section. Peer or higher headings end the section. Missing, altered, duplicate,
relocated, or example-fenced targets fail rather than selecting another Fixed
block. Later ordinary Fixed blocks remain untouched. Reapplication refuses
instead of inserting the same repair twice.

Only `unreleased_fixed` and its anchor constant change in the assembler.
All seven original BLOBS pins, the exact-head/clean-root/symlink checks, every
other transform, the authored replacement paragraph, conformance safeguards,
and compute-before-write behavior remain unchanged. The source comparison
confirmed every byte outside this guard region is preserved. No assembler
entrypoint or product transform was executed during these checks.

CHANGELOG.md itself is unchanged in this kit. The inherited product entry is
still pending mechanical assembly; it is not evidence of completed behavior.
The existing assembly guide's seven-file allowlist remains in force.

## Focused developer evidence

Environment: Linux x86_64, Python 3.13.5; standard library only.

```sh
python3 -B -m unittest discover -s tools/repair88 -p test_assemble.py -v
python3 -B -c 'from pathlib import Path; [compile(p.read_bytes(), str(p), "exec") for p in (Path("tools/repair88/assemble.py"), Path("tools/repair88/test_assemble.py"))]'
```

Result: 22 tests passed, zero failures or skips; source compilation passed.
These are developer checks, not independent integration qualification.

The exact complete 44,778-byte pinned changelog was read as a fixture. The test
verifies its Git blob before exercising the actual guard with the production
replacement literal, checks the intended position, and verifies every original
byte survives. It does not write the returned string to CHANGELOG.md.
The old six tests passed on the predecessor while a separate pure-helper probe
reproduced its six-heading refusal. The original local block is not rewritten.

Tested assembler SHA-256:
`34eda4d5a90e2a8bb269ce63a27fc4d8497d09af835cefabe691a0074074c423`
Tested test-file SHA-256:
`64cada57c361b6a9d2e96f24efba4354e6c2688b4a409f6c76c5c96737ce1c7e`
Unchanged input changelog SHA-256:
`bed101407d612dce608703a23e384fb042fde1e63fa56f48430e4f7897512d96`
In-memory changelog result SHA-256 (45,173 bytes; not an assembled artifact):
`e099953d5f75ee0315ddeefb5cacc98b75b6d1dc32a36b0bbbb9c01a786355b6`

## Separately owned local boundary

After supervisor admission, the assembly owner must verify the exact new
consumer kit and unchanged producer kit heads/trees in fresh clean isolated
checkouts. Run the focused guard tests before assembly. Use `python3 -B` for
the existing dry-run/write commands and supply each exact kit SHA through
`--expected-head`. Compare all dry-run/write hashes and the unchanged seven-file
Conduit/two-file MindGraph allowlists. Any refusal remains
`BLOCKED_SUCCESSOR_ASSEMBLY`; do not bypass or repair a guard locally.

Record mechanical child commits/trees on new child branches without altering
#90, #29, #86, or #23 in place. No child pair exists from this source-only pass.
Do not substitute the single in-memory changelog result for a full assembly
receipt. Complete-pair dry-run/write success remains UNKNOWN until observed.

Exact-pair qualification follows only in separately admitted fresh checkouts
of those children. The inherited real producer CLI/MCP collision controls,
live Conduit tools/list discovery, full product/conformance/build gates, and
populated live-worker non-admission controls remain required. None ran here.
No private corpus, model, installed index, macOS app, or local worker is needed
for this source guard; those inputs remain requirements of the later work.

Do not change MindGraph #25-#27 dependencies, launch studies, merge, release,
or infer retrieval quality from an assembly result.
