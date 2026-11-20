IVERILOG ?= iverilog
VVP ?= vvp
YOSYS ?= yosys
BUILD_DIR := build
IVERILOG_FLAGS := -g2012 -Wall

-include fpga/fpga_config.mk

MAC_RTL := rtl/core/mac_unit.v
PE_RTL := $(MAC_RTL) rtl/core/processing_element.v
ARRAY_RTL := $(PE_RTL) rtl/core/pe_interconnect.v rtl/core/systolic_array.v
CTRL_RTL := rtl/core/control_fsm.v rtl/core/systolic_controller.v
DATA_RTL := rtl/interface/input_buffer.v rtl/interface/output_buffer.v rtl/interface/matrix_interface.v
TOP_RTL := $(ARRAY_RTL) $(CTRL_RTL) $(DATA_RTL) rtl/core/top_module.v
TILED_RTL := $(ARRAY_RTL) $(CTRL_RTL) rtl/extensions/matrix_tiling_controller.v rtl/extensions/tiled_input_buffer.v rtl/extensions/partial_result_buffer.v rtl/extensions/tiled_gemm_top.v
PERF_RTL := $(TOP_RTL) rtl/extensions/matrix_tiling_controller.v rtl/extensions/tiled_input_buffer.v rtl/extensions/partial_result_buffer.v rtl/extensions/tiled_gemm_top.v
BURST_IF_RTL := $(ARRAY_RTL) $(CTRL_RTL) rtl/extensions/tiled_input_buffer.v rtl/extensions/matrix_tiling_controller.v rtl/extensions/partial_result_buffer.v rtl/extensions/burst_matrix_interface.v
INTEGRATED_TOP_RTL := $(BURST_IF_RTL) rtl/extensions/integrated_gemm_top.v
BASELINE_RTL := rtl/baseline/sequential_gemm.v

.PHONY: demo test test-core test-extensions test-mac test-pe test-array test-controller test-data test-top test-tiled test-performance test-burst-interface test-integrated-top test-baseline synth-check synth-check-tiled synth-check-integrated synth-check-baseline synth-fpga fpga-utilization fpga-path-analysis fpga-timing fpga-bitstream clean

test: test-core test-extensions test-baseline

test-core: test-mac test-pe test-array test-controller test-data test-top

test-extensions: test-tiled test-performance test-burst-interface test-integrated-top

demo: $(BUILD_DIR)
	$(IVERILOG) $(IVERILOG_FLAGS) -s tb_prototype_demo -o $(BUILD_DIR)/tb_prototype_demo.vvp $(TOP_RTL) testbench/core/tb_prototype_demo.v
	$(VVP) $(BUILD_DIR)/tb_prototype_demo.vvp

test-mac: $(BUILD_DIR)
	$(IVERILOG) $(IVERILOG_FLAGS) -s tb_mac_unit -o $(BUILD_DIR)/tb_mac_unit.vvp $(MAC_RTL) testbench/core/tb_mac_unit.v
	$(VVP) $(BUILD_DIR)/tb_mac_unit.vvp

test-pe: $(BUILD_DIR)
	$(IVERILOG) $(IVERILOG_FLAGS) -s tb_processing_element -o $(BUILD_DIR)/tb_processing_element.vvp $(PE_RTL) testbench/core/tb_processing_element.v
	$(VVP) $(BUILD_DIR)/tb_processing_element.vvp

test-array: $(BUILD_DIR)
	$(IVERILOG) $(IVERILOG_FLAGS) -s tb_systolic_array -o $(BUILD_DIR)/tb_systolic_array.vvp $(ARRAY_RTL) testbench/core/tb_systolic_array.v
	$(VVP) $(BUILD_DIR)/tb_systolic_array.vvp

test-controller: $(BUILD_DIR)
	$(IVERILOG) $(IVERILOG_FLAGS) -s tb_systolic_controller -o $(BUILD_DIR)/tb_systolic_controller.vvp $(CTRL_RTL) testbench/core/tb_systolic_controller.v
	$(VVP) $(BUILD_DIR)/tb_systolic_controller.vvp

