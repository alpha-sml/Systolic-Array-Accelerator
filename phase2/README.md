# Phase II — Systolic Array Matrix Multiplication Accelerator

## 1. Project Overview

Phase I delivered a parameterized, synthesizable Verilog HDL implementation of an output-stationary systolic array matrix multiplication accelerator (`rtl/`), verified through six self-checking Icarus Verilog testbenches (`testbench/`) and structural elaboration in Yosys.

The verified Phase I baseline comprises ten RTL modules:
- **Compute core:** `mac_unit`, `processing_element`, `pe_interconnect`, `systolic_array`
- **Control path:** `control_fsm`, `systolic_controller`
- **Data-management path:** `input_buffer`, `output_buffer`, `matrix_interface`
- **Integration:** `top_module`

For the default $3 \times 3$ configuration with 8-bit signed two's-complement operands and 32-bit signed accumulators:
- Controller residency is $T_{\text{ctrl}} = 4N - 1 = 11$ cycles ($N = 3$ LOAD, $3N - 2 = 7$ COMPUTE, $1$ DONE).
- Element-wise host transport requires $2N^2 = 18$ write beats and $N^2 = 9$ read beats, giving $T_{\text{op}} = 3N^2 + 4N - 1 = 38$ cycles (39 cycles at the host boundary due to the start-qualification register in `matrix_interface`).
- Host transport accounts for ~71% (27 of 38 cycles) of total operation time, while PE utilisation during COMPUTE is $\rho(N) = N / (3N - 2) \approx 42.9\%$.
- All Phase I regression suites (376 counted checks across five suites plus the 94-cycle cycle-accurate controller suite) and the Yosys structural check pass with zero failures and zero structural problems.

Phase I intentionally stopped at RTL simulation and non-technology-mapped structural checking. No FPGA implementation, device-specific synthesis, static timing analysis, resource/power measurement, sequential baseline comparison, tiling, or burst host interface was undertaken.

All Phase I RTL (`rtl/`), testbenches (`testbench/`), report (`report/report.pdf`), prototype demonstration (`testbench/tb_prototype_demo.v`), and `Makefile` targets remain preserved and unmodified in `phase2/` development.

---

## 2. Phase II Objectives

Phase II extends the verified Phase I architecture from a fixed-size, element-by-element simulated RTL core into a quantitatively evaluated, scalable, high-bandwidth, and FPGA-characterized accelerator:

1. **Scalability:** Support matrices larger than the physical $N \times N$ array via tiled execution, partial-result storage, and inter-tile accumulation.
2. **Datapath Efficiency:** Optimize the PE/MAC datapath and evaluate advanced arithmetic extensions (reduced precision and zero-skipping) while preserving signed arithmetic correctness.
3. **Host Bandwidth:** Eliminate the element-by-element host transport bottleneck through a burst/block-transfer (or DMA-style) interface, with double buffering as an architectural extension.
4. **Quantitative Evaluation:** Benchmark the systolic accelerator against a conventional sequential matrix multiplication baseline across latency, MAC throughput, and PE utilisation.
5. **Hardware Realization:** Perform technology-mapped FPGA synthesis, resource utilisation analysis, static timing analysis (STA), and hardware/power evaluation where tools and hardware permit.

### Core Phase II Evaluation Work vs. Optional Advanced Extensions

To keep Phase II focused and verifiable, work is separated into:

- **Core Phase II Evaluation Work:**
  - Tiled matrix multiplication, partial-result storage, and controller scheduling extensions (Task 1).
  - PE/MAC datapath optimization and boundary/signed arithmetic verification (Task 2).
  - Burst/block-transfer host interface, acknowledgement/error handling, and integrated system verification (Task 3).
  - Sequential baseline RTL/simulation implementation and analytical-vs-simulated performance comparison (Task 4).
  - Target FPGA selection, constraints, technology-mapped synthesis, LUT/FF/DSP/memory utilization, and static timing analysis (Task 5).

- **Optional Advanced Extensions:**
  - Reduced-precision arithmetic / packed lanes (Task 2).
  - Zero-skipping / sparse computation support (Task 2).
  - Direct-memory-access (DMA)-style transfers and double-buffered input banks to overlap host load with compute (Task 3).
  - Physical FPGA bitstream generation, on-board hardware verification, and power measurement, contingent on available hardware and vendor tool support (Task 5).

