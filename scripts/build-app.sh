#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

XCODE_DEVELOPER="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
XCODE_SWIFT="$XCODE_DEVELOPER/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
XCODE_SDK="$XCODE_DEVELOPER/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
if [[ -x "$XCODE_SWIFT" && -d "$XCODE_SDK" ]]; then
    SWIFT_BIN="$XCODE_SWIFT"
    export SDKROOT="${SDKROOT:-$XCODE_SDK}"
else
    SWIFT_BIN="$(command -v swift)"
fi

# Keep compiler caches out of user Library paths so sandboxed builds are
# deterministic and do not depend on machine-specific cache permissions.
BUILD_CACHE_ROOT="${TMPDIR:-/tmp}/conduit-swift-build"
mkdir -p "$BUILD_CACHE_ROOT/clang" "$BUILD_CACHE_ROOT/swiftpm"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$BUILD_CACHE_ROOT/clang}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$BUILD_CACHE_ROOT/swiftpm}"

"$SWIFT_BIN" build -c release --disable-sandbox

APP="$ROOT/dist/Conduit.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/Conduit" "$APP/Contents/MacOS/Conduit"
cp "Sources/Conduit/Resources/Info.plist" "$APP/Contents/Info.plist"

# Sign the complete bundle rather than relying on the linker's executable-only
# ad-hoc signature. This binds Info.plist/resources and gives macOS privacy
# controls the intended bundle identifier for local daily-driver installs.
codesign --force --sign - --identifier dev.camerontjs.conduit "$APP"
codesign --verify --deep --strict "$APP"

printf 'Built %s\n' "$APP"
printf 'Open with: open "%s"\n' "$APP"
