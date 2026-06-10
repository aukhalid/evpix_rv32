#!/usr/bin/env bash
set -euo pipefail
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$KIT_ROOT/reports/yosys"
cd "$KIT_ROOT"
yosys -l "$KIT_ROOT/reports/yosys/yosys_synth_only.log" "$KIT_ROOT/scripts/yosys_synth_only.ys"
