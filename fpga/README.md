# FPGA Synthesis and Hardware Evaluation

This directory contains the FPGA evaluation flow, scripts, and Yosys synthesis reports for the Systolic Array Matrix Multiplication Accelerator (`fpga/`).

---

## 1. Evaluation Stages: What Was Run vs. Not Run

It is essential to separate six distinct FPGA verification stages cleanly:

| Stage | Description | Tool / Target | Status |
| :--- | :--- | :--- | :--- |
| **1. RTL Structural Checks** | Verilog parsing, hierarchy elaboration, latch/driver DRC (`make synth-check*`) | Yosys `0.71+post` | **PASS** |
| **2. Yosys Technology-Mapped Synthesis** | Generic FPGA primitive mapping (`LUT1`–`LUT6`, `FDCE`/`FDPE`, `DSP48E1`, `CARRY4`, `BRAM`) (`make synth-fpga`) | Yosys `synth_xilinx -family xc7`, `synth_ecp5` | **PASS** |
| **3. Vendor FPGA Synthesis** | Vendor device-specific synthesis (`synth_design` / Quartus map) | Vivado / Quartus | **NOT RUN** (tools missing) |
| **4. Place-and-Route (PnR)** | Physical cell placement and interconnect routing (`make fpga-bitstream`) | Vivado / Quartus / `nextpnr` | **NOT RUN** (tools & pinout missing) |
| **5. Static Timing Analysis (STA)** | Routed critical-path delay, setup/hold slack, and $F_{\max}$ (`make fpga-timing`) | Vivado / Quartus / `nextpnr` + `icetime` | **NOT RUN** (tools & part missing) |
| **6. Physical Hardware Validation** | Bitstream download and on-board 3×3 / 6×6 matrix testing | FPGA development board + JTAG | **NOT RUN** (no hardware attached) |

> [!IMPORTANT]
> **Yosys resource mapping is pre-placement technology mapping, not a completed vendor FPGA implementation.** Because no target FPGA part or board is specified in the project, device utilization percentages, routed $F_{\max}$, bitstream generation, and physical FPGA testing were not performed.

---

## 2. Target Device and Toolchain

- **Target FPGA Part & Development Board:** **Unspecified** (no part number, speed grade, or board `.xdc`/`.sdc` constraint file exists in the repository; none was fabricated).
- **Evaluated Family in Yosys:** Xilinx 7-Series (`xc7`) for primary LUT/FF/DSP/BRAM attribution, with a Lattice ECP5 (`synth_ecp5`) cross-check.
- **Installed Tools (macOS ARM64):** `yosys 0.71+post` (`yosys-abc`), `iverilog 13.0`, `python3`.
- **Unavailable Tools:** Xilinx Vivado, Intel Quartus, `nextpnr-*`, `icetime`, `ecppack`, `icepack`, `OpenSTA`, `openFPGALoader`, and physical FPGA hardware.

---

## 3. Evaluated RTL Top Modules

| Top Module | Scope | Source Location |
| :--- | :--- | :--- |
| `integrated_gemm_top` | Integrated extension top (burst interface + tiling + 3×3 systolic array + partial result buffer; 11 RTL files) | [`rtl/extensions/integrated_gemm_top.v`](../rtl/extensions/integrated_gemm_top.v) |
| `tiled_gemm_top` | Optional 3×3 / 6×6 tiled accelerator with single-word host interface (10 RTL files) | [`rtl/extensions/tiled_gemm_top.v`](../rtl/extensions/tiled_gemm_top.v) |
| `top_module` | Core Phase I 3×3 standalone systolic accelerator (10 RTL files) | [`rtl/core/top_module.v`](../rtl/core/top_module.v) |
| `sequential_gemm` | Single-MAC sequential comparison baseline (1 RTL file) | [`rtl/baseline/sequential_gemm.v`](../rtl/baseline/sequential_gemm.v) |

All evaluated RTL passed `synth_xilinx -family xc7` and `synth_ecp5` with **0 errors**, **0 inferred latches**, **0 unresolved modules**, and **0 multi-driver conflicts** without requiring RTL modifications.

---

## 4. Yosys Resource Utilization Results (`xc7`)

Source: [`reports/utilization_summary.txt`](reports/utilization_summary.txt).

### 4.1 Primary Integrated Extension (`integrated_gemm_top`, Flattened with I/O Buffers)

| Resource | Used | Available | Utilization (%) |
| :--- | ---: | :--- | :--- |
| Slice LUTs (`LUT1`–`LUT6`) | **12,919** | Unavailable (target part unspecified) | Unavailable |
| Estimated Logic Cells (Yosys) | **12,019** | Unavailable (target part unspecified) | Unavailable |
| Flip-Flops (`FDCE` + `FDPE`) | **2,549** (`2,546` + `3`) | Unavailable (target part unspecified) | Unavailable |
| DSP Blocks (`DSP48E1`) | **19** | Unavailable (target part unspecified) | Unavailable |
| Block RAM (`RAMB18E1` + `RAMB36E1`) | **0** | Unavailable (target part unspecified) | Unavailable |
| Carry Chains (`CARRY4`) | **234** | Unavailable (target part unspecified) | Unavailable |
| Wide Muxes (`MUXF7` + `MUXF8`) | **78** (`66` + `12`) | Unavailable (target part unspecified) | Unavailable |
| Clock Buffers (`BUFG`) / Inverters (`INV`) | **1** / **26** | Unavailable (target part unspecified) | Unavailable |
| Bonded I/O (`IBUF` + `OBUF`) | **120** (`71` + `49`) | Unavailable (target part unspecified) | Unavailable |

### 4.2 Hierarchical Submodule Attribution (`integrated_gemm_top`, `xc7 -noiopad`)

