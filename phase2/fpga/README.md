# Phase II Task 5 — FPGA Implementation and Hardware Evaluation

## 1. Objective and Scope

This directory contains the reproducible FPGA evaluation deliverables for **Task 5: FPGA Implementation and Hardware Evaluation** of the Systolic Array Matrix Multiplication Accelerator project.

The evaluation bridges the gap between RTL functional simulation / structural elaboration (`synth-check*`) and device-mapped FPGA realization:

- **Technology-mapped FPGA synthesis** of the integrated Phase II top module (`phase2_top_module`) and comparative baseline architectures (`top_module`, `tiled_gemm_top`, and `sequential_gemm`) using **Yosys 0.71+post**.
- **Hierarchical and flattened FPGA resource attribution** across LUTs, flip-flops, DSP blocks, block RAM, carry chains, wide multiplexers, and I/O buffers.
- **Pre-placement structural critical-path analysis** (RTL topological path stages and ABC9 mapped LUT logic depth) and **static timing / Fmax feasibility assessment**.
- **Quantitative comparison** against Task 4 cycle-count and reference-clock performance metrics without conflating simulation assumptions with physical hardware measurements.
- **Reproducible automation** via root `Makefile` targets and scripts in [`phase2/fpga/scripts/`](scripts/).

> [!IMPORTANT]
> **Scope Boundaries Maintained Strictly:**
> 1. **Yosys structural checking (`make synth-check*`) is not FPGA synthesis**, and **Yosys pre-placement technology mapping (`make synth-fpga`) is not physical place-and-route or static timing closure**.
> 2. **No Phase I (`rtl/`, `testbench/`) or existing Phase II RTL/testbenches were modified.** All evaluated designs are unmodified repository RTL.
> 3. **No device part, board capacity, pinout, Fmax, timing slack, or physical hardware result is fabricated.** Unavailable post-implementation and hardware validation metrics are explicitly marked as **NOT RUN / UNAVAILABLE**.

---

## 2. Target FPGA Device and Board

Inspection of the repository (`README.md`, `phase2/README.md`, `phase2/*/README.md`, `Makefile`, and `report/report.pdf`) confirmed that **no target FPGA vendor, device family, part number, development board, speed grade, or pinout/clock constraint file is specified anywhere in the existing project**.

To adhere strictly to evidence-based hardware evaluation without inventing a target board or device capacity:

- **Target FPGA Part Number:** `UNSPECIFIED`
- **Target Development Board:** `UNSPECIFIED`
- **Official Board Constraints (`.xdc` / `.sdc` / `.pcf` / `.lpf`):** `UNSPECIFIED` (none present in repository; no synthetic pinout invented)
- **Evaluated Synthesis Architecture Family:** **Xilinx 7-Series (`xc7`)** via Yosys `synth_xilinx -family xc7` (chosen because Xilinx 7-Series primitives — 6-input LUTs, `FDCE`/`FDPE`, `CARRY4`, `MUXF7`/`MUXF8`, `DSP48E1`, `RAMB18E1`/`RAMB36E1` — provide clear architectural visibility into DSP inference, BRAM inference, and LUT mapping).
- **Cross-Architecture Validation Family:** **Lattice ECP5 (`ecp5`)** via Yosys `synth_ecp5` to verify that findings (0 BRAM inference, `partial_result_buffer` LUT dominance, and address-multiplier DSP inference) hold across FPGA architectures.

Because `FPGA_TARGET_PART` is unspecified, device-capacity totals and utilization percentages are reported as **Unavailable** in [`reports/utilization_summary.txt`](reports/utilization_summary.txt).

---

## 3. Toolchain and Environment Inventory

Checked on host `Darwin 27.2.0` (`arm64`, macOS):

