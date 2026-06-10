#!/usr/bin/env bash
set -euo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORFS_ROOT="${OPENROAD_FLOW_ROOT:-}"

if [ -z "$ORFS_ROOT" ]; then
  for d in "$HOME/OpenROAD-flow-scripts" "$HOME/openroad-flow-scripts" "$HOME/tools/OpenROAD-flow-scripts" "/opt/OpenROAD-flow-scripts"; do
    if [ -d "$d/flow" ]; then ORFS_ROOT="$d"; break; fi
  done
fi

if [ -z "$ORFS_ROOT" ] || [ ! -d "$ORFS_ROOT/flow" ]; then
  echo "ERROR: Could not find OpenROAD-flow-scripts."
  echo "Set it manually, for example:"
  echo "  export OPENROAD_FLOW_ROOT=~/OpenROAD-flow-scripts"
  exit 1
fi

for platform in sky130hd asap7; do
  DEST="$ORFS_ROOT/flow/designs/$platform/evpix_asic"
  mkdir -p "$DEST"
  cp "$KIT_ROOT/flow/$platform/constraint.sdc" "$DEST/constraint.sdc"
  cp "$KIT_ROOT/flow/$platform/config.mk" "$DEST/config.mk"
  # Hard-code DESIGN_HOME so make can be launched from any folder.
  sed -i "s#export DESIGN_HOME ?=.*#export DESIGN_HOME := $KIT_ROOT#" "$DEST/config.mk"
  echo "Installed $platform design config at: $DEST"
done

cat > "$KIT_ROOT/.orfs_root" <<EOF2
$ORFS_ROOT
EOF2

echo
printf "ORFS_ROOT="; cat "$KIT_ROOT/.orfs_root"
echo "Next: bash scripts/10_run_sky130hd.sh"