---

## 3. Phase II Technical Tasks

Phase II is organized into **exactly five** technical tasks mapped to topic-based directories under `phase2/`:

1. **Task 1 — Tiled Matrix Multiplication and Controller Extensions** (`phase2/scalability/`, `phase2/integration/`)
2. **Task 2 — PE/MAC Optimisation and Advanced Arithmetic** (`phase2/optimization/`, `phase2/integration/`)
3. **Task 3 — High-Bandwidth Host Interface and System Integration** (`phase2/interface/`, `phase2/integration/`)
4. **Task 4 — Baseline Comparison and Quantitative Performance Evaluation** (`phase2/baseline/`, `phase2/performance/`)
5. **Task 5 — FPGA Implementation and Hardware Evaluation** (`phase2/fpga/`)

---

## 4. Detailed Scope of Each Task

### Task 1 — Tiled Matrix Multiplication and Controller Extensions
- **Directory:** `phase2/scalability/` (integrated in `phase2/integration/`)
- **Report Basis:** Section VI-F.3 (Fixed array size, no tiling), Section VI-D.3 (Tiled projection of $(M/N)^3$ tile operations), Section VIII-C Priority 2.1 (Tiling and partial-result accumulation).
- **Core Scope:**
  - Extend the accelerator to multiply matrices larger than the physical $N \times N$ array (e.g., $M \times M$ or $M \times K \times P$ decomposed into $N \times N$ tiles).
  - Implement tile scheduling logic to sequence operand tile pairs $(A_{i,k}, B_{k,j})$ across $(M/N)^3$ tile operations.
  - Design partial-result storage to retain intermediate $N \times N$ accumulator tiles between successive $k$-reduction steps.
  - Implement accumulation across successive tile operations without losing precision or corrupting signed two's-complement results.
  - Extend the controller FSM/counters to coordinate multi-tile LOAD/COMPUTE/ACCUMULATE/DONE sequences while preserving single-tile Phase I behavior.
  - Verify multiplication of larger matrices (e.g., $6 \times 6$, $9 \times 9$, or $12 \times 12$) on the existing $3 \times 3$ physical array.

### Task 2 — PE/MAC Optimisation and Advanced Arithmetic
- **Directory:** `phase2/optimization/` (integrated in `phase2/integration/`)
- **Report Basis:** Section III-C & IV-C (MAC/PE design and accumulator headroom), Section VI-F.5 (No sparsity support), Section VI-F.6 (No overflow detection), Section VIII-C Priority 3.1 (Sparse computation and reduced precision).
- **Core Scope:**
  - Investigate and implement PE/MAC datapath optimisations (e.g., critical-path reduction, pipelining/DSP-friendly multiplier-accumulator structure, or parameterized accumulator width/overflow handling) while maintaining compatibility with the systolic array interface.
  - Preserve signed two's-complement arithmetic correctness across all four quadrants.
  - Verify arithmetic boundary conditions (minimum/maximum signed operands, zero/one/minus-one, sign extension, and accumulator headroom/wraparound).
  - Compare original Phase I PE/MAC datapath against optimised variants (cycle latency, critical path, and synthesis resource impact).
- **Optional Advanced Extensions:**
  - Investigate reduced-precision arithmetic (e.g., 4-bit / sub-8-bit or packed multi-lane MAC operations).
  - Investigate zero-skipping computation (operand zero-detection and clock/MAC-enable gating or sparse skip logic) and quantify workload-dependent trade-offs.

### Task 3 — High-Bandwidth Host Interface and System Integration
- **Directory:** `phase2/interface/`, `phase2/integration/`
- **Report Basis:** Section VI-D.2 & VI-F.2 (Host transport dominates at 71% of cycles for $N=3$), Section VI-F.7 (One outstanding operation), Section VIII-C Priority 1.2 (Improved block-transfer host interface) & Priority 2.2 (Double buffering).
- **Core Scope:**
  - Replace or augment the element-by-element host transfer mechanism with a burst or block-transfer interface (streaming multiple operands/results per transaction or wide-bus packing).
  - Define explicit acknowledgement, completion, backpressure, and error handling (rejecting invalid/out-of-range/busy accesses cleanly, preserving Phase I reset and start-edge lockout semantics).
  - Integrate the enhanced host interface with existing/extended input buffers, output buffers, controller, and systolic array in `phase2/integration/`.
  - Verify the complete integrated system end-to-end, ensuring all Phase I functional guarantees remain intact.
