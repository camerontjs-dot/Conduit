#!/usr/bin/env bash
# Run both Conduit suites without the caller needing to know where XCTest lives.
#
# XCTest ships inside Xcode.app, not with the Command Line Tools. If
# `xcode-select -p` points at /Library/Developer/CommandLineTools, a bare
# `swift test` fails with `no such module 'XCTest'`. That is a toolchain
# selection problem, not a missing dependency, so resolve it here the same way
# build-app.sh already does rather than requiring a machine-wide xcode-select.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

XCODE_DEVELOPER="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

echo "==> conduit-selftest"
swift run conduit-selftest

echo
echo "==> provider conformance contract"
python3 -m unittest discover -s Tests -p 'test_*.py'

if [[ -d "$XCODE_DEVELOPER" ]]; then
    echo
    echo "==> swift test (DEVELOPER_DIR=$XCODE_DEVELOPER)"
    DEVELOPER_DIR="$XCODE_DEVELOPER" swift test "$@"
else
    echo
    echo "==> swift test SKIPPED" >&2
    echo "    No Xcode at $XCODE_DEVELOPER, so XCTest is genuinely unavailable." >&2
    echo "    Install Xcode or set DEVELOPER_DIR to a developer directory that has it." >&2
    echo "    The selftest above still covers ConduitCore." >&2
    exit 1
fi
