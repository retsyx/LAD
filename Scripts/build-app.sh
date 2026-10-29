#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CONFIG="${LAD_BUILD_CONFIGURATION:-release}"
RUNTIME_PAYLOAD="$("$ROOT/Scripts/prepare-runtime.sh")"
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
# Rebuild the engine resources from an explicit runtime-only list. Copying over
# an old app can otherwise retain deleted modules, tests or Python bytecode.
PACKAGED_ENGINE="$APP/Contents/Resources/Engine"
rm -rf "$PACKAGED_ENGINE"
mkdir -p "$PACKAGED_ENGINE"
cp "$ROOT/Engine/worker.py" "$ROOT/Engine/agent_server.py" \
   "$ROOT/Engine/script.sb" "$ROOT/Engine/requirements-lock.txt" "$PACKAGED_ENGINE/"
ditto "$ROOT/Examples" "$APP/Contents/Resources/Examples"
# Ship a verified offline payload. First use prepares a versioned private
# interpreter/venv in Application Support without changing the signed app.
rm -f "$APP/Contents/Resources/python-runtime.txt"
mkdir -p "$APP/Contents/Resources/CADRuntime"
cp "$RUNTIME_PAYLOAD/manifest.json" "$RUNTIME_PAYLOAD/payload.tar.gz" "$APP/Contents/Resources/CADRuntime/"
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