- **Optional Advanced Extensions:**
  - Investigate direct-memory-access (DMA)-style transfers where supported by the target platform/interface.
  - Investigate double buffering (two independently selectable input-buffer banks, write-inactive / read-active bank switching, and controller/host protocol coordination to overlap matrix loading with computation).

### Task 4 — Baseline Comparison and Quantitative Performance Evaluation
- **Directory:** `phase2/baseline/`, `phase2/performance/`
- **Report Basis:** Section VI-D (Analytical throughput $\Theta$, utilisation $\rho(N)$, latency $T_{\text{op}}$), Section VIII-C Priority 1.1 (Sequential baseline comparison).
- **Core Scope:**
  - Implement a conventional sequential matrix multiplication baseline in synthesizable RTL (and/or cycle-accurate reference) using equivalent matrix sizes and 8-bit signed / 32-bit signed operand widths.
  - Compare execution latency (total cycles, compute cycles, and host-transfer overhead) between the sequential baseline and the systolic accelerator (both Phase I and Phase II tiled/burst variants).
  - Calculate MAC throughput (MACs/cycle and ops/sec once $f_{\max}$ is available from Task 5) and PE utilisation across matrix sizes.
  - Compare closed-form analytical estimates ($4N-1$, $3N^2+4N-1$, $(M/N)^3(4N-1)$) against actual simulation cycle counts.
  - Produce quantitative performance tables, speedup metrics, and roofline/scaling graphs in `phase2/performance/`.
  - Coordinate resource and timing data with Task 5 so speedup and efficiency claims reflect comparable clock frequencies and hardware costs.

### Task 5 — FPGA Implementation and Hardware Evaluation
- **Directory:** `phase2/fpga/`
- **Report Basis:** Section I-D, Section VI-E (Yosys structural check is not technology-mapped synthesis), Section VI-F.1 & VI-F.9 (No physical implementation, no timing constraints/closure), Table VIII.
- **Core Scope:**
  - Select a target FPGA device or development board (e.g., Xilinx Artix-7 / Zynq-7000, Lattice iCE40/ECP5, or Intel Cyclone, depending on available toolchain such as Vivado, Yosys+nextpnr, or Quartus).
  - Prepare device-specific synthesis scripts, pinout/top-level wrappers (if needed), and timing constraints (SDC/XDC clock period and I/O constraints).
  - Perform technology-mapped synthesis on the Phase I baseline and Phase II integrated accelerator.
  - Evaluate LUT, flip-flop (FF), DSP block, and block RAM / distributed memory utilisation.
  - Perform static timing analysis (STA) and determine achievable maximum clock frequency ($f_{\max}$) and critical-path bottlenecks.
  - Document actual synthesis and timing results honestly, distinguishing post-synthesis estimates from post-place-and-route results.
- **Optional Advanced Extensions:**
  - Perform full place-and-route, bitstream generation, and on-board FPGA hardware verification if physical hardware and vendor tools are available.
  - Evaluate dynamic and static power consumption if supported by the selected toolchain and hardware.

---

## 5. Expected RTL Modules and Testbenches

> **Note:** Directory placeholders exist only to establish structure; no Phase II RTL files are created during setup. Below are the planned modules and testbenches per task.

