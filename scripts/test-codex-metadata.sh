#!/usr/bin/env bash
# Compile the actual maintained client and run bounded owned fake stdio peers.
# Never starts Codex, mounts the Session API, changes HOME or removes evidence.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
    echo "Codex metadata native fixture BLOCKED: macOS is required." >&2
    exit 1
fi
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swift build --package-path "$ROOT" --target ConduitCore
BIN_PATH="$(swift build --package-path "$ROOT" --show-bin-path)"
ARTIFACT_ROOT="$ROOT/.build/codex-metadata-owner-$(uuidgen)"
mkdir "$ARTIFACT_ROOT"
OBJECTS=()
while IFS= read -r object; do OBJECTS+=("$object"); done < <(find "$BIN_PATH/ConduitCore.build" -maxdepth 1 -name '*.o' -type f | sort)
[[ ${#OBJECTS[@]} -gt 0 ]]
xcrun swiftc -target "$(uname -m)-apple-macosx13.0" \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -parse-as-library -I "$BIN_PATH/Modules" \
    "$ROOT/Sources/Conduit/CodexAppServerClient.swift" \
    "$ROOT/Tests/Native/CodexMetadataOwnerHarness.swift" \
    "${OBJECTS[@]}" -lsqlite3 -o "$ARTIFACT_ROOT/native-owner"
CONDUIT_CODEX_UNIX=0 "$ARTIFACT_ROOT/native-owner" \
    "$ROOT/Tests/Fixtures/codex-metadata-fake.py" "$ARTIFACT_ROOT"
echo "Codex metadata owner artifacts retained at $ARTIFACT_ROOT"
