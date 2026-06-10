#!/usr/bin/env bash
# Kill a previous/stuck EVPIX OpenROAD/Yosys/ABC run.
# Use this before starting V12 if an old v10 ABC process is still running.
set -euo pipefail

echo "Processes before kill:"
ps -eo pid,etime,%cpu,%mem,cmd | grep -E "evpix_asic|yosys-abc|yosys|openroad|make DESIGN_CONFIG=.*evpix_asic" | grep -v grep || true

# Kill children first, then parents. Only match EVPIX/OpenROAD processes.
pkill -f "yosys-abc -s" || true
pkill -f "tools/install/yosys/bin/yosys.*evpix_asic" || true
pkill -f "OpenROAD-flow-scripts.*/flow/scripts/synth" || true
pkill -f "make DESIGN_CONFIG=.*evpix_asic" || true
pkill -f "scripts/10_run_sky130hd.sh" || true
pkill -f "00_RUN_ME_FIRST_SKY130_FULL.sh" || true
sleep 2

echo "Processes after kill:"
ps -eo pid,etime,%cpu,%mem,cmd | grep -E "evpix_asic|yosys-abc|yosys|openroad|make DESIGN_CONFIG=.*evpix_asic" | grep -v grep || true

echo "Done."
