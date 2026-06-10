#!/usr/bin/env bash
set -euo pipefail

ORFS_ROOT="${OPENROAD_FLOW_ROOT:-}"
if [ -z "$ORFS_ROOT" ]; then
  if [ -f "$(dirname "$0")/../.orfs_root" ]; then
    ORFS_ROOT="$(cat "$(dirname "$0")/../.orfs_root")"
  else
    ORFS_ROOT="$HOME/Desktop/OpenROAD-flow-scripts"
  fi
fi

if [ ! -d "$ORFS_ROOT/flow/scripts" ]; then
  echo "ERROR: OpenROAD-flow-scripts not found at: $ORFS_ROOT"
  echo "Set OPENROAD_FLOW_ROOT and rerun."
  exit 1
fi

export OPENROAD_FLOW_ROOT="$ORFS_ROOT"

python3 - <<'PY'
from pathlib import Path
import re, os
root = Path(os.environ["OPENROAD_FLOW_ROOT"]) / "flow" / "scripts"
yosys_tcl_names = {"synth.tcl", "synth_canonicalize.tcl"}
for p in root.glob("*.tcl"):
    txt = p.read_text()
    if "read_verilog" not in txt:
        continue
    old = txt
    if p.name in yosys_tcl_names:
        txt = re.sub(r'\bread_verilog(?![^\n;]*\s-sv\b)', 'read_verilog -sv', txt)
    else:
        txt = re.sub(r'\bread_verilog\s+-sv\b', 'read_verilog', txt)
    if txt != old:
        bak = p.with_suffix(p.suffix + ".evpix_v13_bak")
        if not bak.exists():
            bak.write_text(old)
        p.write_text(txt)
        print("patched", p)
print("Done. read_verilog syntax fixed for Yosys vs OpenROAD Tcl scripts.")
PY
