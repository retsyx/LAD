#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
RUNTIME_PAYLOAD="$("$ROOT/Scripts/prepare-runtime.sh")"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/lad-clang-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/lad-swift-cache}"
swift test --disable-sandbox
"$RUNTIME_PAYLOAD/expanded/python/bin/python3" -m unittest discover -s Engine/tests -v
