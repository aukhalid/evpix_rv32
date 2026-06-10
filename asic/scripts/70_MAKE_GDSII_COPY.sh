#!/usr/bin/env bash
set -euo pipefail
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$KIT_ROOT/.orfs_root" ]; then ORFS_ROOT="$(cat "$KIT_ROOT/.orfs_root")"; else ORFS_ROOT="${OPENROAD_FLOW_ROOT:-}"; fi
if [ -z "${ORFS_ROOT:-}" ]; then
  echo "ERROR: OPENROAD_FLOW_ROOT unknown. Run 00_RUN_ME_FIRST_SKY130_FULL.sh first."
  exit 1
fi
RES="$ORFS_ROOT/flow/results/sky130hd/evpix_asic/base"
OUT="$KIT_ROOT/reports/final_gdsii"
mkdir -p "$OUT"
GDS=""
if [ -d "$RES" ]; then
  GDS="$(find "$RES" -maxdepth 1 -type f -name "*.gds" | head -1 || true)"
fi
if [ -n "$GDS" ]; then
  cp -f "$GDS" "$OUT/evpix_asic_sky130hd.gds"
  cp -f "$GDS" "$OUT/evpix_asic_sky130hd.gdsii"
  cp -f "$GDS" "$OUT/evpix_asic_sky130hd.gds2"
  echo "GDSII/GDS2 layout copies created from OpenROAD results:"
  ls -lh "$OUT"/evpix_asic_sky130hd.gds* || true
else
  echo "No .gds file found in OpenROAD results. Writing GDS directly from routed/fill ODB..."
  bash "$KIT_ROOT/scripts/85_WRITE_GDS_FROM_FILLED_ODB.sh"
fi