| Task | Directory | Expected RTL / Scripts | Expected Testbenches / Verification |
| :--- | :--- | :--- | :--- |
| **Task 1** | `phase2/scalability/` | `tile_scheduler.v`, `partial_result_buffer.v`, `tiled_controller.v` | `tb_tile_scheduler.v`, `tb_tiled_gemm.v` (larger matrices e.g. $6\times 6$, $9\times 9$ on $3\times 3$ array) |
| **Task 2** | `phase2/optimization/` | `mac_unit_opt.v`, `processing_element_opt.v` (and optional `mac_zero_skip.v` / `mac_reduced_prec.v`) | `tb_mac_opt.v`, `tb_pe_opt.v` (signed boundary, wraparound, zero-skip, reduced-precision checks) |
| **Task 3** | `phase2/interface/`, `phase2/integration/` | `burst_matrix_interface.v`, `dma_adapter.v` (optional), `double_buffer_input.v` (optional), `phase2_top_module.v` | `tb_burst_interface.v`, `tb_double_buffer.v` (optional), `tb_phase2_top.v` (end-to-end integration & error/reset checks) |
| **Task 4** | `phase2/baseline/`, `phase2/performance/` | `sequential_gemm.v`, benchmark/analysis scripts (Makefile) | `tb_sequential_gemm.v`, cycle-count comparison logs, performance tables and documentation |
| **Task 5** | `phase2/fpga/` | Synthesis scripts (Vivado Tcl / Yosys+nextpnr), constraint files (`.xdc` / `.sdc`), FPGA top wrapper | Synthesis/STA/PnR reports, utilisation & $f_{\max}$ summaries, hardware test logs (if available) |

---

## 6. Expected Deliverables

1. **Task 1:** Synthesizable tiling/accumulation RTL, self-checking multi-tile testbenches, and verified cycle-count documentation for $M > N$ matrices.
2. **Task 2:** Optimised PE/MAC RTL (plus optional reduced-precision/zero-skipping variants), boundary verification logs, and comparative datapath analysis against Phase I `mac_unit`/`processing_element`.
3. **Task 3:** Burst/block-transfer host interface specification and RTL, integrated `phase2_top_module`, and full system-level regression passing all Phase I and Phase II checks.
4. **Task 4:** Verified sequential baseline RTL, simulation-vs-analytical cycle-count datasets, MAC throughput and PE utilisation metrics, and comparative performance tables/graphs.
5. **Task 5:** Target FPGA configuration, constraint files, technology-mapped synthesis and STA reports (LUT/FF/DSP/BRAM, $f_{\max}$), and hardware/power evaluation report (if supported).

---

## 7. Dependencies Between Tasks

The following technical dependencies govern Phase II execution:

1. **Baseline before final performance comparison:** The sequential baseline implementation (Task 4 — `phase2/baseline/`) must be completed and verified before final latency, throughput, and speedup comparisons (Task 4 — `phase2/performance/`).
2. **FPGA device selection before constraints and implementation:** The target FPGA device/board and toolchain must be selected (Task 5) before authoring device-specific timing constraints (`.xdc`/`.sdc`), synthesis scripts, or running implementation.
3. **Host-interface design before system integration:** The burst/block-transfer host protocol, signal handshakes, and error semantics (Task 3 — `phase2/interface/`) must be finalized before full system integration (Task 3 — `phase2/integration/`).
4. **Partial-result storage and accumulation before tiled execution:** Tiled matrix multiplication (Task 1) requires partial-result storage and an inter-tile accumulation path before multi-tile controller scheduling can be verified end-to-end.
5. **PE/MAC compatibility:** PE/MAC optimisations (Task 2) must preserve port and cycle-timing compatibility with `systolic_array` and `pe_interconnect` unless an explicit interface update is coordinated with Task 1 and Task 3.
6. **Double buffering after stable host interface and buffers:** Double-buffered input banks (Task 3 optional extension) must follow a stable burst host-interface and buffer design to avoid simultaneous bank-access hazards.
7. **Phase I preservation:** The integrated Phase II system (`phase2/integration/`) must retain all existing Phase I functional and protocol guarantees (signed arithmetic, reset behavior, start lockout, held-high suppression, and invalid-access rejection).
8. **Cross-task timing/resource coordination:** Final performance evaluation (Task 4) depends on $f_{\max}$ and resource utilisation figures from FPGA synthesis/STA (Task 5) to convert cycle counts into wall-clock latency and area-efficiency metrics.

---

## 8. Recommended Implementation Sequence

1. **Stage 1 — Foundations & Characterization (Parallel):**
   - **Task 4 (`baseline/`):** Implement and verify the sequential matrix multiplication baseline at $3 \times 3$ and larger target sizes ($M \times M$).
   - **Task 5 (`fpga/`):** Select target FPGA device/toolchain, author initial constraints, and run baseline synthesis/STA on the unmodified Phase I `top_module` to establish reference LUT/FF/DSP/$f_{\max}$ numbers.
   - **Task 2 (`optimization/`):** Prototype and verify PE/MAC datapath optimisations and arithmetic boundary tests in isolation.

