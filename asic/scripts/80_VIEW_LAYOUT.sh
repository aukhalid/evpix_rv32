#!/usr/bin/env bash
set -euo pipefail
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$KIT_ROOT/.orfs_root" ]; then ORFS_ROOT="$(cat "$KIT_ROOT/.orfs_root")"; else ORFS_ROOT="${OPENROAD_FLOW_ROOT:-}"; fi
GDS="$KIT_ROOT/reports/final_gdsii/evpix_asic_sky130hd.gds"
if [ ! -f "$GDS" ] && [ -n "${ORFS_ROOT:-}" ]; then
  GDS="$(find "$ORFS_ROOT/flow/results/sky130hd/evpix_asic/base" -maxdepth 1 -type f -name "*.gds" 2>/dev/null | head -1 || true)"
fi
if [ -z "${GDS:-}" ] || [ ! -f "$GDS" ]; then
  echo "ERROR: No GDS layout found. Run the SKY130 flow first."
  exit 1
fi

echo "Opening layout: $GDS"
echo "Tip: zoom out, then take a screenshot for your documentation."

if command -v klayout >/dev/null 2>&1; then
  klayout "$GDS" &
elif command -v magic >/dev/null 2>&1; then
  magic -d XR "$GDS" &
elif command -v openroad >/dev/null 2>&1; then
  echo "KLayout/Magic not found. Opening OpenROAD GUI fallback if possible."
  ODB=""
  if [ -n "${ORFS_ROOT:-}" ]; then
    ODB="$(find "$ORFS_ROOT/flow/results/sky130hd/evpix_asic/base" -maxdepth 1 -type f -name "*.odb" 2>/dev/null | head -1 || true)"
  fi
  if [ -n "$ODB" ]; then
    openroad -gui "$ODB" &
  else
    echo "No .odb found for OpenROAD GUI. Install/use KLayout to view the .gds."
    exit 1
  fi
else
  echo "No GUI viewer found. Install/use KLayout, Magic, or OpenROAD GUI."
  echo "GDS file: $GDS"
  exit 1
fi
