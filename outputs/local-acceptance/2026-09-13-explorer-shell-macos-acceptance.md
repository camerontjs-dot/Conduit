# MainFrame Explorer Shell v0 — local macOS acceptance

Status: `PASS` for the bounded PR #26 slice, subject to post-merge main
qualification.

This receipt records local evidence for the first-class, read-only Explore
workspace. It contains aggregate observations only; no private MainFrame
inventory, project names, corpus material, or host paths are recorded.

## Identity

- Repository: `camerontjs-dot/Conduit`
- Pull request: `#26`
- Feature branch: `feat/mainframe-explorer-shell-v0-20260913`
- Remote main at preflight: `420ab3b2e2d2a8d3783a0f342df3f2ee657c2444`
- Remote PR head at preflight: `e4d07cd4f9c20705bc09cf2dfded254c124892ec`
- Integration source commit qualified locally: `31dd5e4a3b6ce29918d3d60066d79afb7f908ba0`
- PR head containing this receipt: recorded after the receipt commit
- Post-merge main SHA: recorded in the outer project closeout after merge

## Toolchain

- macOS: `26.5.2` (`25F84`)
- Xcode: `26.6` (`17F113`)
- Swift: `6.3.3` (`swift-driver 1.148.6`)
- Build/test selection: repository scripts; full suite selected the Xcode
  developer directory explicitly.

## Focused and full verification

- `./scripts/test.sh --filter 'ConduitWorkspaceTests|MainframeLifecycleScannerTests|MainframeExplorerTests'`: `PASS`
  - selftest: `443 passed, 0 failed`
  - selected XCTest: `24 passed, 0 failed`
  - selected classes: workspace contract `3`, Explorer `10`, lifecycle `11`
- `./scripts/test.sh`: `PASS`
  - selftest: `443 passed, 0 failed`
  - XCTest: `385 passed, 0 failed`

## Compile, build, and signing

- `swift build --target Conduit`: `PASS`
- `./scripts/build-app.sh`: `PASS`
- release bundle and resource copy: `PASS`
- strict bundle codesign verification: `PASS`
- tested executable SHA-256: `ffd670878cafe8376203b9d521d384144b54014231dcc79921d00fde1a2a50c6`
- installed executable SHA-256 during this acceptance: the same value
- built and installed executable hashes matched before installed evidence.

## Synthetic Explorer smoke

Observed on a disposable fixture outside the repository:

- lifecycle roots appeared in the intended order;
- `.agents`, `.context`, and `.github` remained visible;
- `.git` was excluded;
- directories expanded one level at a time;
- symlinks were visible as leaves and were not traversed;
- valid project and operation records received authoritative labels;
- bounded invalid, binary, and oversized reads produced explicit messages;
- source opened read-only; no edit or mutation control was exposed;
- Quick Open exercised exact name, path fragment, subsequence, directory,
  file, and symlink results;
- Back/Forward, breadcrumb reveal, forward-history clearing, and a stale path
  produced the expected behavior.

## Real MainFrame read-only smoke

Observed against the configured local MainFrame installation:

- lifecycle roots and available system surfaces opened;
- project and operation areas were both representable;
- ordinary source/Markdown files opened read-only;
- `.git` remained excluded;
- Quick Open reached the bounded `20,000`-entry limit and visibly reported
  that results may be incomplete;
- no generated inventory or other write was made.

The relevant MainFrame Git status was unchanged before and after the smoke.

## Runtime continuity

Observed with a disposable Shell task on the synthetic fixture:

- Sessions → Explore → Sessions preserved the same selected task and runtime;
- no new task, process restart, prompt resend, buffer loss, or approval-state
  change was observed;
- Raw output and retained Conversation content remained available.

## Accessibility and sizing

- workspace picker exposed Explore with the expected `folder` symbol;
- tree rows exposed useful labels and help text;
- Quick Open was exposed as a keyboard action and Command-P opened it;
- Back/Forward disabled state was exposed;
- reader exposed a read-only state and source text selection;
- default and reduced-width window checks remained browseable and readable;
- VoiceOver was not run; accessibility evidence is AppKit accessibility-tree
  inspection, not a VoiceOver certification.

## Installed app and control-plane canary

- exact feature bundle was installed only after built/installed hash equality;
- installed Explore journey passed: workspace selection, tree expansion,
  read-only file opening, Quick Open, Back/Forward, breadcrumbs, and
  Sessions round-trip;
- the operator-controlled Session API write gate was observed enabled and was
  not changed by this work;
- three `Shell` canary attempts completed, each with `9` lanes and no recorded
  `FAIL` lane. The canary receipts retain their own provider-boundary notes;
  this acceptance does not upgrade quiet PTY output or a requested interrupt
  into provider completion/cancellation proof.

## Hosted checks and limitations

- PR #26 GitHub macOS evidence remained infrastructure-blocked: `runner_id: 0`,
  empty runner name, and `steps: []`. No hosted product failure is inferred.
- Explorer UI acceptance is limited to this staged read-only workspace slice.
- Markdown remains bounded source text, not rendered Markdown.
- Graph, backlinks, Workstation, editing, rename, delete, move, global search,
  and MindGraph surfaces remain out of scope.
- Post-merge main qualification is required before the final merged-main claim.
