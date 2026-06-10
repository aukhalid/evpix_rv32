#!/usr/bin/env bash
set -euo pipefail
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$KIT_ROOT/.orfs_root" ]; then ORFS_ROOT="$(cat "$KIT_ROOT/.orfs_root")"; else ORFS_ROOT="${OPENROAD_FLOW_ROOT:-}"; fi
if [ -z "${ORFS_ROOT:-}" ] || [ ! -d "$ORFS_ROOT/flow" ]; then
  echo "Run scripts/02_install_designs_into_orfs.sh first, or export OPENROAD_FLOW_ROOT."
  exit 1
fi
cd "$ORFS_ROOT/flow"
echo "Running EVPIX on SKY130HD until routed+density-filled ODB..."
echo "This intentionally stops before final_report because your VM gets killed by signal 9 during RC/PSM report generation."
TARGET="results/sky130hd/evpix_asic/base/6_1_fill.odb"
make DESIGN_CONFIG=./designs/sky130hd/evpix_asic/config.mk "$TARGET" 2>&1 | tee "$KIT_ROOT/reports/sky130hd_run.log"
if [ ! -f "$TARGET" ]; then
  echo "ERROR: Expected routed/fill ODB was not generated: $TARGET"
  exit 1
fi
echo "SUCCESS: routed/fill ODB generated: $ORFS_ROOT/flow/$TARGET"
