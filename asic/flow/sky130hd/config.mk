# EVPIX ASIC OpenROAD-flow-scripts config: SkyWater SKY130 HD.
# V15 FAST/HIER + floorplan init fix config: avoids the 7+ hour flat ABC hang by synthesizing
# hierarchically and relaxing first-pass timing. Tighten clock/area only after
# the first clean GDS is produced.
export DESIGN_NICKNAME = evpix_asic
export DESIGN_NAME     = evpix_asic_core_top
export PLATFORM        = sky130hd

# Path injected by scripts/02_install_designs_into_orfs.sh
export DESIGN_HOME ?= $(abspath ../../../../../../evpix_asic_openroad_kit_v15_floorplan_fix)
include $(DESIGN_HOME)/flow/rtl_files.mk

export SDC_FILE = $(DESIGN_HOME)/flow/sky130hd/constraint.sdc

# Physical margins for first successful RTL-to-GDS run.
# NOTE: Do not set CORE_UTILIZATION together with DIE_AREA/CORE_AREA.
# OpenROAD floorplan init treats those as mutually exclusive.
export PLACE_DENSITY    = 0.32
export TNS_END_PERCENT  = 100

# Relax first-pass timing. This is a bring-up GDS run, not timing closure.
export ABC_CLOCK_PERIOD_IN_PS = 100000
export SDC_FILE_CLOCK_PERIOD  = 100.0

# The v10 flat synthesis run reached ABC and stayed there for 7+ hours. Keep
# hierarchy so ABC maps smaller modules instead of one huge flattened network.
export SYNTH_HIERARCHICAL = 1
export REMOVE_ABC_BUFFERS = 1
export ABC_AREA           = 1

# Large conservative area to avoid placement/routing congestion on first run.
export DIE_AREA  = 0 0 5500 5500
export CORE_AREA = 150 150 5350 5350
