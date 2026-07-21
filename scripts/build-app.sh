#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release

APP="$ROOT/dist/Conduit.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/Conduit" "$APP/Contents/MacOS/Conduit"
cp "Sources/Conduit/Resources/Info.plist" "$APP/Contents/Info.plist"

printf 'Built %s\n' "$APP"
printf 'Open with: open "%s"\n' "$APP"
