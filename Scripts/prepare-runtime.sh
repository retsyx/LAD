#!/bin/bash
# Build-machine operation only. The finished app installs this payload offline.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="$(uname -m)"
if [[ "$ARCH" != arm64 ]]; then
    echo "The packaged CAD runtime currently supports Apple Silicon only." >&2
    exit 1
fi
SOURCE="$ROOT/Engine/runtime-source.json"
URL="$(/usr/bin/plutil -extract "$ARCH.url" raw -o - "$SOURCE")"
SHA="$(/usr/bin/plutil -extract "$ARCH.sha256" raw -o - "$SOURCE")"
CACHE="$ROOT/.build/cad-runtime/downloads"
mkdir -p "$CACHE"
ARCHIVE="$CACHE/$SHA.tar.gz"
if [[ ! -f "$ARCHIVE" ]] || [[ "$(/usr/bin/shasum -a 256 "$ARCHIVE" | cut -d ' ' -f 1)" != "$SHA" ]]; then
    PARTIAL="$ARCHIVE.partial.$$"
    trap 'rm -f "$PARTIAL"' EXIT
    /usr/bin/curl --fail --location --retry 3 "$URL" -o "$PARTIAL" >&2
    [[ "$(/usr/bin/shasum -a 256 "$PARTIAL" | cut -d ' ' -f 1)" == "$SHA" ]] || { echo "CPython download checksum mismatch." >&2; exit 1; }
    mv "$PARTIAL" "$ARCHIVE"
    trap - EXIT
fi
BOOTSTRAP="$ROOT/.build/cad-runtime/bootstrap-$SHA"
if [[ ! -x "$BOOTSTRAP/python/bin/python3" ]]; then
    STAGING="$BOOTSTRAP.partial.$$"
    trap 'rm -rf "$STAGING"' EXIT
    mkdir -p "$STAGING"
    /usr/bin/tar -xzf "$ARCHIVE" -C "$STAGING"
    if [[ -d "$BOOTSTRAP" ]]; then rm -rf "$BOOTSTRAP"; fi
    mv "$STAGING" "$BOOTSTRAP"
    trap - EXIT
fi
export PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1
exec "$BOOTSTRAP/python/bin/python3" "$ROOT/Scripts/prepare_runtime.py" --root "$ROOT" --archive "$ARCHIVE" --architecture "$ARCH" "$@"
