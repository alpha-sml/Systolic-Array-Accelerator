# Task 5 — FPGA Evaluation Results Summary

## Evaluation Status Matrix

| Stage | Target / Scope | Status | Summary |
| :--- | :--- | :--- | :--- |
| RTL Synthesizability & DRC | `phase2_top_module`, `tiled_gemm_top`, `top_module`, `sequential_gemm` | **PASS** | 0 latches, 0 multi-drivers, 0 combinational loops, 0 unresolved modules; 0 RTL edits needed |
| Technology-Mapped Synthesis | Yosys 0.71+post (`synth_xilinx -family xc7`, `synth_ecp5`) | **PASS** | Complete LUT, FF, `DSP48E1`, BRAM, `CARRY4`, `MUXF7/8`, I/O metrics generated |
| Resource Attribution | Hierarchical & flattened `phase2_top_module` | **PASS** | Flattened: **13,448 LUTs**, **2,549 FFs**, **19 DSP48E1**, **0 BRAM**, **234 CARRY4**, **120 IOs** |
| Pre-Placement Structural Depth | Yosys `ltp -noff` & ABC9 `lev` | **PASS** | `phase2_top_module`: 38 RTL stages / 15 mapped LUT levels (`top_module`: 12 / 7; `sequential_gemm`: 12 / 8) |
| Post-Implementation STA & $F_{\max}$ | Vivado / Quartus / `nextpnr` + constraints | **NOT RUN** | No STA/PnR tool installed; target FPGA part and constraints unspecified |
| Place & Route / Bitstream | Vendor or open-source PnR + packer | **NOT RUN** | No PnR/bitstream toolchain installed; target device and pinout unspecified |
| Physical Hardware Validation | On-board 3×3 & 6×6 GEMM tests | **NOT RUN** | No physical FPGA board or JTAG interface attached |

---

## Key Quantitative Findings (`synth_xilinx -family xc7`, Flattened)

| Architecture | Slice LUTs | Est. LCs | FFs | `DSP48E1` | BRAM | `CARRY4` | RTL LTP | ABC9 LUT `lev` |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `sequential_gemm` | 1,334 | 1,121 | 1,882 | 1 | 0 | 27 | 12 | 8 |
| `top_module` | 1,145 | 1,055 | 1,026 | 9 | 0 | 16 | 12 | 7 |
| `tiled_gemm_top` | 10,702 | 10,068 | 2,388 | 17 | 0 | 192 | 38 | 13 |
| `phase2_top_module` | **13,448** | **12,435** | **2,549** | **19** | **0** | **234** | **38** | **15** |

- **Device Utilization (%):** Unavailable (target FPGA part and capacity are unspecified in the repository).
- **Achieved Clock / $F_{\max}$:** Unavailable (no post-PnR static timing analysis run; Task 4's `100.0 MHz` figure is an assumed simulation reference only).
- **Primary Architectural Bottleneck:** `partial_result_buffer` accounts for **88.2%** of hierarchical LUTs (`14,911`) and creates the **38-stage** structural combinational path due to 9-way parallel dynamic-index read-modify-write muxes, while `integer * matrix_dim` index math infers **10** of the **19** `DSP48E1` blocks (the 9 systolic PE MACs use only `288` LUT4s and `9` `DSP48E1`s).

See [`README.md`](README.md) for the complete technical evaluation and [`reports/`](reports/) for raw parsed summary tables.
