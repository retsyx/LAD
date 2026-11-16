#!/bin/bash
# Print test-process and system memory every five seconds until stopped.
set -u
page="$(sysctl -n hw.pagesize)"
while true; do
    processes="$(ps -axo rss=,comm=)"
    xctest="$(awk '$2 ~ /\/xctest$/ {kb += $1} END {print int(kb / 1024)}' <<<"$processes")"
    python="$(awk '$2 ~ /\/python3[.0-9]*$/ {kb += $1} END {print int(kb / 1024)}' <<<"$processes")"
    compressor="$(vm_stat | awk -v page="$page" '/occupied by compressor/ {gsub(/\./, "", $5); print int($5 * page / 1048576)}')"
    free="$(memory_pressure -Q | awk -F': ' '/free percentage/ {sub(/%/, "", $2); print $2}')"
    swap="$(sysctl -n vm.swapusage | awk '{sub(/M/, "", $6); print int($6)}')"
    disk="$(df -m / | awk 'NR == 2 {print $4}')"
    echo "$(date -u +%H:%M:%S) xctest_mb=$xctest python_mb=$python compressor_mb=$compressor free_pct=$free swap_used_mb=$swap disk_free_mb=$disk"
    sleep 5
done
