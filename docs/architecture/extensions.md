# Optional Extensions Architecture (Phase II)

This document covers the optional architectural extensions in `rtl/extensions/` built on top of the unmodified Phase I core (`rtl/core/`). Neither extension is required for the core 3×3 demonstration (`make demo`).

---

## Extension A — Tiled Matrix Multiplication

Tiled matrix multiplication scales computation beyond the physical $3 \times 3$ systolic array to support both **3×3** and **6×6** matrices (`cfg_matrix_dim` $\in \{3, 6\}$) while reusing `systolic_array` and `systolic_controller` unmodified.

### Modules (`rtl/extensions/`)
- [`matrix_tiling_controller.v`](../../rtl/extensions/matrix_tiling_controller.v): Six-state FSM (`ST_IDLE`, `ST_TILE_START`, `ST_TILE_EXEC`, `ST_TILE_CAPTURE`, `ST_TILE_NEXT`, `ST_DONE`) sequencing tile triples $(i, j, k)$ in row-major output order ($k$ innermost, $j$ middle, $i$ outermost). Asserts `accumulate_en = (tile_k != 0)` so $k = 0$ initializes the output tile and $k > 0$ accumulates into stored partial sums.
- [`tiled_input_buffer.v`](../../rtl/extensions/tiled_input_buffer.v): Stores full matrices `A` and `B` (up to $6 \times 6 = 36$ signed 8-bit elements each), validates `matrix_dim`, stages active $3 \times 3$ tiles $A(i, k)$ and $B(k, j)$ during `LOAD`, and generates skewed boundary inputs during `COMPUTE`.
- [`partial_result_buffer.v`](../../rtl/extensions/partial_result_buffer.v): Holds up to 36 signed 32-bit accumulators (`c_mem`). On `capture_en`, stores the $3 \times 3$ `acc_in` tile directly if `!accumulate_en`, or adds `c_mem[g_idx] + elem_in` if `accumulate_en`.
- [`tiled_gemm_top.v`](../../rtl/extensions/tiled_gemm_top.v): Integrates the tiling modules with `systolic_controller` and `systolic_array` behind the standard element-by-element host interface, strictly rejecting unsupported dimensions (`cfg_matrix_dim` $\notin \{3, 6\}$).

### Tiled Execution Schedule
- **3×3 (`cfg_matrix_dim = 3`):** $K = 1$, $1$ tile pass $(0,0,0)$; compute latency = **15 cycles** (11 array cycles + 4 tiling wrapper cycles).
- **6×6 (`cfg_matrix_dim = 6`):** $K = 2$, $(6/3)^3 = 8$ tile passes $(0,0,0) \dots (1,1,1)$; each tile launches every **14 cycles** ($11$ array + $1$ capture + $1$ next + $1$ sync), yielding **113 compute cycles** ($8 \times 14 + 1$).

### Verification (`testbench/extensions/tb_tiled_gemm.v`)
- **1,164 checks passed, 0 failed** across 9 test suites: 3×3 single-tile, 6×6 positive GEMM with 14-cycle per-tile and 113-cycle compute verification, 6×6 extreme signed boundaries (`-128`, `+127`, `-1`, `0`), inter-tile additive cancellation, unsupported dimension rejection (`5`, `4`, `0`), mid-compute async reset recovery, back-to-back runs, protocol guarantees, and 221-active / 223-E2E cycle audit.

---

## Extension B — Advanced Burst Host Interface and System Integration

Element-wise loading dominates end-to-end latency for isolated matrix multiplications (~71% of active cycles at 3×3). Extension B replaces single-element transfers with a burst/packed host bus while preserving Phase I error-rejection and start-lockout semantics.

### Modules (`rtl/extensions/`)
- [`burst_matrix_interface.v`](../../rtl/extensions/burst_matrix_interface.v):
  - **Streaming Mode (`burst_write_packed = 0`):** Writes one 8-bit element per beat from `burst_write_data[7:0]` with auto-incrementing linear addressing (`addr .. addr + len - 1`).
  - **Packed 32-bit Word Mode (`burst_write_packed = 1`):** Accepts four 8-bit elements per 32-bit word (`[7:0]`, `[15:8]`, `[23:16]`, `[31:24]`). Writes sub-word 0 combinationally with zero pipeline bubbles, then deasserts `burst_write_ready = 0` for 3 cycles (`W_PACKED_DRAIN`) while draining sub-words 1–3.
  - **Error Qualification:** Emits `burst_write_err` and 3-bit `burst_err_code` (`ERR_BUSY`, `ERR_ADDR`, `ERR_LEN`, `ERR_DIM`) on invalid transactions without corrupting buffers.
  - **2-Stage Lossless Skid Buffer:** Holds active and in-flight 32-bit readback words from synchronous `partial_result_buffer` memory when the host deasserts `burst_read_ready`.
  - **Start Lockout:** Rising-edge detection on `host_start` with `reset_lock` and `matrices_ready` gating.
- [`integrated_gemm_top.v`](../../rtl/extensions/integrated_gemm_top.v): Top-level integration combining `burst_matrix_interface`, `tiled_input_buffer`, `matrix_tiling_controller`, `partial_result_buffer`, `systolic_controller`, and `systolic_array` (120 external I/O pins: 71 inputs, 49 outputs).

### Verification (`testbench/extensions/`)
- [`tb_burst_interface.v`](../../testbench/extensions/tb_burst_interface.v): **215 checks passed, 0 failed** (12 suites covering streaming/packed bursts, backpressure, error codes, start lockout, async abort, and skid-buffer pauses).
- [`tb_integrated_top.v`](../../testbench/extensions/tb_integrated_top.v): **808 checks passed, 0 failed** (8 suites covering 3×3 streaming, 6×6 packed-32b GEMM, signed boundaries, back-to-back invalidation, error codes, mid-compute reset recovery, and backpressured 36-element readback).