| Tool / Component | Status | Version / Location | Role in Task 5 |
| :--- | :--- | :--- | :--- |
| **Yosys** | **Installed** | `Yosys 0.71+post` (`git sha1 5628c1324`, `/opt/homebrew/bin/yosys`) | Technology-mapped FPGA synthesis (`synth_xilinx`, `synth_ecp5`), `ltp` structural depth |
| **Yosys-ABC** | **Installed** | Bundled with Yosys 0.71 (`/opt/homebrew/bin/yosys-abc`) | K-LUT technology mapping (`ABC9`) |
| **Icarus Verilog / `vvp`** | **Installed** | `Icarus Verilog version 13.0 (stable)` (`/opt/homebrew/bin/iverilog`) | RTL simulation regression verification |
| **Python 3** | **Installed** | `python3` (`/Library/Frameworks/Python.framework/...`) | Deterministic synthesis/path report parsing |
| **Xilinx Vivado** | **Missing** | Not installed | Vendor synthesis, PnR, STA, power, bitstream (**NOT RUN**) |
| **Intel Quartus (`quartus_sh`, `quartus_sta`)** | **Missing** | Not installed | Intel synthesis, PnR, STA (**NOT RUN**) |
| **`nextpnr-*` (`xilinx`, `ecp5`, `ice40`, `himbaechel`, `generic`)** | **Missing** | Not installed | Open-source FPGA PnR & timing analysis (**NOT RUN**) |
| **`icetime` / `icepack` / `ecppack`** | **Missing** | Not installed | Lattice timing / bitstream packing (**NOT RUN**) |
| **`OpenSTA` / `OpenROAD` / `openFPGALoader`** | **Missing** | Not installed | Standalone STA / JTAG board programming (**NOT RUN**) |
| **Physical FPGA Board (USB / JTAG)** | **Unavailable** | None detected (`ioreg -p IOUSB` shows no FPGA/JTAG programmer) | Hardware validation (**NOT RUN**) |

---

## 4. RTL Top Module and Source Dependencies

### 4.1 Primary Integrated Top Module (`phase2_top_module`)

