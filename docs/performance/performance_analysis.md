# Performance Analysis and Sequential Baseline Comparison

This document summarizes the latency, throughput, and speedup evaluation comparing the core and tiled systolic accelerators against a sequential single-MAC reference baseline.

---

## 1. Sequential GEMM Baseline (`rtl/baseline/sequential_gemm.v`)

To establish a fair hardware comparison under identical precision (8-bit signed inputs, 32-bit signed accumulators) and identical single-element host interface semantics:

- **Architecture:** Single combinational 8×8 signed multiplier + 32-bit signed accumulator (`acc_reg`) with three nested loop counters $(i, j, k)$ executing one scalar MAC per clock cycle across `ST_IDLE`, `ST_COMP`, and `ST_DONE`.
- **Supported Dimensions:** `cfg_matrix_dim` $\in \{3, 6\}$ (`3×3` = $3^3 = 27$ compute cycles; `6×6` = $6^3 = 216$ compute cycles).
- **Verification ([`tb_sequential_gemm.v`](../../testbench/baseline/tb_sequential_gemm.v)):** **636 checks passed, 0 failed** across reset, protocol/write rejection in `ST_COMP` and `ST_DONE`, 3×3/6×6 positive & boundary operands, back-to-back operations, and mid-compute reset recovery.

---

## 2. Measurement Methodology and Metric Definitions

All cycle counts are measured at hardware interface boundaries in [`tb_performance.v`](../../testbench/extensions/tb_performance.v) (240 checks passed, 0 failed) and [`tb_sequential_gemm.v`](../../testbench/baseline/tb_sequential_gemm.v):

- **$T_{\text{load}}$ (Input Loading):** $2M^2$ single-element write beats ($18$ cycles for $3 \times 3$; $72$ cycles for $6 \times 6$).
- **$T_{\text{comp}}$ (Compute Latency):** Cycles from accepted `start_ack` to `host_done`.
- **$T_{\text{read}}$ (Result Readback):** $M^2$ synchronous read beats ($9$ cycles for $3 \times 3$; $36$ cycles for $6 \times 6$).
- **$T_{\text{active}}$ (Active Phase Sum):** $T_{\text{load}} + T_{\text{comp}} + T_{\text{read}}$.
- **$T_{\text{e2e}}$ (Seamless End-to-End Latency):** $T_{\text{active}} + 2$ transition cycles (1 write-to-start handoff + 1 done-to-read handoff). When a quiescent host bubble separates matrix write and start assertion, end-to-end latency increases by exactly 1 cycle (224 vs. 223 at 6×6, audited in Suite 7 of `tb_performance.v`).
- **MAC Throughput:** $\text{MACs/cycle} = M^3 / \text{Latency}$, where total MAC operations equal $M^3$ ($27$ for $3 \times 3$; $216$ for $6 \times 6$).

> [!IMPORTANT]
> **Reference Clock Disclaimer:** Throughput figures in `MMAC/s` below use a nominal **100.0 MHz** ($T_{\text{clk}} = 10.0\text{ ns}$) analytical reference clock for cycle-to-rate normalization only. They are **not** measured post-implementation FPGA operating frequencies (see [`fpga/README.md`](../../fpga/README.md)).

---

## 3. Verified Comparison Results

### Primary Cycle-Count Summary (Simulation Measurements)

| Architecture | Matrix | Compute cycles | End-to-end cycles |
|---|---|---:|---:|
| Sequential | 3×3 | 27 | 56 |
| Standalone systolic | 3×3 | 11 | 40 |
| Tiled systolic | 3×3 | 15 | 44 |
| Sequential | 6×6 | 216 | 326 |
| Tiled systolic | 6×6 | 113 | 223 |

### Detailed Throughput and Speedup Breakdown

| Metric | Sequential (3×3) | Standalone Systolic (3×3) | Tiled Systolic (3×3) | Sequential (6×6) | Tiled Systolic (6×6) |
| :--- | :---: | :---: | :---: | :---: | :---: |
| **Total MACs ($M^3$)** | 27 | 27 | 27 | 216 | 216 |
| **Active PEs ($N_{\text{PE}}$)** | 1 | 9 | 9 | 1 | 9 |
| **Load / Read Cycles ($T_{\text{load}} / T_{\text{read}}$)** | 18 / 9 | 18 / 9 | 18 / 9 | 72 / 36 | 72 / 36 |
| **Active Sum ($T_{\text{active}}$)** | 54 | 38 | 42 | 324 | 221 |
| **Compute MACs / cycle** | 1.0000 | **2.4545** | 1.8000 | 1.0000 | **1.9115** |
| **Seamless E2E MACs / cycle** | 0.4821 | **0.6750** | 0.6136 | 0.6626 | **0.9686** |
| **Decoupled E2E Cycles ($T_{\text{active}} + 3$)** | 57 | 41 | 45 | 327 | 224 |
| **Decoupled E2E MACs / cycle** | 0.4737 | **0.6585** | 0.6000 | 0.6606 | **0.9643** |
| **Compute Throughput (@ 100 MHz ref)** | 100.00 MMAC/s | **245.45 MMAC/s** | 180.00 MMAC/s | 100.00 MMAC/s | **191.15 MMAC/s** |
| **Seamless E2E Throughput (@ 100 MHz ref)** | 48.21 MMAC/s | **67.50 MMAC/s** | 61.36 MMAC/s | 66.26 MMAC/s | **96.86 MMAC/s** |
| **Decoupled E2E Throughput (@ 100 MHz ref)** | 47.37 MMAC/s | **65.85 MMAC/s** | 60.00 MMAC/s | 66.06 MMAC/s | **96.43 MMAC/s** |
| **Compute Speedup vs. Sequential** | 1.0000× | **2.4545×** | 1.8000× | 1.0000× | **1.9115×** |
| **Seamless E2E Speedup vs. Sequential** | 1.0000× | **1.4000×** | 1.2727× | 1.0000× | **1.4619×** |
| **Decoupled E2E Speedup vs. Sequential** | 1.0000× | **1.3902×** | 1.2667× | 1.0000× | **1.4598×** |

---

## 4. Key Observations

1. **Core 3×3 Compute vs. Transport Bottleneck:** The primary 3×3 standalone systolic core reduces compute latency by **59.26%** (27 → 11 cycles, **2.4545×** compute speedup). Because single-word host transfers occupy 27 of 38 active cycles (**71.05%**), end-to-end speedup is **1.4000×** (56 → 40 cycles).
2. **Optional 6×6 Tiled Scaling:** At 6×6, arithmetic scales cubically ($216$ MACs, $8\times$) while host transfers scale quadratically ($108$ cycles, $4\times$), raising end-to-end throughput from `0.6136` to `0.9686 MACs/cycle` (**1.4619×** E2E speedup over sequential 6×6).
3. **PE Utilization Trade-Off:** Spatial wavefront fill/drain limits single-operation compute-phase PE utilization of the 3×3 array to $\rho = N / (3N - 2) = 3/7 \approx 42.9\%$ during the 7 active compute cycles (27.27% across the 11-cycle residency), whereas the single-MAC sequential engine keeps its lone MAC active 100% of compute cycles at the cost of $M^3$ latency.
4. **Equal-Clock Assumption:** Cycle speedups translate directly into wall-clock speedups only if both designs achieve comparable clock frequencies after FPGA place-and-route, which remains unverified without vendor static timing analysis.
