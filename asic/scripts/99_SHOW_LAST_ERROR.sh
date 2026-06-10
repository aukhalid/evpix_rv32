#!/usr/bin/env bash
set -euo pipefail
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$KIT_ROOT/.orfs_root" ]; then ORFS_ROOT="$(cat "$KIT_ROOT/.orfs_root")"; else ORFS_ROOT="${OPENROAD_FLOW_ROOT:-$HOME/Desktop/OpenROAD-flow-scripts}"; fi

echo "OPENROAD_FLOW_ROOT=$ORFS_ROOT"
echo "KIT_ROOT=$KIT_ROOT"

if [ -f "$KIT_ROOT/reports/run_sky130_v7.log" ]; then
  echo "==== EVPIX runner log tail ===="
  tail -n 220 "$KIT_ROOT/reports/run_sky130_v7.log"
fi

echo
if [ -d "$ORFS_ROOT/flow/logs/sky130hd/evpix_asic" ]; then
  echo "==== Last SKY130 log files ===="
  find "$ORFS_ROOT/flow/logs/sky130hd/evpix_asic" -type f | sort | tail -12
  LAST="$(find "$ORFS_ROOT/flow/logs/sky130hd/evpix_asic" -type f | sort | tail -1 || true)"
  if [ -n "$LAST" ]; then
    echo
    echo "==== tail -n 220 $LAST ===="
    tail -n 220 "$LAST"
  fi
else
  echo "No ORFS SKY130 log directory found yet."
fi
