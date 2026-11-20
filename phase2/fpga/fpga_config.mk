# Task 5 FPGA Implementation Configuration
# Target FPGA device, board, and constraint files are intentionally UNSPECIFIED
# because no target FPGA board or part number is defined in the repository.

FPGA_BUILD_DIR       ?= $(BUILD_DIR)/fpga
FPGA_SYNTH_FAMILY    ?= xc7
FPGA_CROSS_FAMILY    ?= ecp5
FPGA_TARGET_PART     ?= UNSPECIFIED
FPGA_BOARD           ?= UNSPECIFIED
FPGA_CONSTRAINTS     ?=
# Assumed simulation reference period from Task 2/Task 4 (NOT a verified FPGA timing constraint)
FPGA_REF_CLK_PERIOD_NS ?= 10.0
