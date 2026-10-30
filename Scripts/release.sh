#!/bin/bash
# Release tooling uses LAD's pinned build interpreter; no system Python needed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(uname -m)" == arm64 ]] || { echo "LAD requires Apple Silicon (arm64)." >&2; exit 1; }
PAYLOAD="$("$ROOT/Scripts/prepare-runtime.sh")"
export PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1
exec "$PAYLOAD/expanded/python/bin/python3" "$ROOT/Scripts/release.py" --root "$ROOT" --payload "$PAYLOAD" "$@"
