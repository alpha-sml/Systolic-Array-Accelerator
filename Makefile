IVERILOG ?= iverilog
VVP ?= vvp
YOSYS ?= yosys
BUILD_DIR := build
IVERILOG_FLAGS := -g2012 -Wall

MAC_RTL := rtl/mac_unit.v
PE_RTL := $(MAC_RTL) rtl/processing_element.v
ARRAY_RTL := $(PE_RTL) rtl/pe_interconnect.v rtl/systolic_array.v
CTRL_RTL := rtl/control_fsm.v rtl/systolic_controller.v
DATA_RTL := rtl/input_buffer.v rtl/output_buffer.v rtl/matrix_interface.v
TOP_RTL := $(ARRAY_RTL) $(CTRL_RTL) $(DATA_RTL) rtl/top_module.v

.PHONY: test test-mac test-pe test-array test-controller test-data test-top synth-check clean

test: test-mac test-pe test-array test-controller test-data test-top

test-mac: $(BUILD_DIR)
	$(IVERILOG) $(IVERILOG_FLAGS) -s tb_mac_unit -o $(BUILD_DIR)/tb_mac_unit.vvp $(MAC_RTL) testbench/tb_mac_unit.v
	$(VVP) $(BUILD_DIR)/tb_mac_unit.vvp

test-pe: $(BUILD_DIR)
	$(IVERILOG) $(IVERILOG_FLAGS) -s tb_processing_element -o $(BUILD_DIR)/tb_processing_element.vvp $(PE_RTL) testbench/tb_processing_element.v
	$(VVP) $(BUILD_DIR)/tb_processing_element.vvp

test-array: $(BUILD_DIR)
	$(IVERILOG) $(IVERILOG_FLAGS) -s tb_systolic_array -o $(BUILD_DIR)/tb_systolic_array.vvp $(ARRAY_RTL) testbench/tb_systolic_array.v
	$(VVP) $(BUILD_DIR)/tb_systolic_array.vvp

test-controller: $(BUILD_DIR)
	$(IVERILOG) $(IVERILOG_FLAGS) -s tb_systolic_controller -o $(BUILD_DIR)/tb_systolic_controller.vvp $(CTRL_RTL) testbench/tb_systolic_controller.v
	$(VVP) $(BUILD_DIR)/tb_systolic_controller.vvp

test-data: $(BUILD_DIR)
	$(IVERILOG) $(IVERILOG_FLAGS) -s tb_data_management -o $(BUILD_DIR)/tb_data_management.vvp $(DATA_RTL) testbench/tb_data_management.v
	$(VVP) $(BUILD_DIR)/tb_data_management.vvp

test-top: $(BUILD_DIR)
	$(IVERILOG) $(IVERILOG_FLAGS) -s tb_top_module -o $(BUILD_DIR)/tb_top_module.vvp $(TOP_RTL) testbench/tb_top_module.v
	$(VVP) $(BUILD_DIR)/tb_top_module.vvp

synth-check: $(BUILD_DIR)
	@if command -v $(YOSYS) >/dev/null 2>&1; then \
		$(YOSYS) -Q -p 'read_verilog -sv $(TOP_RTL); hierarchy -check -top top_module; proc; check'; \
	else \
		echo "Yosys is not installed; structural check was not run."; \
	fi

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

clean:
	rm -rf $(BUILD_DIR)
