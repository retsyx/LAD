#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -n "${LAD_PYTHON:-}" ]]; then
    PYTHON="$LAD_PYTHON"
elif command -v python3.11 >/dev/null 2>&1; then
    PYTHON="$(command -v python3.11)"
elif command -v python3.12 >/dev/null 2>&1; then
    PYTHON="$(command -v python3.12)"
else
    echo "Python 3.11 or 3.12 is required for the CAD runtime. Install with: brew install python@3.11"
    exit 1
fi

if [[ ! -x .venv/bin/python ]]; then "$PYTHON" -m venv .venv; fi
.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install -r Engine/requirements.txt
.venv/bin/python -c 'import cadquery; print("CAD runtime ready: CadQuery", cadquery.__version__)'
echo "Ready. Run Scripts/build-app.sh, then open dist/LAD.app."
