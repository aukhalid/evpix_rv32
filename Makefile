#==============================================================================
# EVPIX-RV32 — Master Project Makefile
# Repo   : https://github.com/aukhalid/evpix_rv32
# Author : Ahasan Ullah Khalid
#
# Tools required
# ──────────────
#  Simulation  : Vivado xsim  (xvlog → xelab → xsim)
#  FPGA        : Vivado batch (synth → impl → bitstream → program)
#  ASIC        : OpenROAD-Flow-Scripts via your asic/scripts/ shell scripts
#
# Quick reference
# ───────────────
#  make help              show all targets
#  make setup             create build/ folder tree (run once after git clone)
#
#  make sim_core          simulate tb_rv32i_top        (RV32I pipeline regression)
#  make sim_ipu           simulate tb_ipu_system       (IPU system test)
#  make sim_custom        simulate tb_rv32i_ipu_custom (custom ISA + IPU joint test)
#  make sim_all           run all three testbenches in sequence
#
#  make fpga_synth_only   Vivado synthesis → post_synth.dcp
#  make fpga_impl_only    Vivado P&R       → post_route.dcp
#  make fpga_bit_only     Generate bitstream
#  make fpga_all          Full Vivado flow (synth → impl → bit) in one shot
#  make fpga_program      Flash Basys-3 via JTAG
#
#  make asic_setup_check  Verify ORFS install + tools
#  make asic_install      Install design into ORFS
#  make asic_synth_only   Yosys synthesis only
#  make asic_all          Full RTL-to-GDSII (SKY130HD) — takes 20-60 min
#  make asic_asap7        Full ASAP7 variant flow
#  make asic_report       Print QoR metrics
#  make asic_view         Open GDSII in KLayout
#  make asic_kill         Kill a stuck flow
#
#  make clean             Remove simulation artifacts only
#  make clean_all         Remove all build artifacts (sim + fpga + asic)
#  make distclean         Remove the entire build/ directory

#==============================================================================

SHELL       := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

#==============================================================================
# 0.  PROJECT PATHS
#==============================================================================
ROOT_DIR     := $(CURDIR)

# ── Simulation paths (Used ONLY for sim_* targets) ───────────────────────────
SIM_RTL_DIR  := $(ROOT_DIR)/simulation/rtl_src
SIM_TB_DIR   := $(ROOT_DIR)/simulation/testbench

# ── FPGA/ASIC paths (Used for Synthesis & Physical Design) ───────────────────
FPGA_RTL_DIR := $(ROOT_DIR)/fpga/rtl_src
FPGA_XDC     := $(ROOT_DIR)/fpga/constrains/evpix_basys3.xdc
ASIC_SCRIPTS := $(ROOT_DIR)/asic/scripts

# ── Vivado tools ─────────────────────────────────────────────────────────────
VIVADO       ?= vivado
XVLOG        ?= xvlog
XELAB        ?= xelab
XSIM         ?= xsim

# ── FPGA device / top ────────────────────────────────────────────────────────
FPGA_PART    ?= xc7a35tcpg236-1
FPGA_TOP     ?= evpix_top_ov7670_direct

# ── ASIC variables ───────────────────────────────────────────────────────────
ORFS_DIR     ?= $(HOME)/OpenROAD-flow-scripts
PLATFORM     ?= sky130hd

# ── Build output tree ────────────────────────────────────────────────────────
BUILD_DIR    := $(ROOT_DIR)/build
SIM_BUILD    := $(BUILD_DIR)/sim
FPGA_BUILD   := $(BUILD_DIR)/fpga
ASIC_BUILD   := $(BUILD_DIR)/asic

