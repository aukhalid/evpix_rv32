#!/usr/bin/env bash
set -euo pipefail
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$KIT_ROOT/.orfs_root" ]; then ORFS_ROOT="$(cat "$KIT_ROOT/.orfs_root")"; else ORFS_ROOT="${OPENROAD_FLOW_ROOT:-}"; fi
mkdir -p "$KIT_ROOT/reports/collected"
for platform in sky130hd asap7; do
  BASE="$ORFS_ROOT/flow/reports/$platform/evpix_asic/base"
  RES="$ORFS_ROOT/flow/results/$platform/evpix_asic/base"
  if [ -d "$BASE" ]; then
    find "$BASE" -maxdepth 2 -type f \( -name "*.rpt" -o -name "*.log" -o -name "*.json" \) -exec cp -v {} "$KIT_ROOT/reports/collected/" \; || true
  fi
  if [ -d "$RES" ]; then
    find "$RES" -maxdepth 1 -type f \( -name "*.gds" -o -name "*.def" -o -name "*.v" -o -name "*.sdc" \) -exec cp -v {} "$KIT_ROOT/reports/collected/" \; || true
  fi
done
echo "Collected reports/results into $KIT_ROOT/reports/collected"
