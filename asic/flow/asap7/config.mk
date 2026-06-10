# EVPIX ASIC OpenROAD-flow-scripts config: ASAP7 comparison.
export DESIGN_NICKNAME = evpix_asic
export DESIGN_NAME     = evpix_asic_core_top
export PLATFORM        = asap7
export DESIGN_HOME ?= $(abspath ../../../../../../evpix_asic_openroad_kit_v15_floorplan_fix)
include $(DESIGN_HOME)/flow/rtl_files.mk
export SDC_FILE = $(DESIGN_HOME)/flow/asap7/constraint.sdc
# NOTE: Do not set CORE_UTILIZATION together with DIE_AREA/CORE_AREA.
# OpenROAD floorplan init treats those as mutually exclusive.
export PLACE_DENSITY    = 0.30
export TNS_END_PERCENT  = 100
export ABC_CLOCK_PERIOD_IN_PS = 50000
export SDC_FILE_CLOCK_PERIOD  = 50.0
export SYNTH_HIERARCHICAL = 1
export REMOVE_ABC_BUFFERS = 1
export ABC_AREA           = 1
export DIE_AREA  = 0 0 1000 1000
export CORE_AREA = 25 25 975 975
