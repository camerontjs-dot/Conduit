#!/usr/bin/env bash
# Post-install verification: prove the app you just installed actually works.
#
# scripts/test.sh proves ConduitCore logic. It cannot prove that the installed
# bundle drives a real runtime, because the Session API, the adapters, and the
# PTY all live outside the deterministic suite. Every defect found on
# 2026-09-04 — the duplicate objective delivery, the intermittent PTY
# observation gap, a provider error reported as a completed turn — was
# invisible to 291 passing tests and visible on the first live run.
#
# This is deliberately NOT wired into build-app.sh. It needs the operator's
# Session API write gate, and that switch stays the operator's.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REPEAT="${1:-3}"
AGENT="${2:-Shell}"

echo "==> installed bundle"
APP=/Applications/Conduit.app/Contents/MacOS/Conduit
if [[ ! -x "$APP" ]]; then
    echo "    no installed app at $APP" >&2
    exit 2
fi
INSTALLED=$(shasum -a 256 "$APP" | cut -d' ' -f1)
echo "    installed : $INSTALLED"
if [[ -x dist/Conduit.app/Contents/MacOS/Conduit ]]; then
    BUILT=$(shasum -a 256 dist/Conduit.app/Contents/MacOS/Conduit | cut -d' ' -f1)
    echo "    just built: $BUILT"
    if [[ "$INSTALLED" != "$BUILT" ]]; then
        echo "    ! the installed app is NOT the build you just made." >&2
        echo "      Verifying it would prove nothing about your change." >&2
        exit 3
    fi
fi

echo
echo "==> canary (${REPEAT}x, agent=${AGENT})"
echo "    A single green run hides intermittent defects, so this repeats."
exec ./scripts/canary-control-plane.py --run --repeat "$REPEAT" --agent "$AGENT"
