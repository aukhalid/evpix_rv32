EVPIX-RV32 upgraded package
===========================

What was added
--------------
1. Generic 3x3 convolution accelerator
2. Max/avg pooling accelerator
3. Non-blocking custom-0 control path
4. Performance counters

Custom-0 ISA convention used here
---------------------------------
opcode = 7'b0001011

funct3 meanings:
  000 : IPU_START   (rd gets 1 if accepted, 0 if IPU busy)
  001 : IPU_STATUS  (rd[0]=busy, rd[1]=done)
  010 : IPU_RESULT  (rd gets last result)
  011 : IPU_PERF    (rd gets selected performance counter)

For IPU_START instructions:
  rs1 = src_base
  rs2 = dst_base
  funct7[2:0] = operation ID
  funct7[6:3] = kernel ID (used only for generic convolution)

Operation IDs (funct7[2:0]):
  0 : grayscale
  1 : threshold
  2 : maxpixel
  3 : sobel
  4 : generic convolution
  5 : maxpool
  6 : avgpool

Kernel IDs (funct7[6:3]) for generic convolution:
  0 : identity
  1 : sobel x
  2 : sobel y
  3 : gaussian blur
  4 : sharpen
  5 : edge detect

For IPU_PERF instructions:
  funct7[2:0] counter selector
    0 : total cycle count
    1 : IPU busy cycles
    2 : convolution cycles
    3 : pooling cycles
    4 : stall cycles

Simulation files
----------------
memfile_rv32i.hex        : baseline RV32I regression program
memfile_ipu_system.hex   : full upgraded IPU system test program
memfile_pix.hex          : same as memfile_ipu_system.hex (default instruction memory file)
image_rgb888_small.hex   : 8x8 RGB888 test image (vertical edge)

tb_rv32i_top.sv          : baseline RV32I testbench
 tb_ipu_system.sv         : upgraded IPU integration testbench

Recommended simulation flow
---------------------------
1. Baseline core regression:
     use tb_rv32i_top.sv
2. Upgraded IPU regression:
     use tb_ipu_system.sv

Both testbenches are self-checking.