| Submodule | LUTs | LUT Share | FFs | `DSP48E1` | `CARRY4` | `MUXF7/8` |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| `partial_result_buffer` | **14,911** | **88.2%** | 1,186 | 5 | 149 | 96 |
| `tiled_input_buffer` | 1,405 | 8.3% | 792 | 4 | 40 | 51 |
| `systolic_array` (`9× PE` + `9× MAC` + `pe_interconnect`) | 288 | 1.7% | 432 | **9** | 0 | 0 |
| `burst_matrix_interface` | 253 | 1.5% | 163 | 0 | 21 | 0 |
| `matrix_tiling_controller` | 31 | 0.2% | 20 | 0 | 1 | 0 |
| `systolic_controller` + `control_fsm` | 21 | 0.1% | 9 | 0 | 0 | 0 |
| `integrated_gemm_top` (glue) | 5 | 0.0% | 0 | 0 | 0 | 0 |
| **Hierarchical Total (`-noiopad`)** | **16,914** | **100.0%** | **2,602** | **18** | **211** | **147** |
| **Flattened Total (`-flatten`, with I/O pads)** | **12,919** | — | **2,549** | **19** | **234** | **78** |

### 4.3 Cross-Architecture Comparison (`xc7 -flatten`)

| Top Module | Slice LUTs | Est. LCs | FFs | `DSP48E1` | BRAM | `CARRY4` | I/Os |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `sequential_gemm` (baseline) | 1,351 | 1,137 | 1,882 | 1 | 0 | 27 | 71 |
| `top_module` (core 3×3 systolic) | **1,145** | **1,055** | **1,026** | **9** | 0 | 16 | 63 |
| `tiled_gemm_top` (tiled extension) | 10,698 | 10,091 | 2,388 | 17 | 0 | 192 | 71 |
| `integrated_gemm_top` (integrated extension) | 12,919 | 12,019 | 2,549 | 19 | 0 | 234 | 120 |

Cross-check on Lattice ECP5 (`synth_ecp5 -top integrated_gemm_top`): **43,294 `LUT4`**, **2,549 `TRELLIS_FF`**, **29 `MULT18X18D`**, **0 `DP16KD`**, **806 `CCU2C`**, **14,572 `PFUMX`**, **5,541 `L6MUX21`**.

### 4.4 Resource Findings
1. **Core 3×3 Systolic Array is Compact:** `top_module` uses only **1,145 LUTs**, **1,026 FFs**, and **9 `DSP48E1`** (fewer LUTs and FFs than the `sequential_gemm` baseline, trading 8 additional DSPs for 9-way MAC parallelism).
2. **`partial_result_buffer` Dominates Extension Area (~88% LUTs):** Nine parallel dynamic-index read-modify-write loops (`g_idx = g_row * matrix_dim + g_col`) across 36 register-backed 32-bit accumulators synthesize into large 36:1 mux trees.
3. **10 Address-Arithmetic DSPs:** Beyond the 9 MAC DSPs, 10 extra `DSP48E1` slices are inferred from `integer * matrix_dim` linear index multiplications inside `partial_result_buffer` and `tiled_input_buffer`.
4. **Zero BRAM Inference:** Asynchronous `rst_n` `for`-loop resets across matrix memories map arrays to slice flip-flops rather than `RAMB18E1`/`RAMB36E1`, and keep `mac_unit` `DSP48E1` pipeline registers bypassed (`AREG=BREG=MREG=PREG=0`).

---

## 5. Timing Status and Pre-Placement Logic Depth

Source: [`reports/timing_and_path_analysis.txt`](reports/timing_and_path_analysis.txt).

- **Target Clock Period:** `10.0 ns` (`100.0 MHz` assumed simulation reference in [`docs/performance/performance_analysis.md`](../docs/performance/performance_analysis.md); **not** a verified FPGA clock constraint).
- **Achieved Clock Period / Critical Path Delay / Setup & Hold Slack / $F_{\max}$:** **Unavailable (NOT RUN — vendor STA and PnR unavailable; target part unspecified).**

| Top Module | Pre-Map RTL Path Depth (`ltp -noff`) | ABC9 Mapped LUT Depth (`lev`) | Dominant Structural Bottleneck |
| :--- | ---: | ---: | :--- |
| `integrated_gemm_top` | 38 stages | 14 LUTs | `partial_result_buffer` dynamic read-add-writeback mux chain |
| `tiled_gemm_top` | 38 stages | 13 LUTs | `partial_result_buffer` dynamic read-add-writeback mux chain |
| `top_module` | 12 stages | 7 LUTs | `input_buffer` skew mux → boundary PE `mac_unit` (`DSP48E1` + `LUT4`) |
| `sequential_gemm` | 12 stages | 10 LUTs | Dimension mask / readiness control; single-MAC `mem` mux → `DSP48E1` → `acc` |

Because post-implementation $F_{\max}$ is unavailable, FPGA wall-clock speedup over `sequential_gemm` is not claimed.

---

## 6. Reproducible FPGA Commands

```bash
# Open-source Yosys technology-mapped synthesis (outputs to build/fpga/)
make synth-fpga

# Print parsed resource utilization table
make fpga-utilization

# Print timing availability notice and structural logic-depth analysis
make fpga-path-analysis

# Vendor STA & bitstream checks (exit non-zero with NOT RUN diagnostic until Vivado/part/XDC are supplied)
make fpga-timing
make fpga-bitstream

# Refresh tracked summary reports in fpga/reports/
bash fpga/scripts/run_yosys_synth.sh --build-dir build/fpga --family xc7 --mode all --save-reports fpga/reports
```

A reference Vivado batch script for future use with a real FPGA part and official board `.xdc` is provided in [`scripts/vivado_impl_template.tcl`](scripts/vivado_impl_template.tcl).
