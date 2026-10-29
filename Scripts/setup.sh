#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PAYLOAD="$("$ROOT/Scripts/prepare-runtime.sh")"
echo "CAD runtime payload ready: $PAYLOAD"
echo "Run Scripts/build-app.sh, then open dist/LAD.app. LAD prepares its private runtime automatically."
