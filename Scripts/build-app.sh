#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CONFIG="${LAD_BUILD_CONFIGURATION:-release}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/lad-clang-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/lad-swift-cache}"
swift build --disable-sandbox -c "$CONFIG"
BIN="$(swift build --disable-sandbox -c "$CONFIG" --show-bin-path)"
APP="$ROOT/dist/LAD.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/LAD" "$APP/Contents/MacOS/LAD"
# Bundle.module searches Contents/Resources in a packaged macOS app.
if [[ -d "$BIN/LAD_LAD.bundle" ]]; then
    ditto "$BIN/LAD_LAD.bundle" "$APP/Contents/Resources/LAD_LAD.bundle"
fi
ditto "$ROOT/Engine" "$APP/Contents/Resources/Engine"
ditto "$ROOT/Examples" "$APP/Contents/Resources/Examples"
# Deliberately reference the local native runtime. Avoid copying 1.4 GB of binary
# dependencies and a non-relocatable virtualenv into a development app.
if [[ -x "$ROOT/.venv/bin/python" ]]; then
    printf '%s\n' "$ROOT/.venv/bin/python" > "$APP/Contents/Resources/python-runtime.txt"
fi
cp "$ROOT/Scripts/Info.plist" "$APP/Contents/Info.plist"
xcrun swift "$ROOT/Scripts/make-icon.swift" "$ROOT/dist"
cp "$ROOT/dist/LAD.icns" "$APP/Contents/Resources/LAD.icns"
cp "$ROOT/dist/LADDocument.icns" "$APP/Contents/Resources/LADDocument.icns"
cp "$ROOT/dist/LADFolder.icns" "$APP/Contents/Resources/LADFolder.icns"
codesign --force --deep --sign - "$APP"
# Refresh this app's document-type and icon registration after each rebuild.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "Built $APP"
echo "Launch: open \"$APP\""
