#!/usr/bin/env bash
set -euo pipefail

echo "Checking tools in PATH..."
for t in yosys openroad make git python3; do
  if command -v "$t" >/dev/null 2>&1; then
    echo "OK: $t -> $(command -v $t)"
  else
    echo "MISSING: $t"
  fi
done

echo
if [ -n "${OPENROAD_FLOW_ROOT:-}" ] && [ -d "$OPENROAD_FLOW_ROOT/flow" ]; then
  echo "OPENROAD_FLOW_ROOT is set: $OPENROAD_FLOW_ROOT"
else
  echo "OPENROAD_FLOW_ROOT is not set. Searching common locations..."
  for d in "$HOME/OpenROAD-flow-scripts" "$HOME/openroad-flow-scripts" "$HOME/tools/OpenROAD-flow-scripts" "/opt/OpenROAD-flow-scripts"; do
    if [ -d "$d/flow" ]; then
      echo "Found possible ORFS: $d"
    fi
  done
fi

echo
printf "Yosys version: "; yosys -V || true
printf "OpenROAD version: "; openroad -version || true
