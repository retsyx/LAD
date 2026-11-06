#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[[ "$(uname -m)" == arm64 ]] || { echo "LAD requires Apple Silicon (arm64)." >&2; exit 1; }
CONFIG="${LAD_BUILD_CONFIGURATION:-release}"
RUNTIME_PAYLOAD="${LAD_RUNTIME_PAYLOAD:-}"
if [[ -z "$RUNTIME_PAYLOAD" ]]; then RUNTIME_PAYLOAD="$("$ROOT/Scripts/prepare-runtime.sh")"; fi
[[ -f "$RUNTIME_PAYLOAD/manifest.json" && -f "$RUNTIME_PAYLOAD/payload.tar.gz" ]] || {
    echo "The prepared CAD runtime payload is incomplete." >&2; exit 1;
}
APP="${LAD_APP_OUTPUT:-$ROOT/dist/LAD.app}"
[[ "$(basename "$APP")" == LAD.app ]] || { echo "The app output must be named LAD.app." >&2; exit 1; }
mkdir -p "$(dirname "$APP")"
STAGING="$(mktemp -d "$(dirname "$APP")/.LAD-build.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
ASSEMBLED="$STAGING/LAD.app"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/lad-clang-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/lad-swift-cache}"
swift build --disable-sandbox --arch arm64 -c "$CONFIG"
BIN="$(swift build --disable-sandbox --arch arm64 -c "$CONFIG" --show-bin-path)"
mkdir -p "$ASSEMBLED/Contents/MacOS" "$ASSEMBLED/Contents/Resources"
cp "$BIN/LAD" "$ASSEMBLED/Contents/MacOS/LAD"
THUMBNAIL_EXTENSION="$ASSEMBLED/Contents/PlugIns/LADThumbnailExtension.appex"
mkdir -p "$THUMBNAIL_EXTENSION/Contents/MacOS"
cp "$BIN/LADThumbnailExtension" "$THUMBNAIL_EXTENSION/Contents/MacOS/LADThumbnailExtension"
cp "$ROOT/Scripts/ThumbnailExtension-Info.plist" "$THUMBNAIL_EXTENSION/Contents/Info.plist"
if [[ "$CONFIG" == release ]]; then
    SYMBOLS="${LAD_APP_SYMBOLS_OUTPUT:-}"
    if [[ -z "$SYMBOLS" ]]; then
        mkdir -p "$ROOT/.build/app-symbols"
        SYMBOLS="$(mktemp -d "$ROOT/.build/app-symbols/release.XXXXXX")"
    fi
    BUILD_PYTHON="${LAD_BUILD_PYTHON:-$RUNTIME_PAYLOAD/expanded/python/bin/python3}"
    "$BUILD_PYTHON" "$ROOT/Scripts/prepare_app_binaries.py" \
        --app "$ASSEMBLED" --symbols "$SYMBOLS" --build-root "$ROOT"
fi
# Bundle.module searches Contents/Resources in a packaged macOS app.
[[ -d "$BIN/LAD_LAD.bundle" ]] || { echo "The Swift resource bundle is missing." >&2; exit 1; }
ditto "$BIN/LAD_LAD.bundle" "$ASSEMBLED/Contents/Resources/LAD_LAD.bundle"
PACKAGED_ENGINE="$ASSEMBLED/Contents/Resources/Engine"
mkdir -p "$PACKAGED_ENGINE"
cp "$ROOT/Engine/worker.py" "$ROOT/Engine/agent_server.py" "$ROOT/Engine/agent-tools.json" \
   "$ROOT/Engine/script.sb" "$ROOT/Engine/requirements-lock.txt" "$PACKAGED_ENGINE/"
cp "$ROOT"/Engine/mesh_*.py "$ROOT/Engine/mesh-api.md" "$PACKAGED_ENGINE/"
ditto "$ROOT/Examples" "$ASSEMBLED/Contents/Resources/Examples"
# Ship a verified offline payload. First use prepares a versioned private
# interpreter/venv in Application Support without changing the signed app.
mkdir -p "$ASSEMBLED/Contents/Resources/CADRuntime"
cp "$RUNTIME_PAYLOAD/manifest.json" "$RUNTIME_PAYLOAD/payload.tar.gz" "$ASSEMBLED/Contents/Resources/CADRuntime/"
cp "$ROOT/LICENSE" "$ASSEMBLED/Contents/Resources/LICENSE.txt"
cp "$ROOT/Scripts/Info.plist" "$ASSEMBLED/Contents/Info.plist"
if [[ -n "${LAD_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $LAD_VERSION" "$ASSEMBLED/Contents/Info.plist"
fi
if [[ -n "${LAD_BUILD_NUMBER:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $LAD_BUILD_NUMBER" "$ASSEMBLED/Contents/Info.plist"
fi
for KEY in CFBundleShortVersionString CFBundleVersion; do
    VALUE="$(/usr/libexec/PlistBuddy -c "Print :$KEY" "$ASSEMBLED/Contents/Info.plist")"
    /usr/libexec/PlistBuddy -c "Set :$KEY $VALUE" "$THUMBNAIL_EXTENSION/Contents/Info.plist"
done
mkdir -p "$STAGING/icons"
xcrun swift "$ROOT/Scripts/make-icon.swift" "$STAGING/icons"
for ICON in LAD LADDocument LADFolder; do
    cp "$STAGING/icons/$ICON.icns" "$ASSEMBLED/Contents/Resources/"
done
if [[ "${LAD_APP_SIGNING:-adhoc}" != none ]]; then
    codesign --force --sign - --entitlements "$ROOT/Scripts/ThumbnailExtension.entitlements" "$THUMBNAIL_EXTENSION"
    codesign --force --sign - "$ASSEMBLED"
fi
# A fresh assembly never retains deleted resources or old runtime payloads.
if [[ -e "$APP" ]]; then rm -rf "$APP"; fi
mv "$ASSEMBLED" "$APP"
if [[ "${LAD_REGISTER_APP:-1}" == 1 ]]; then
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
fi
echo "Built $APP"
echo "Launch: open \"$APP\""
