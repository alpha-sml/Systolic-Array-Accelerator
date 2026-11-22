# FPGA Evaluation Results Summary

## Evaluation Status Matrix

| Stage | Target / Scope | Status | Summary |
| :--- | :--- | :--- | :--- |
| RTL Structural Checks (`make synth-check*`) | `top_module`, `tiled_gemm_top`, `integrated_gemm_top`, `sequential_gemm` | **PASS** | 0 latches, 0 multi-drivers, 0 combinational loops, 0 unresolved modules |
| Yosys Technology-Mapped Synthesis (`make synth-fpga`) | Xilinx `xc7` & Lattice `ecp5` | **PASS** | Clean primitive mapping without modifying any RTL |
| Vendor FPGA Synthesis | Vivado / Quartus | **NOT RUN** | Vendor tools missing; target part unspecified |
| Place-and-Route & Bitstream (`make fpga-bitstream`) | Physical device implementation | **NOT RUN** | PnR tools, target part, and board pinout constraints missing |
| Static Timing Analysis & $F_{\max}$ (`make fpga-timing`) | Post-PnR timing closure | **NOT RUN** | No STA engine installed; target speed grade unspecified |
| Physical Hardware Validation | On-board 3×3 & 6×6 tests | **NOT RUN** | No FPGA development board attached |

---

## Key Resource & Logic-Depth Summary (`synth_xilinx -family xc7`, Flattened)

| Architecture | Slice LUTs | Est. LCs | FFs | `DSP48E1` | BRAM | `CARRY4` | RTL LTP | ABC9 LUT `lev` |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `sequential_gemm` (baseline) | 1,351 | 1,137 | 1,882 | 1 | 0 | 27 | 12 | 10 |
| `top_module` (core 3×3) | **1,145** | **1,055** | **1,026** | **9** | 0 | 16 | 12 | 7 |
| `tiled_gemm_top` (tiled ext.) | 10,698 | 10,091 | 2,388 | 17 | 0 | 192 | 38 | 13 |
| `integrated_gemm_top` (integrated ext.) | 12,919 | 12,019 | 2,549 | 19 | 0 | 234 | 38 | 14 |

- **Device Utilization (%):** Unavailable (target FPGA part and capacity are unspecified).
- **Achieved Clock / $F_{\max}$:** Unavailable (no vendor STA performed; 100.0 MHz in performance analysis is an assumed reference clock only).
- **Key Observation:** The core 3×3 systolic array (`top_module`) is compact (`1,145` LUTs, `9` `DSP48E1`), whereas `partial_result_buffer` contributes `88.2%` of hierarchical LUTs in `integrated_gemm_top` (`14,911` LUTs) and the 10 additional `DSP48E1` slices (`19` total vs. `9` MAC DSPs) are likely inferred from `integer * matrix_dim` index arithmetic in `partial_result_buffer` and `tiled_input_buffer` (an inferred explanation rather than a confirmed attribution).

See [`README.md`](README.md) for methodology details and [`reports/`](reports/) for raw parsed summary files.
