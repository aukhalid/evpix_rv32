# Common RTL for EVPIX ASIC OpenROAD top.
# This list intentionally excludes FPGA-only VGA/OV7670/SCCB/display RAM modules.
export VERILOG_FILES = \
  $(DESIGN_HOME)/rtl/common/adder.sv \
  $(DESIGN_HOME)/rtl/common/alu.sv \
  $(DESIGN_HOME)/rtl/common/alu_control.sv \
  $(DESIGN_HOME)/rtl/common/branch_unit.sv \
  $(DESIGN_HOME)/rtl/common/main_control.sv \
  $(DESIGN_HOME)/rtl/common/imm_generator.sv \
  $(DESIGN_HOME)/rtl/common/program_counter.sv \
  $(DESIGN_HOME)/rtl/common/register_file.sv \
  $(DESIGN_HOME)/rtl/common/forwarding_unit.sv \
  $(DESIGN_HOME)/rtl/common/hazard_detection_unit.sv \
  $(DESIGN_HOME)/rtl/common/if_id_reg.sv \
  $(DESIGN_HOME)/rtl/common/id_ex_reg.sv \
  $(DESIGN_HOME)/rtl/common/ex_mem_reg.sv \
  $(DESIGN_HOME)/rtl/common/mem_wb_reg.sv \
  $(DESIGN_HOME)/rtl/common/writeback_stage.sv \
  $(DESIGN_HOME)/rtl/common/fetch_stage.sv \
  $(DESIGN_HOME)/rtl/common/execute_stage.sv \
  $(DESIGN_HOME)/rtl/common/decode_stage.sv \
  $(DESIGN_HOME)/rtl/common/datapath.sv \
  $(DESIGN_HOME)/rtl/common/instruction_memory_fpga.sv \
  $(DESIGN_HOME)/rtl/common/ipu_fpga.sv \
  $(DESIGN_HOME)/rtl/common/evpix_ml_feature_extractor.sv \
  $(DESIGN_HOME)/rtl/common/evpix_tinyml_classifier.sv \
  $(DESIGN_HOME)/rtl/asic/rv32i_core_asic_extmem.sv \
  $(DESIGN_HOME)/rtl/asic/evpix_asic_core_top.sv
