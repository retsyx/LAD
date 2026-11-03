#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[[ "$(uname -m)" == arm64 ]] || { echo "LAD requires Apple Silicon (arm64)." >&2; exit 1; }
usage() {
    echo "Usage:" >&2
    echo "  $0 stage SOURCE_DIRECTORY STAGING_DIRECTORY [--thumbnails]" >&2
    echo "  $0 publish SOURCE_DIRECTORY STAGING_DIRECTORY BACKUP_DIRECTORY" >&2
    exit 2
}
[[ $# -ge 3 ]] || usage
MODE="$1"
SOURCE_DIRECTORY="$2"
STAGING_DIRECTORY="$3"
[[ "$SOURCE_DIRECTORY" == /* ]] || SOURCE_DIRECTORY="$PWD/$SOURCE_DIRECTORY"
[[ "$STAGING_DIRECTORY" == /* ]] || STAGING_DIRECTORY="$PWD/$STAGING_DIRECTORY"
export LAD_MIGRATION_MODE="$MODE"
export LAD_MIGRATION_SOURCE_DIRECTORY="$SOURCE_DIRECTORY"
export LAD_MIGRATION_STAGING_DIRECTORY="$STAGING_DIRECTORY"
export LAD_MIGRATION_THUMBNAILS=0
case "$MODE" in
    stage)
        [[ $# -eq 3 || ( $# -eq 4 && "$4" == --thumbnails ) ]] || usage
        if [[ $# -eq 4 ]]; then export LAD_MIGRATION_THUMBNAILS=1; fi
        ;;
    publish)
        [[ $# -eq 4 ]] || usage
        if pgrep -x LAD >/dev/null; then
            echo "Quit LAD before publishing the converted designs." >&2
            exit 1
        fi
        BACKUP_DIRECTORY="$4"
        [[ "$BACKUP_DIRECTORY" == /* ]] || BACKUP_DIRECTORY="$PWD/$BACKUP_DIRECTORY"
        export LAD_MIGRATION_BACKUP_DIRECTORY="$BACKUP_DIRECTORY"
        ;;
    *) usage ;;
esac
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/lad-clang-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/lad-swift-cache}"
swift test --disable-sandbox --arch arm64 --filter ProjectDevelopmentMigrationTests/testDevelopmentMigration