# ── Source Arrays (alphabetical order handles packages cleanly) ──────────────
SIM_SV_SRCS  := $(sort $(wildcard $(SIM_RTL_DIR)/*.sv))
FPGA_SV_SRCS := $(sort $(wildcard $(FPGA_RTL_DIR)/*.sv))

#==============================================================================
# 1.  .PHONY DECLARATIONS
#==============================================================================
.PHONY: help setup dirs \
        sim_core sim_ipu sim_custom sim_all sim_clean \
        fpga_gen_tcl fpga_synth_only fpga_impl_only fpga_bit_only \
        fpga_all fpga_program fpga_clean \
        asic_setup_check asic_install asic_synth_only \
        asic_all asic_asap7 asic_report asic_gds_copy \
        asic_view asic_kill asic_last_error asic_clean \
        clean clean_all distclean

#==============================================================================
# 2.  HELP
#==============================================================================
help: ## Show this help menu
	@printf "\n\033[1;36m EVPIX-RV32  ─  Build Automation (Vivado + ORFS)\033[0m\n"
	@printf " ════════════════════════════════════════════════════════\n"
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
	  awk 'BEGIN{FS=":.*?## "} {printf "  \033[32m%-22s\033[0m %s\n", $$1, $$2}'
	@printf "\n\033[90m Overridable variables:\033[0m\n"
	@printf "   VIVADO=<path>      path to vivado binary  (default: vivado)\n"
	@printf "   WAVES=0|1          0=no dump (default)  1=open Vivado wave viewer\n"
	@printf "   FPGA_TOP=<module>  top module name  (default: evpix_top_ov7670_direct)\n"
	@printf "   FPGA_PART=<part>   Xilinx part number  (default: xc7a35tcpg236-1)\n"
	@printf "   ORFS_DIR=<path>    OpenROAD-flow-scripts root  (default: ~/OpenROAD-flow-scripts)\n\n"

#==============================================================================
# 3.  SETUP — Create build/ folder tree
#==============================================================================
dirs:
	@mkdir -p \
	  $(SIM_BUILD)/logs \
	  $(SIM_BUILD)/xsim.dir \
	  $(FPGA_BUILD)/synth \
	  $(FPGA_BUILD)/impl \
	  $(FPGA_BUILD)/bitstream \
	  $(FPGA_BUILD)/reports \
	  $(FPGA_BUILD)/logs \
	  $(ASIC_BUILD)/logs \
	  $(ASIC_BUILD)/reports \
	  $(ASIC_BUILD)/gds

setup: dirs ## First-time setup after git clone

#==============================================================================
# 4.  SIMULATION — Vivado xsim (Uses simulation/ folder)
#==============================================================================
WAVES ?= 0

define _xsim
	@echo ""
	@printf " \033[1;33m▶  Simulating: $(1)\033[0m\n"
	@echo " ──────────────────────────────────────────────────────"
	@echo "   Step 0: Clearing previous simulation run logs/snapshots..."
	@rm -rf $(SIM_BUILD)/xsim.dir/$(1)_snapshot*
	@rm -f $(SIM_BUILD)/logs/$(1)_*.log
	@echo "   Step 1: Copying memory hex files → $(SIM_BUILD)/"
	@cp -f $(SIM_TB_DIR)/*.hex $(SIM_BUILD)/ 2>/dev/null || true
	@echo "   Step 2: xvlog (Compilation from simulation/rtl_src)"
	cd $(SIM_BUILD) && \
	$(XVLOG) --sv \
	  --work work \
	  -i $(SIM_RTL_DIR) \
	  --log logs/$(1)_xvlog.log \
	  $(SIM_SV_SRCS) \
	  $(SIM_TB_DIR)/$(1).sv
	@echo "   Step 3: xelab (Elaboration)"
	cd $(SIM_BUILD) && \
	$(XELAB) work.$(1) \
	  -debug all \
	  -s $(1)_snapshot \
	  --log logs/$(1)_xelab.log
	@echo "   Step 4: xsim (Simulation Execution)"
	cd $(SIM_BUILD) && \
	if [ "$(WAVES)" = "1" ]; then \
		$(XSIM) $(1)_snapshot -gui -log logs/$(1)_xsim.log; \
	else \
		$(XSIM) $(1)_snapshot -runall -log logs/$(1)_xsim.log; \
	fi
	@echo "   ✓ Logs saved to: $(SIM_BUILD)/logs/$(1)_xsim.log"
endef

sim_core: dirs ## Simulate tb_rv32i_top (RV32I pipeline regression)
	$(call _xsim,tb_rv32i_top)

sim_ipu: dirs ## Simulate tb_ipu_system (IPU system functional test)
	$(call _xsim,tb_ipu_system)

sim_custom: dirs ## Simulate tb_rv32i_ipu_custom (custom ISA + IPU joint test)
	$(call _xsim,tb_rv32i_ipu_custom)

sim_all: sim_core sim_ipu sim_custom ## Run all three testbenches sequentially

sim_clean: ## Remove simulation build artifacts
	rm -rf $(SIM_BUILD)

#==============================================================================
# 5.  FPGA FLOW — Vivado batch mode (Uses fpga/ folder)
#==============================================================================

define _SYNTH_TCL
create_project -in_memory -part $(FPGA_PART)
set_property DEFAULT_LIB work [current_project]
$(foreach f,$(FPGA_SV_SRCS),read_verilog -sv $(f)
)read_xdc $(FPGA_XDC)
synth_design -top $(FPGA_TOP) -part $(FPGA_PART)
write_checkpoint -force $(FPGA_BUILD)/synth/post_synth.dcp
report_utilization    -file $(FPGA_BUILD)/reports/utilization_synth.rpt
report_timing_summary -file $(FPGA_BUILD)/reports/timing_synth.rpt
puts "=== SYNTHESIS DONE ==="
endef

define _IMPL_TCL
open_checkpoint $(FPGA_BUILD)/synth/post_synth.dcp
read_xdc $(FPGA_XDC)
opt_design
place_design
phys_opt_design
route_design
write_checkpoint     -force $(FPGA_BUILD)/impl/post_route.dcp
report_timing_summary -file $(FPGA_BUILD)/reports/timing_route.rpt
report_utilization    -file $(FPGA_BUILD)/reports/utilization_impl.rpt
report_power          -file $(FPGA_BUILD)/reports/power.rpt
puts "=== IMPLEMENTATION DONE ==="
endef

define _BIT_TCL
open_checkpoint $(FPGA_BUILD)/impl/post_route.dcp
write_bitstream -force -compress $(FPGA_BUILD)/bitstream/evpix_rv32_top.bit
puts "=== BITSTREAM DONE ==="
endef

define _PROG_TCL
open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $$dev
set_property PROGRAM.FILE {$(FPGA_BUILD)/bitstream/evpix_rv32_top.bit} $$dev
program_hw_devices $$dev
disconnect_hw_target
close_hw_manager
puts "=== BASYS-3 PROGRAMMED ==="
endef

fpga_gen_tcl: dirs
	$(file >$(FPGA_BUILD)/synth.tcl,$(_SYNTH_TCL))
	$(file >$(FPGA_BUILD)/impl.tcl,$(_IMPL_TCL))
	$(file >$(FPGA_BUILD)/bit.tcl,$(_BIT_TCL))
	$(file >$(FPGA_BUILD)/prog.tcl,$(_PROG_TCL))

fpga_synth_only: fpga_gen_tcl ## Run synthesis  →  post_synth.dcp
	@echo "Cleaning old synthesis outputs..."
	@rm -f $(FPGA_BUILD)/synth/post_synth.dcp $(FPGA_BUILD)/logs/synth.*
	$(VIVADO) -mode batch \
	  -source $(FPGA_BUILD)/synth.tcl \
	  -log    $(FPGA_BUILD)/logs/synth.log \
	  -journal $(FPGA_BUILD)/logs/synth.jou
	@echo "  ✓ Synthesis completed. Reports generated in $(FPGA_BUILD)/reports/"

fpga_impl_only: ## Place & Route  →  post_route.dcp (requires synthesis checkpoint)
	@[ -f $(FPGA_BUILD)/synth/post_synth.dcp ] || \
	  { echo "ERROR: Run 'make fpga_synth_only' first. No synthesis checkpoint found!"; exit 1; }
	@echo "Cleaning old implementation outputs..."
	@rm -f $(FPGA_BUILD)/impl/post_route.dcp $(FPGA_BUILD)/logs/impl.*
	@$(MAKE) fpga_gen_tcl
	$(VIVADO) -mode batch \
	  -source $(FPGA_BUILD)/impl.tcl \
	  -log    $(FPGA_BUILD)/logs/impl.log \
	  -journal $(FPGA_BUILD)/logs/impl.jou
	@echo "  ✓ Implementation completed."

fpga_bit_only: ## Generate bitstream  →  evpix_rv32_top.bit (requires implementation checkpoint)
	@[ -f $(FPGA_BUILD)/impl/post_route.dcp ] || \
	  { echo "ERROR: Run 'make fpga_impl_only' first. No implementation checkpoint found!"; exit 1; }
	@echo "Cleaning old bitstream outputs..."
	@rm -f $(FPGA_BUILD)/bitstream/evpix_rv32_top.bit $(FPGA_BUILD)/logs/bit.*
	@$(MAKE) fpga_gen_tcl
	$(VIVADO) -mode batch \
	  -source $(FPGA_BUILD)/bit.tcl \
	  -log    $(FPGA_BUILD)/logs/bit.log \
	  -journal $(FPGA_BUILD)/logs/bit.jou
	@echo "  ✓ Bitstream generated at $(FPGA_BUILD)/bitstream/evpix_rv32_top.bit"

fpga_all: dirs ## Complete Vivado pipeline: synth → impl → bitstream
	@$(MAKE) fpga_synth_only
	@$(MAKE) fpga_impl_only
	@$(MAKE) fpga_bit_only
	@printf "\n\033[1;32m╔════════════════════════════════════════════════════╗\033[0m\n"
	@printf " \033[1;32m ║  FPGA flow complete!                               ║\033[0m\n"
	@printf " \033[1;32m ╚════════════════════════════════════════════════════╝\033[0m\n\n"

fpga_program: ## Flash bitstream to target device via hardware manager JTAG
	@[ -f $(FPGA_BUILD)/bitstream/evpix_rv32_top.bit ] || \
	  { echo "ERROR: Bitstream file not found. Run 'make fpga_all' first!"; exit 1; }
	@$(MAKE) fpga_gen_tcl
	$(VIVADO) -mode batch \
	  -source $(FPGA_BUILD)/prog.tcl \
	  -log    $(FPGA_BUILD)/logs/prog.log \
	  -journal $(FPGA_BUILD)/logs/prog.jou

fpga_clean: ## Remove FPGA build directory
	rm -rf $(FPGA_BUILD)

#==============================================================================
# 6.  ASIC FLOW — OpenROAD-Flow-Scripts (SKY130HD / ASAP7)
#==============================================================================

asic_setup_check: dirs ## Verify installation status of environment utilities
	@echo "Verifying environment capabilities..."
	@bash $(ASIC_SCRIPTS)/01_check_tools.sh 2>&1 | tee $(ASIC_BUILD)/logs/check_tools.log
	@[ -d "$(ORFS_DIR)" ] || \
	  { echo "ERROR: ORFS directory not found at $(ORFS_DIR). Explicitly declare using ORFS_DIR=<path>"; exit 1; }

asic_install: dirs ## Port local configuration layouts across into active ORFS path
	@echo "Cleaning out previous setups in execution directories..."
	@rm -f $(ASIC_BUILD)/logs/install.log
	@echo "Installing configuration assets..."
	@bash $(ASIC_SCRIPTS)/02_install_designs_into_orfs.sh 2>&1 | tee $(ASIC_BUILD)/logs/install.log

asic_synth_only: dirs ## Execute isolated RTL logic synthesis structural maps via Yosys
	@rm -f $(ASIC_BUILD)/logs/synth_only.log
	@bash $(ASIC_SCRIPTS)/40_yosys_synth_only.sh 2>&1 | tee $(ASIC_BUILD)/logs/synth_only.log

asic_all: dirs ## Launch the complete monolithic RTL-to-GDSII flow pipeline (SKY130HD)
	@echo "Cleaning up prior execution run metrics and build outputs..."
	@rm -f $(ASIC_BUILD)/logs/sky130hd_flow.log
	@printf "\n \033[1;36m▶ Initializing physical design mapping flow: [Platform: $(PLATFORM)]\033[0m\n\n"
	@bash $(ASIC_SCRIPTS)/10_run_sky130hd.sh 2>&1 | tee $(ASIC_BUILD)/logs/sky130hd_flow.log
	@$(MAKE) asic_report
	@$(MAKE) asic_gds_copy

asic_asap7: dirs ## Launch variant execution runs utilizing advanced node models
	@rm -f $(ASIC_BUILD)/logs/asap7_flow.log
	@bash $(ASIC_SCRIPTS)/20_run_asap7.sh 2>&1 | tee $(ASIC_BUILD)/logs/asap7_flow.log

asic_report: dirs ## Extract execution parameters to compile localized structural report maps
	@bash $(ASIC_SCRIPTS)/30_collect_reports.sh 2>&1 | tee $(ASIC_BUILD)/reports/qor_summary.txt
	@cat $(ASIC_BUILD)/reports/qor_summary.txt

asic_gds_copy: dirs ## Extract deep layout stream formats to target delivery trees
	@bash $(ASIC_SCRIPTS)/70_MAKE_GDSII_COPY.sh 2>&1 | tee $(ASIC_BUILD)/logs/gds_copy.log

asic_view: ## Open and load structural file data outputs into layout viewer interface
	@bash $(ASIC_SCRIPTS)/80_VIEW_LAYOUT.sh

asic_kill: ## Abruptly terminate deadlocked/hung physical floorplanning tasks
	@bash $(ASIC_SCRIPTS)/98_KILL_STUCK_EVPIX_FLOW.sh

asic_last_error: ## Query local log outputs to dump last identified stack exceptions
	@bash $(ASIC_SCRIPTS)/99_SHOW_LAST_ERROR.sh

asic_clean: ## Clear active ASIC flow artifact spaces
	rm -rf $(ASIC_BUILD)

#==============================================================================
# 7.  GLOBAL ENVIRONMENT CLEAN OPERATIONS
#==============================================================================
clean: sim_clean ## Clean out simulation snapshots (Daily cycle operations)
	@echo "  ✓ Simulation workspace cleared."

clean_all: sim_clean fpga_clean asic_clean ## Wipe runtime states across all physical execution modes
	@echo "  ✓ Combined platform target paths sanitized."

distclean: clean_all ## Perform complete structural workspace reset
	rm -rf $(BUILD_DIR)
	@echo "  ✓ Active 'build/' tree dropped. Execute 'make setup' to begin anew."