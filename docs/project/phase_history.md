# Project Development History (Phase I and Phase II)

This project was developed in two distinct stages and subsequently organized into a functional directory layout (`rtl/`, `testbench/`, `fpga/`, `docs/`, `report/`). This document preserves the historical boundary between Phase I and Phase II.

---

## Phase I — Core Systolic Array Implementation

Phase I fulfilled the foundational B.Tech Modern Computer Architecture (MCA) requirements by designing, verifying, and documenting a parameterized $N \times N$ output-stationary systolic array matrix multiplication accelerator (verified default: $3 \times 3$, 8-bit signed operands, 32-bit signed accumulators).

- **Scope:** Core compute array, finite-state controller, input/output buffers, host-facing matrix interface, six self-checking Icarus Verilog testbenches (376 counted checks + 94-cycle controller verification), interactive 3×3 prototype demo, analytical cycle/utilization derivations, and Yosys structural check (`make synth-check`).
- **Artifacts:**
  - Final Combined IEEE Report (Phase I + Phase II): [`report/report.pdf`](../../report/report.pdf) (originally authored as the Phase I IEEE report upon completion of the core 3×3 implementation and subsequently expanded into the final combined Phase I + Phase II report)
  - Presentation Video: [Watch Phase I Presentation](https://drive.google.com/file/d/1x2GeWZgQnMK2wWIYd1ib1YpxJbkEby2q/view?usp=sharing)
  - Current Source Locations: `rtl/core/`, `rtl/interface/`, `testbench/core/`, `testbench/interface/`

---

## Phase II — Extensions and Performance Evaluation

Phase II extended the verified Phase I RTL—without modifying any Phase I core logic or interfaces—to evaluate scalability, host transport bandwidth, sequential baseline speedup, and technology-mapped FPGA feasibility:

1. **Extension A — Tiled Matrix Multiplication:** Added `tiled_gemm_top` and supporting tiling/partial-result blocks (`rtl/extensions/`) to multiply $6 \times 6$ matrices across 8 sequential $3 \times 3$ tile passes on the unmodified Phase I array.
2. **Extension B — Advanced Burst Host Interface:** Added `burst_matrix_interface` and integrated `integrated_gemm_top` (originally `phase2_top_module` under `phase2/integration/`, now in `rtl/extensions/`) supporting streaming and 32-bit packed-word bursts with a 2-stage lossless readback skid buffer.
3. **Extension C — Sequential GEMM Baseline & Performance Evaluation:** Added single-MAC `sequential_gemm` (`rtl/baseline/`) and `tb_performance` (`testbench/extensions/`) to measure exact compute and end-to-end speedups across 3×3 and 6×6 matrices.
4. **FPGA Synthesis & Evaluation:** Added Yosys technology-mapped synthesis (`synth_xilinx -family xc7` and `synth_ecp5` cross-check), hierarchical resource attribution, structural logic-depth inspection, and environment guards (`fpga/`), clearly distinguishing synthesis estimates from unavailable vendor place-and-route, STA ($F_{\max}$), and hardware testing.

---

## Directory Reorganization Mapping

| Historical Location | Current Functional Location | Category |
| :--- | :--- | :--- |
| `rtl/{mac_unit,processing_element,pe_interconnect,systolic_array,control_fsm,systolic_controller,top_module}.v` | `rtl/core/` | Phase I Core |
| `rtl/{input_buffer,output_buffer,matrix_interface}.v` | `rtl/interface/` | Phase I Interface |
| `testbench/tb_{mac_unit,processing_element,systolic_array,systolic_controller,top_module,prototype_demo}.v` | `testbench/core/` | Phase I Core Verification |
| `testbench/tb_data_management.v` | `testbench/interface/` | Phase I Interface Verification |
| `phase2/scalability/*.v`, `phase2/interface/*.v` | `rtl/extensions/` | Phase II Optional Extensions |
| `phase2/integration/phase2_top_module.v` | `rtl/extensions/integrated_gemm_top.v` | Phase II Optional Extensions (renamed for functional clarity) |
| `phase2/baseline/sequential_gemm.v` | `rtl/baseline/` | Phase II Baseline Reference |
| `phase2/{scalability,interface,performance}/tb_*.v` | `testbench/extensions/` | Phase II Extension Verification |
| `phase2/integration/tb_phase2_top.v` | `testbench/extensions/tb_integrated_top.v` | Phase II Extension Verification (renamed for functional clarity) |
| `phase2/baseline/tb_sequential_gemm.v` | `testbench/baseline/` | Phase II Baseline Verification |
| `phase2/fpga/` | `fpga/` | Phase II FPGA Evaluation |
| `phase2/*/README.md` | `docs/{architecture,performance,project}/` | Consolidated Documentation |
