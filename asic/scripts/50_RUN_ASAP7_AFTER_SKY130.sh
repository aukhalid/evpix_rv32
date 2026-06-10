#!/usr/bin/env bash
set -euo pipefail
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KIT_ROOT"
if [ -f "$KIT_ROOT/.orfs_root" ]; then
  export OPENROAD_FLOW_ROOT="$(cat "$KIT_ROOT/.orfs_root")"
else
  export OPENROAD_FLOW_ROOT="${OPENROAD_FLOW_ROOT:-/home/arif/Desktop/OpenROAD-flow-scripts}"
fi
if [ -f "$HOME/tools/oss-cad-suite/environment" ]; then
  source "$HOME/tools/oss-cad-suite/environment"
fi
bash scripts/02_install_designs_into_orfs.sh
rm -rf "$OPENROAD_FLOW_ROOT/flow/logs/asap7/evpix_asic" "$OPENROAD_FLOW_ROOT/flow/results/asap7/evpix_asic" "$OPENROAD_FLOW_ROOT/flow/reports/asap7/evpix_asic" "$OPENROAD_FLOW_ROOT/flow/objects/asap7/evpix_asic"
bash scripts/20_run_asap7.sh
bash scripts/30_collect_reports.sh || true
find "$OPENROAD_FLOW_ROOT/flow/results/asap7/evpix_asic/base" -type f \( -name "*.gds" -o -name "*.def" -o -name "*.v" -o -name "*.sdc" -o -name "*.spef" \) || true
