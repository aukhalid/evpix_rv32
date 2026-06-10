#!/usr/bin/env bash
set -euo pipefail
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$KIT_ROOT/.orfs_root" ]; then ORFS_ROOT="$(cat "$KIT_ROOT/.orfs_root")"; else ORFS_ROOT="${OPENROAD_FLOW_ROOT:-}"; fi
if [ -z "${ORFS_ROOT:-}" ] || [ ! -d "$ORFS_ROOT/flow" ]; then
  echo "Run scripts/02_install_designs_into_orfs.sh first, or export OPENROAD_FLOW_ROOT."
  exit 1
fi
cd "$ORFS_ROOT/flow"
echo "Running EVPIX on ASAP7..."
make DESIGN_CONFIG=./designs/asap7/evpix_asic/config.mk 2>&1 | tee "$KIT_ROOT/reports/asap7_run.log"