test-data: $(BUILD_DIR)
	$(IVERILOG) $(IVERILOG_FLAGS) -s tb_data_management -o $(BUILD_DIR)/tb_data_management.vvp $(DATA_RTL) testbench/interface/tb_data_management.v
	$(VVP) $(BUILD_DIR)/tb_data_management.vvp

test-top: $(BUILD_DIR)
	$(IVERILOG) $(IVERILOG_FLAGS) -s tb_top_module -o $(BUILD_DIR)/tb_top_module.vvp $(TOP_RTL) testbench/core/tb_top_module.v
	$(VVP) $(BUILD_DIR)/tb_top_module.vvp

test-tiled: $(BUILD_DIR)
	$(IVERILOG) $(IVERILOG_FLAGS) -s tb_tiled_gemm -o $(BUILD_DIR)/tb_tiled_gemm.vvp $(TILED_RTL) testbench/extensions/tb_tiled_gemm.v
	$(VVP) $(BUILD_DIR)/tb_tiled_gemm.vvp

test-performance: $(BUILD_DIR)
	$(IVERILOG) $(IVERILOG_FLAGS) -s tb_performance -o $(BUILD_DIR)/tb_performance.vvp $(PERF_RTL) testbench/extensions/tb_performance.v
	$(VVP) $(BUILD_DIR)/tb_performance.vvp

test-burst-interface: $(BUILD_DIR)
	$(IVERILOG) $(IVERILOG_FLAGS) -s tb_burst_interface -o $(BUILD_DIR)/tb_burst_interface.vvp $(BURST_IF_RTL) testbench/extensions/tb_burst_interface.v
	$(VVP) $(BUILD_DIR)/tb_burst_interface.vvp

test-integrated-top: $(BUILD_DIR)
	$(IVERILOG) $(IVERILOG_FLAGS) -s tb_integrated_top -o $(BUILD_DIR)/tb_integrated_top.vvp $(INTEGRATED_TOP_RTL) testbench/extensions/tb_integrated_top.v
	$(VVP) $(BUILD_DIR)/tb_integrated_top.vvp

test-baseline: $(BUILD_DIR)
	$(IVERILOG) $(IVERILOG_FLAGS) -s tb_sequential_gemm -o $(BUILD_DIR)/tb_sequential_gemm.vvp $(BASELINE_RTL) testbench/baseline/tb_sequential_gemm.v
	$(VVP) $(BUILD_DIR)/tb_sequential_gemm.vvp

synth-check: $(BUILD_DIR)
	@if command -v $(YOSYS) >/dev/null 2>&1; then \
		$(YOSYS) -Q -p 'read_verilog -sv $(TOP_RTL); hierarchy -check -top top_module; proc; opt; check -assert'; \
	else \
		echo "ERROR: Yosys ($(YOSYS)) is not installed; structural check failed." >&2; \
		exit 1; \
	fi

synth-check-tiled: $(BUILD_DIR)
	@if command -v $(YOSYS) >/dev/null 2>&1; then \
		$(YOSYS) -Q -p 'read_verilog -sv $(TILED_RTL); hierarchy -check -top tiled_gemm_top; proc; opt; check -assert'; \
	else \
		echo "ERROR: Yosys ($(YOSYS)) is not installed; structural check failed." >&2; \
		exit 1; \
	fi

synth-check-integrated: $(BUILD_DIR)
	@if command -v $(YOSYS) >/dev/null 2>&1; then \
		$(YOSYS) -Q -p 'read_verilog -sv $(INTEGRATED_TOP_RTL); hierarchy -check -top integrated_gemm_top; proc; opt; check -assert'; \
	else \
		echo "ERROR: Yosys ($(YOSYS)) is not installed; structural check failed." >&2; \
		exit 1; \
	fi

synth-check-baseline: $(BUILD_DIR)
	@if command -v $(YOSYS) >/dev/null 2>&1; then \
		$(YOSYS) -Q -p 'read_verilog -sv $(BASELINE_RTL); hierarchy -check -top sequential_gemm; proc; opt; check -assert'; \
	else \
		echo "ERROR: Yosys ($(YOSYS)) is not installed; structural check failed." >&2; \
		exit 1; \
	fi