- **Module:** `phase2_top_module` ([`phase2/integration/phase2_top_module.v`](../integration/phase2_top_module.v))
- **Parameters (Default Verified Configuration):**
  - `ARRAY_SIZE = 3` (physical $3 \times 3$ systolic core)
  - `MAX_MATRIX_SIZE = 6` (supports $3 \times 3$ single-tile and $6 \times 6$ multi-tile)
  - `DATA_WIDTH = 8` (signed two's-complement matrix elements)
  - `ACC_WIDTH = 32` (signed two's-complement accumulators and result elements)
  - `WORDS_PER_BEAT = 4`, `BUS_DATA_WIDTH = 32`
  - `ADDR_WIDTH = 6`, `BURST_LEN_WIDTH = 7`
- **External I/O Footprint:** **120 signal pins** (**71 inputs**, **49 outputs**), matching the `71 IBUF + 49 OBUF` primitives mapped during flattened synthesis.

### 4.2 RTL Source Dependency Tree (`PHASE2_TOP_RTL`, 11 files)

| Layer | File | Module | Role |
| :--- | :--- | :--- | :--- |
| Compute (Phase I) | [`rtl/mac_unit.v`](../../rtl/mac_unit.v) | `mac_unit` | 8×8 signed multiplier + 32-bit signed accumulator with async `rst_n` and sync `clr` |
| Compute (Phase I) | [`rtl/processing_element.v`](../../rtl/processing_element.v) | `processing_element` | Registered eastward `a_out` / southward `b_out` + `mac_unit` |
| Compute (Phase I) | [`rtl/pe_interconnect.v`](../../rtl/pe_interconnect.v) | `pe_interconnect` | Structural 2D mesh links (0 registers, 0 logic) |
| Compute (Phase I) | [`rtl/systolic_array.v`](../../rtl/systolic_array.v) | `systolic_array` | $3 \times 3$ PE array + interconnect |
| Control (Phase I) | [`rtl/control_fsm.v`](../../rtl/control_fsm.v) | `control_fsm` | 4-state tile FSM (`IDLE`, `LOAD`, `COMPUTE`, `DONE`) |
| Control (Phase I) | [`rtl/systolic_controller.v`](../../rtl/systolic_controller.v) | `systolic_controller` | Single-tile cycle counters and strobes (`4N-1 = 11` cycles) |
| Scalability (Phase II) | [`phase2/scalability/tiled_input_buffer.v`](../scalability/tiled_input_buffer.v) | `tiled_input_buffer` | Dual $6 \times 6$ operand storage, write masks, tile staging, combinational skew |
| Scalability (Phase II) | [`phase2/scalability/matrix_tiling_controller.v`](../scalability/matrix_tiling_controller.v) | `matrix_tiling_controller` | $(i, j, k)$ tile sequencing and capture/accumulate orchestration |
| Scalability (Phase II) | [`phase2/scalability/partial_result_buffer.v`](../scalability/partial_result_buffer.v) | `partial_result_buffer` | 36×32-bit result storage + 9-way parallel inter-tile accumulation |
| Interface (Phase II) | [`phase2/interface/burst_matrix_interface.v`](../interface/burst_matrix_interface.v) | `burst_matrix_interface` | Streaming/packed-32b burst write engine, start lockout, 2-stage readback skid buffer |
| Integration (Phase II) | [`phase2/integration/phase2_top_module.v`](../integration/phase2_top_module.v) | `phase2_top_module` | Integrated top module |

### 4.3 Comparative Architectures Evaluated

- **`top_module`** ([`rtl/top_module.v`](../../rtl/top_module.v), 10 files in `TOP_RTL`): Phase I fixed $3 \times 3$ standalone systolic accelerator.
- **`tiled_gemm_top`** ([`phase2/scalability/tiled_gemm_top.v`](../scalability/tiled_gemm_top.v), 10 files in `TILED_RTL`): Phase II tiled $3 \times 3$ / $6 \times 6$ accelerator with single-element host interface.
- **`sequential_gemm`** ([`phase2/baseline/sequential_gemm.v`](../baseline/sequential_gemm.v), 1 file in `BASELINE_RTL`): Single-MAC sequential baseline supporting $3 \times 3$ and $6 \times 6$.

### 4.4 RTL Synthesizability Audit

Across all four designs under both structural elaboration (`hierarchy -check; proc; check`) and technology-mapped synthesis (`synth_xilinx -family xc7`, `synth_ecp5`):

- **Simulation-only constructs:** None (`initial` blocks, `#` delays, `$display`/`$fatal`, or non-synthesizable tasks are absent from all RTL files).
- **Inferred latches:** **0** (all combinational `always @(*)` blocks assign complete defaults).
- **Multiple drivers / combinational loops:** **0** (`Found and reported 0 problems.` in all Yosys runs).
- **Unresolved modules:** **0**.
- **Warnings observed:** Strictly 3 unique memory-to-register replacement messages per design (`Replacing memory \mem_a / \mem_b / \c_mem / \result_mem with list of registers`) caused by `for`-loop asynchronous resets (`always @(posedge clk or negedge rst_n)`). Note: during `ABC9` execution inside `synth_xilinx`, ABC emits an internal combinational-box sequential-sweep log message (`ABC: Error: Abc_FrameUpdateGia(): Transformation has failed.`) and proceeds cleanly with standard `ABC: Mapping (K=6/8)` LUT mapping (`exit 0`, `0 problems`).
- **RTL modifications required:** **None.** Existing RTL is 100% synthesizable as-is.

---

## 5. Synthesis and Implementation Procedure

1. **Structural Elaboration (`make synth-check*`):** Validates Verilog-2012/2005 parsing, parameter elaboration, process lowering, and DRC (`check`).
2. **Open-Source Technology-Mapped Synthesis (`make synth-fpga` -> [`scripts/run_yosys_synth.sh`](scripts/run_yosys_synth.sh)):**
   - Runs `synth_xilinx -family xc7 -top phase2_top_module -noiopad` for **hierarchical per-submodule resource attribution**.
   - Runs `synth_xilinx -family xc7 -top phase2_top_module -flatten` for **global cross-boundary optimization, I/O buffer insertion (`IBUF`/`OBUF`), JSON netlist, and post-synthesis gate Verilog**.
   - Runs flattened `synth_xilinx -family xc7` identically on `top_module`, `tiled_gemm_top`, and `sequential_gemm`.
   - Runs `synth_xilinx -family xc7 -top mac_unit -noiopad` + `dump t:DSP48E1` to inspect internal DSP register usage.
   - Runs `synth_ecp5 -top phase2_top_module` to cross-validate resource trends on Lattice ECP5.
3. **Structural Depth Extraction (`make fpga-path-analysis`):**
   - Runs pre-techmap `hierarchy -check -top <top>; proc; flatten; opt; check; ltp -noff` to trace exact RTL longest topological paths without library-FF false loop artifacts, and extracts post-mapping `ABC9` LUT logic depths (`lev`, `levB`).
4. **Vendor PnR, STA & Bitstream (`make fpga-timing`, `make fpga-bitstream`):**
   - Guarded by [`scripts/check_fpga_env.sh`](scripts/check_fpga_env.sh). Because Vivado/Quartus/`nextpnr` and target device/constraints are absent, both targets explicitly fail with `STATUS: NOT RUN`.
   - A ready-to-use non-project Vivado batch template is provided in [`scripts/vivado_impl_template.tcl`](scripts/vivado_impl_template.tcl) for execution when Vivado, an FPGA part, and an official board `.xdc` are supplied.

---

## 6. Resource Utilization Results

### 6.1 Primary Integrated Top Module (`phase2_top_module`, Xilinx `xc7`, Flattened with I/O Buffers)

Source: [`reports/utilization_summary.txt`](reports/utilization_summary.txt).

| Resource | Used | Available | Utilization (%) |
| :--- | ---: | :--- | :--- |
| **Slice LUTs (`LUT1`–`LUT6`)** | **13,448** | Unavailable (target FPGA part unspecified) | Unavailable |
| ↳ Breakdown (`LUT1` / `LUT2` / `LUT3`) | 12 / 1,001 / 2,785 | — | — |
| ↳ Breakdown (`LUT4` / `LUT5` / `LUT6`) | 1,359 / 4,708 / 3,583 | — | — |
| **Estimated Logic Cells (Yosys)** | **12,435** | Unavailable (target FPGA part unspecified) | Unavailable |
| **Flip-Flops / Registers (`FDCE` + `FDPE`)** | **2,549** (`2,546` + `3`) | Unavailable (target FPGA part unspecified) | Unavailable |
| **DSP Blocks (`DSP48E1`)** | **19** | Unavailable (target FPGA part unspecified) | Unavailable |
| **Block RAM (`RAMB18E1` + `RAMB36E1`)** | **0** | Unavailable (target FPGA part unspecified) | Unavailable |
| **Carry Chains (`CARRY4`)** | **234** | Unavailable (target FPGA part unspecified) | Unavailable |
| **Wide Multiplexers (`MUXF7` + `MUXF8`)** | **121** (`99` + `22`) | Unavailable (target FPGA part unspecified) | Unavailable |
| **Clock Buffers (`BUFG`)** | **1** | Unavailable (target FPGA part unspecified) | Unavailable |
| **Inverters (`INV`)** | **26** | Unavailable (target FPGA part unspecified) | Unavailable |
| **Bonded I/O Buffers (`IBUF` + `OBUF`)** | **120** (`71` + `49`) | Unavailable (target FPGA part unspecified) | Unavailable |

### 6.2 Hierarchical Resource Attribution (`phase2_top_module`, Xilinx `xc7`, `-noiopad`)

| Submodule | LUTs | LUT Share | FFs | `DSP48E1` | `CARRY4` | `MUXF7`/`MUXF8` |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| `partial_result_buffer` | **14,911** | **88.2%** | **1,186** | 5 | 149 | 96 |
| `tiled_input_buffer` | 1,405 | 8.3% | 792 | 4 | 40 | 51 |
| `systolic_array` (`9× PE` + `9× MAC` + interconnect) | 288 | 1.7% | 432 | **9** | 0 | 0 |
| ↳ `mac_unit` (×9) | 288 | 1.7% | 288 | 9 | 0 | 0 |
| ↳ `processing_element` registers (×9) | 0 | 0.0% | 144 | 0 | 0 | 0 |
| ↳ `pe_interconnect` | 0 | 0.0% | 0 | 0 | 0 | 0 |
| `burst_matrix_interface` | 254 | 1.5% | 163 | 0 | 21 | 0 |
| `matrix_tiling_controller` | 31 | 0.2% | 20 | 0 | 1 | 0 |
| `systolic_controller` + `control_fsm` | 21 | 0.1% | 9 | 0 | 0 | 0 |
| `phase2_top_module` (top glue) | 5 | 0.0% | 0 | 0 | 0 | 0 |
| **Hierarchical Total (`-noiopad`)** | **16,915** | **100.0%** | **2,602** | **18** | **211** | **147** |
| **Flattened Total (`-flatten`, with I/O pads)** | **13,448** | — | **2,549** | **19** | **234** | **121** |

> [!NOTE]
> Flattening across module boundaries propagates the constrained values of `active_matrix_dim` (`0`, `3`, or `6`), reducing total LUTs by **20.5%** (`16,915 -> 13,448`) and eliminating 53 redundant flip-flops (`2,602 -> 2,549`).

### 6.3 Cross-Architecture Comparison (Xilinx `xc7` Flattened & Lattice ECP5)

| Architecture (`-flatten`, `xc7`) | Slice LUTs | Est. LCs | Flip-Flops | `DSP48E1` | BRAM | `CARRY4` | I/O Pins |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `sequential_gemm` (1-MAC baseline) | 1,334 | 1,121 | 1,882 | 1 | 0 | 27 | 71 |
| `top_module` (Phase I 3×3 standalone) | 1,145 | 1,055 | 1,026 | 9 | 0 | 16 | 63 |
| `tiled_gemm_top` (Phase II 3×3/6×6 tiled) | 10,702 | 10,068 | 2,388 | 17 | 0 | 192 | 71 |
| `phase2_top_module` (Phase II integrated) | **13,448** | **12,435** | **2,549** | **19** | **0** | **234** | **120** |

Cross-architecture check (`synth_ecp5 -top phase2_top_module`): **46,155 `LUT4`**, **2,549 `TRELLIS_FF`**, **29 `MULT18X18D`**, **0 `DP16KD` (BRAM)**, **806 `CCU2C`**, **16,057 `PFUMX`**, **6,196 `L6MUX21`**.

### 6.4 Key Resource Attribution Findings

1. **`partial_result_buffer` Dominates Logic (~88% of Hierarchical LUTs):**
   In `phase2/scalability/partial_result_buffer.v` (lines 82–101), `capture_en` executes a $3 \times 3$ nested loop that computes 9 dynamic element addresses (`g_idx = (g_row * matrix_dim) + g_col`) in parallel and reads/writes/accumulates across 36 register-backed 32-bit storage words (`c_mem[0:35]`, 1,152 bits). Because `c_mem` is lowered to individual flip-flops, 9 parallel dynamic read-modify-write ports synthesize into massive 36-to-1 multiplexer trees and per-register write-priority mux chains (**14,911 LUTs** hierarchically; ~10× larger than the entire Phase I `top_module`).
2. **10 Extra `DSP48E1` Blocks Inferred for Buffer Address Arithmetic:**
   Only **9** `DSP48E1` slices come from the 9 systolic PE `mac_unit`s. The remaining **10** `DSP48E1` blocks in flattened `phase2_top_module` come from 32-bit `integer * matrix_dim` linear index multiplications inside `partial_result_buffer.v:87` (`g_row * matrix_dim`) and `tiled_input_buffer.v:129` (`g_row_a * matrix_dim`), where each 32×4 multiplication maps across two cascaded `DSP48E1` slices (`sliceA[0]` + `sliceA.last`). Because `matrix_dim` is strictly `3` or `6`, a future optimization using shift-add (`x*3 = (x<<1)+x`, `x*6 = (x<<2)+(x<<1)`) or tile-block addressing would eliminate all 10 address DSPs.
3. **Zero Block RAM Inference (`0 RAMB18E1 / 0 RAMB36E1`) & Unpipelined `DSP48E1` Mode:**
   - All storage arrays (`mem_a`, `mem_b`, `c_mem`, `result_mem`) include `for`-loop resets inside `always @(posedge clk or negedge rst_n)`, preventing Block RAM or LUTRAM inference and forcing **2,549 flip-flops** (`FDCE`).
   - Standalone `mac_unit` inspection (`build/fpga/mac_unit_dsp_dump.txt`) confirms that the asynchronous reset on `acc` (`always @(posedge clk or negedge rst_n)`) forces `DSP48E1` into pure combinational mode (`AREG=0, BREG=0, CREG=0, MREG=0, PREG=0`), leaving the 32-bit accumulator register in external fabric `FDCE` flip-flops with `32× LUT4` clear/enable gating (`288 LUT4 + 288 FDCE` across 9 MACs).
4. **Burst Interface & Tiling Control Overhead is Modest:**
   `burst_matrix_interface` (254 LUTs, 163 FFs — including the 32-bit packed holding register and two 32-bit readback skid-buffer registers), `matrix_tiling_controller` (31 LUTs, 20 FFs), and `systolic_controller` + `control_fsm` (21 LUTs, 9 FFs) together represent **< 2%** of total LUT area.

---

## 7. Timing Analysis and Maximum Operating Frequency

### 7.1 Post-Implementation Timing Metrics

| Timing Metric | Value | Status / Notes |
| :--- | :--- | :--- |
| **Target Clock Period** | `10.0 ns` (`100.0 MHz`) | Assumed reference from Task 2/Task 4 only — **NOT a closed FPGA constraint** |
| **Achieved Clock Period** | **Unavailable** | **NOT RUN** (no Vivado, Quartus, or `nextpnr` timing engine installed) |
| **Critical Path Delay ($T_{\text{critical}}$)** | **Unavailable** | **NOT RUN** (requires device speed grade and routed interconnect delays) |
| **Setup Slack** | **Unavailable** | **NOT RUN** |
| **Hold Slack** | **Unavailable** | **NOT RUN** |
| **Maximum Operating Frequency ($F_{\max}$)** | **Unavailable** | Cannot compute $F_{\max} = 1 / T_{\text{critical}}$ without valid post-PnR STA |

> [!WARNING]
> **Explicit Timing Policy:** The 100.0 MHz reference clock used in Task 2 and Task 4 throughput calculations is strictly an analytical simulation baseline and is **not** a measured FPGA frequency. Likewise, Yosys ABC9 internal delay numbers are pre-placement heuristics with zero routing delay and are **never** converted into a claimed $F_{\max}$ or timing-closure metric.

### 7.2 Pre-Placement Structural Logic Depth

Source: [`reports/timing_and_path_analysis.txt`](reports/timing_and_path_analysis.txt).

| Top Module | Pre-Map RTL Path Depth (`ltp -noff`, stages) | ABC9 Mapped LUT Depth (`lev`) | ABC9 Max-Cut Depth (`levB`) | Dominant Structural Path Category |
| :--- | ---: | ---: | ---: | :--- |
| `phase2_top_module` | **38** | **15** | 26 | Buffer / inter-tile accumulation mux & writeback (`partial_result_buffer`) |
| `tiled_gemm_top` | **38** | **13** | 27 | Buffer / inter-tile accumulation mux & writeback (`partial_result_buffer`) |
| `top_module` | **12** | **7** | 10 | Buffer skew mux (`input_buffer`) → boundary PE `mac_unit` (`DSP48E1` + `LUT4`) |
| `sequential_gemm` | **12** | **8** | 20 | Dimension mask / readiness control; single-MAC `mem` mux → `DSP48E1` → `acc` |

---

## 8. Critical-Path Discussion

Tracing the Yosys `ltp -noff` topological graphs reveals distinct critical-path mechanisms across the architectures:

1. **`phase2_top_module` and `tiled_gemm_top` — Inter-Tile Accumulation Buffer Logic (38 RTL stages, 15 / 13 mapped LUT levels):**
   - **Endpoint:** `\u_partial_buffer.c_mem[27][31]` (`phase2_top_module`) / `\u_partial_buffer.c_mem[30][31]` (`tiled_gemm_top`).
   - **Mechanism:** `cfg_matrix_dim` feeds `active_matrix_dim` into `partial_result_buffer`, where `g_idx = (g_row * matrix_dim) + g_col` drives a 36-entry dynamic read multiplexer (`c_mem[g_idx]`), a 32-bit signed adder (`c_mem[g_idx] + elem_in`), and a deep cascaded priority writeback mux chain (`$procmux`) across all 9 parallel `(r, c)` loop updates into `c_mem`.
   - **Category:** **Buffer / inter-tile accumulation and controller-configured address/mux logic** — NOT the systolic PE interconnect or MAC core.
2. **`top_module` (and secondary compute path in `phase2_top_module`) — Skewed Buffer + MAC Datapath (12 RTL stages, 7 mapped LUT levels):**
   - **Endpoint:** `\u_array.gen_row[0].gen_col[2].u_pe.u_mac.acc[31]`.
   - **Mechanism:** `systolic_controller` (`cycle_count`) → `input_buffer` combinational skew index calculation (`cycle_count - col_j`) and dynamic `staged_b` byte selection → boundary PE `mac_unit` combinational 8×8 signed multiplier + 32-bit accumulator adder (`DSP48E1` with `AREG=MREG=PREG=0`) → clear/enable `LUT4` → `acc` flip-flop.
   - **PE Interconnect Isolation:** Because `processing_element` registers both `a_out` and `b_out`, interior PE-to-PE links in `pe_interconnect` are strictly register-to-register (`FF -> DSP48E1 -> FF`) and do **not** chain across multiple PEs in a single clock cycle. Only row-0 / col-0 boundary PEs see the `input_buffer` skew mux in series with the MAC.
3. **`sequential_gemm` — Readiness Mask Control & Single-MAC Loop (12 RTL stages, 8 mapped LUT levels):**
   - **Endpoint:** `\host_result_available` (alongside the single-MAC datapath `mem_a[addr_a]`/`mem_b[addr_b]` 36:1 read mux → `DSP48E1` multiply → 32-bit add → `acc_reg` / `mem_c`).
   - Although `sequential_gemm` uses 10× fewer LUTs than `phase2_top_module`, its 36-element register arrays still require 36:1 dynamic read muxes in series with its single multiplier/adder, whereas `phase2_top_module` incurs an extra 3× deeper mux cascade in `partial_result_buffer`.

---

## 9. Comparison with Task 4 Performance Results

The cycle counts established in Task 4 ([`phase2/performance/README.md`](../performance/README.md), [`phase2/baseline/README.md`](../baseline/README.md)) remain exact and unmodified:

| Architecture | Matrix | Compute Cycles | End-to-End Cycles |
| :--- | ---: | ---: | ---: |
| Sequential baseline | 3×3 | 27 | 56 |
| Standalone systolic | 3×3 | 11 | 40 |
| Tiled systolic | 3×3 | 15 | 44 |
| Sequential baseline | 6×6 | 216 | 326 |
| Tiled systolic | 6×6 | 113 | 223 |

Separating the five evaluation tiers strictly:

| Tier | Metric Source | Status in Task 5 | Observations |
| :--- | :--- | :--- | :--- |
| **1. Simulation cycle counts** | Icarus Verilog (`tb_performance.v`, `tb_sequential_gemm.v`) | **PASS** (preserved verbatim) | Tiled 6×6 cuts compute cycles by **1.9115×** (`216 -> 113`) and E2E cycles by **1.4619×** (`326 -> 223`); Phase II burst interface further accelerates host I/O via 32-bit packed bursts. |
| **2. Assumed reference-clock throughput** | Task 4 formula at `100.0 MHz` nominal clock | **Analytical Only** | Sequential 6×6: `100.00 MMAC/s` comp / `66.26 MMAC/s` E2E; Tiled 6×6: `191.15 MMAC/s` comp / `96.86 MMAC/s` E2E. Assumes identical `100 MHz` clock across designs. |
| **3. Post-synthesis FPGA resources** | Yosys `synth_xilinx -family xc7` (measured) | **PASS** | `phase2_top_module` requires **10.08× more LUTs** (`13,448` vs `1,334`) and **19× more DSP48E1** (`19` vs `1`) than `sequential_gemm`, primarily from `partial_result_buffer` rather than the 9-PE systolic core (`288` LUTs, `9` DSPs). |
| **4. Post-implementation FPGA timing ($F_{\max}$)** | Vendor PnR + STA | **NOT RUN** | Real wall-clock throughput ($\text{MACs/cycle} \times F_{\max}$) **cannot** be calculated yet. Crucially, `phase2_top_module`'s 38-stage `partial_result_buffer` combinational path (15 mapped LUT levels vs 8 in `sequential_gemm`) creates a risk of a **lower $F_{\max}$** than `sequential_gemm` unless pipelined/refactored—meaning FPGA wall-clock speedup over `sequential_gemm` **cannot be claimed** until post-implementation STA is measured. |
| **5. Physical hardware measurements** | On-board FPGA execution & I/O capture | **NOT RUN** | No board or programmer available. |

---

## 10. Hardware Validation Status, Limitations, and Remaining Work

### 10.1 Physical Hardware Validation

- **Status:** **NOT RUN**
- **Reason:** No physical FPGA development board is attached to the host, no target device part or board pinout exists in the repository, and no bitstream-capable PnR vendor toolchain (Vivado, Quartus, or `nextpnr` + bitstream packer) is installed in this macOS ARM64 environment. Simulation results are explicitly **not** substituted for hardware execution.

### 10.2 Limitations and Remaining Work

1. **Missing Target Platform Definition:** Select an actual target FPGA part and development board (e.g., Xilinx Artix-7 / Zynq-7000 or Lattice ECP5) and obtain its official board master constraint file (`.xdc` / `.lpf`).
2. **Missing Post-Implementation PnR, STA, and Power:** Run [`scripts/vivado_impl_template.tcl`](scripts/vivado_impl_template.tcl) (or equivalent Quartus/`nextpnr` flow) on a workstation with Vivado/Quartus/`nextpnr` to measure true $T_{\text{critical}}$, setup/hold slack, $F_{\max}$, device utilization percentages, and estimated power.
3. **Architecture Optimization Opportunities Exposed by Task 5 Synthesis (Future Work):**
   - Refactor `partial_result_buffer` to replace the 9-way parallel dynamic-addressed `c_mem` update with tile-indexed / shift-add addressing and pipelined read-modify-write, eliminating ~13k LUTs, 5 address DSPs, and the 38-stage combinational path.
   - Replace `matrix_dim * g_row` multiplies in `tiled_input_buffer` and `partial_result_buffer` with shift-add/mux logic for `dim ∈ {3, 6}` to remove all 10 non-MAC `DSP48E1` inferences.
   - Consider synchronous reset or unreset memory arrays (where protocol-safe) so `mem_a`, `mem_b`, and `c_mem` can infer LUTRAM/BRAM and `mac_unit` can absorb `MREG`/`PREG` inside `DSP48E1`.
4. **On-Board Hardware Validation Checklist (Pending Board Availability):**
   - Program generated bitstream onto physical FPGA.
   - Verify active-low reset behavior and idle readiness flags.
   - Exercise burst streaming and packed-32b host transfers over physical host bridge (UART/AXI/JTAG).
   - Execute $3 \times 3$ and $6 \times 6$ GEMMs with both positive and mixed-sign boundary operands (`-128`, `+127`) and compare against software reference outputs with captured hardware logs.

---

## 11. Exact Reproduction Commands

All commands run from the repository root:

```bash
# 1. Existing functional regression & demonstration suites
make clean
make test-baseline
make test-phase2
make test
make demo

# 2. Existing Yosys structural elaboration checks
make synth-check
make synth-check-tiled
make synth-check-phase2-top
make synth-check-baseline

# 3. Task 5 open-source technology-mapped FPGA synthesis & analysis
make synth-fpga
make fpga-utilization
make fpga-path-analysis

# 4. Regenerate tracked text reports under phase2/fpga/reports/ (optional)
bash phase2/fpga/scripts/run_yosys_synth.sh --build-dir build/fpga --family xc7 --mode all --save-reports phase2/fpga/reports

# 5. Vendor STA & bitstream targets (currently exit non-zero with explicit NOT RUN diagnostics)
make fpga-timing
make fpga-bitstream

# 6. Future Vivado execution (when Vivado, part number, and official board XDC are available)
make fpga-bitstream FPGA_TARGET_PART=<part> FPGA_CONSTRAINTS=<path/to/official_board.xdc>
```