2. **Stage 2 — Architectural Extensions (Parallel with Interface Freeze):**
   - **Task 3 (`interface/`):** Define and verify the burst/block-transfer host interface protocol.
   - **Task 1 (`scalability/`):** Design and verify partial-result storage, accumulation datapath, and tiled controller extensions.

3. **Stage 3 — System Integration & Optional Extensions:**
   - **Task 3 (`integration/`):** Integrate Phase II modules (tiled controller, partial-result buffer, optimised PE/MAC, burst host interface) into `phase2_top_module`.
   - Implement optional extensions (double buffering, zero-skipping, reduced precision) only after core integration passes regression.

4. **Stage 4 — Full Evaluation & Hardware Sign-Off:**
   - **Task 5 (`fpga/`):** Run technology-mapped synthesis, STA, and (if hardware is available) place-and-route / hardware verification on the integrated Phase II system.
   - **Task 4 (`performance/`):** Compile final analytical-vs-simulated cycle counts, wall-clock latency, throughput, PE utilisation, and resource/power tables and plots.

---

## 9. Coding Conventions

All Phase II RTL and testbenches must adhere to the Phase I Verilog conventions:
- **Language standard:** Synthesizable Verilog-2001/SystemVerilog-2012 subset compatible with `iverilog -g2012 -Wall` and Yosys.
- **Directives:** Every source file must begin with `` `timescale 1ns / 1ps `` and `` `default_nettype none ``, and restore `` `default_nettype wire `` at the end of the file.
- **Parameterization:** Pass parameters explicitly down the module hierarchy (`ARRAY_SIZE`, `DATA_WIDTH`, `ACC_WIDTH`). Compute derived widths locally with `$clog2(...)` clamped to a minimum of 1 bit.
- **Structural generation:** Use `genvar` loops and indexed part-selects (`vec[base +: WIDTH]`) for packed inter-module buses.
- **Reset and control:** Active-low asynchronous reset (`rst_n`), synchronous clear (`clr`) with priority over `en`, and explicit state encodings (`localparam` / `parameter`).
- **Naming:** Use descriptive technical module and signal names (`snake_case`). Do not use personal names or member identifiers in files, modules, or directories.

---

## 10. Simulation and Verification Requirements

- **Tools:** Icarus Verilog (`iverilog -g2012 -Wall`) with `vvp` for functional simulation, and `yosys` for structural/synthesis checking.
- **Self-checking testbenches:** Every new RTL module must have a dedicated, self-checking testbench that:
  - Uses a standard clock/reset generator and a `check` task tracking pass/fail counts with diagnostic messages.
  - Computes expected matrix products independently of the DUT (e.g., triple-loop reference in the testbench).
  - Terminates with a clear summary line and `$fatal` on any failure.
- **Mandatory coverage:**
  - Reset from idle and mid-operation states.
  - Signed arithmetic across all four sign quadrants and boundary values ($-2^{D-1}$, $2^{D-1}-1$, $0$, $\pm 1$).
  - Protocol edge cases: invalid/out-of-range addresses, busy-state rejections, held-high start suppression, and back-to-back operations.
  - Parameterization checks (verifying at least two array/matrix configurations where applicable).

---

## 11. Integration and Regression Requirements

- **Phase I Preservation:** Do not modify or delete any file in `rtl/`, `testbench/`, `report/`, or break existing `Makefile` targets (`test`, `demo`, `synth-check`, `clean`).
- **Phase I Regression:** Before and after any Phase II integration milestone, the full Phase I regression must pass:
  ```sh
  make test
  make synth-check
  ```
- **Phase II Isolation:** All Phase II RTL, testbenches, scripts, constraints, and reports must reside under `phase2/`. Any Phase II build targets (added later in `phase2/` or via separate targets) must direct generated artifacts to `build/` (already ignored in `.gitignore`) so no `.vvp`, `.vcd`, `.log`, or FPGA run artifacts are committed to Git.