synth-fpga: $(BUILD_DIR)
	@YOSYS="$(YOSYS)" FPGA_TARGET_PART="$(FPGA_TARGET_PART)" FPGA_BOARD="$(FPGA_BOARD)" FPGA_CONSTRAINTS="$(FPGA_CONSTRAINTS)" \
		bash fpga/scripts/check_fpga_env.sh synth
	@YOSYS="$(YOSYS)" FPGA_TARGET_PART="$(FPGA_TARGET_PART)" FPGA_BOARD="$(FPGA_BOARD)" \
		bash fpga/scripts/run_yosys_synth.sh --build-dir "$(FPGA_BUILD_DIR)" --family "$(FPGA_SYNTH_FAMILY)" --mode synth

fpga-utilization: $(BUILD_DIR)
	@if [ ! -f "$(FPGA_BUILD_DIR)/integrated_gemm_top_$(FPGA_SYNTH_FAMILY)_flat_stat.txt" ]; then \
		$(MAKE) synth-fpga; \
	fi
	@python3 fpga/scripts/parse_yosys_reports.py --build-dir "$(FPGA_BUILD_DIR)" --family "$(FPGA_SYNTH_FAMILY)" --print utilization

fpga-path-analysis: $(BUILD_DIR)
	@YOSYS="$(YOSYS)" FPGA_TARGET_PART="$(FPGA_TARGET_PART)" FPGA_BOARD="$(FPGA_BOARD)" FPGA_CONSTRAINTS="$(FPGA_CONSTRAINTS)" \
		bash fpga/scripts/check_fpga_env.sh synth
	@if [ -f "$(FPGA_BUILD_DIR)/integrated_gemm_top_$(FPGA_SYNTH_FAMILY)_flat.log" ]; then \
		YOSYS="$(YOSYS)" FPGA_TARGET_PART="$(FPGA_TARGET_PART)" FPGA_BOARD="$(FPGA_BOARD)" \
			bash fpga/scripts/run_yosys_synth.sh --build-dir "$(FPGA_BUILD_DIR)" --family "$(FPGA_SYNTH_FAMILY)" --mode path; \
	else \
		YOSYS="$(YOSYS)" FPGA_TARGET_PART="$(FPGA_TARGET_PART)" FPGA_BOARD="$(FPGA_BOARD)" \
			bash fpga/scripts/run_yosys_synth.sh --build-dir "$(FPGA_BUILD_DIR)" --family "$(FPGA_SYNTH_FAMILY)" --mode all; \
	fi
	@python3 fpga/scripts/parse_yosys_reports.py --build-dir "$(FPGA_BUILD_DIR)" --family "$(FPGA_SYNTH_FAMILY)" --print timing

fpga-timing:
	@YOSYS="$(YOSYS)" FPGA_TARGET_PART="$(FPGA_TARGET_PART)" FPGA_BOARD="$(FPGA_BOARD)" FPGA_CONSTRAINTS="$(FPGA_CONSTRAINTS)" \
		bash fpga/scripts/check_fpga_env.sh timing
	@if command -v vivado >/dev/null 2>&1; then \
		vivado -mode batch -source fpga/scripts/vivado_impl_template.tcl \
			-tclargs timing "$(FPGA_TARGET_PART)" "$(FPGA_CONSTRAINTS)" "$(FPGA_BUILD_DIR)/vivado"; \
	else \
		echo "ERROR: Supported STA backend invocation is configured for Vivado; detected non-Vivado tool requires manual project setup." >&2; \
		exit 1; \
	fi

fpga-bitstream:
	@YOSYS="$(YOSYS)" FPGA_TARGET_PART="$(FPGA_TARGET_PART)" FPGA_BOARD="$(FPGA_BOARD)" FPGA_CONSTRAINTS="$(FPGA_CONSTRAINTS)" \
		bash fpga/scripts/check_fpga_env.sh bitstream
	@if command -v vivado >/dev/null 2>&1; then \
		vivado -mode batch -source fpga/scripts/vivado_impl_template.tcl \
			-tclargs bitstream "$(FPGA_TARGET_PART)" "$(FPGA_CONSTRAINTS)" "$(FPGA_BUILD_DIR)/vivado"; \
	else \
		echo "ERROR: Supported bitstream backend invocation is configured for Vivado; detected non-Vivado tool requires manual project setup." >&2; \
		exit 1; \
	fi

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

clean:
	rm -rf $(BUILD_DIR)
