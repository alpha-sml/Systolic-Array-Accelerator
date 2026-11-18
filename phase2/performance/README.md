# Phase II – Task 2: Performance Measurement and Throughput Analysis

## 1. Executive Summary

This document presents the comprehensive performance evaluation, latency characterization, computational throughput analysis, and processing-element (PE) utilisation metrics for the **Design and Verification of a Parameterised Output-Stationary Systolic Array Matrix Multiplication Accelerator**.

The analysis evaluates three accelerator operational configurations through cycle-accurate simulation:
1. **$3\times 3$ Standalone Accelerator Core** (`rtl/top_module.v`): Phase I baseline accelerator executing single $3\times 3$ matrix multiplications.
2. **$3\times 3$ Tiled Accelerator** (`phase2/scalability/tiled_gemm_top.v`, dimension set to 3): Single-tile execution through the Phase II matrix tiling controller.
3. **$6\times 6$ Tiled Accelerator** (`phase2/scalability/tiled_gemm_top.v`, dimension set to 6): Full multi-tile execution decomposing a $6\times 6$ matrix multiplication into 8 sequential $3\times 3$ tile operations with on-chip inter-tile accumulation.

All metrics are measured using cycle-accurate simulation counters and control-signal handshakes within the dedicated testbench `phase2/performance/tb_performance.v`.

---

## 2. Hardware Measurement Boundaries & Cycle Definitions

To ensure scientific rigor and reproducible comparisons, all measurement boundaries are strictly defined with respect to hardware interface signals:

```
+-----------------------------------------------------------------------------------------------+
|                                    End-to-End Latency                                         |
|                                                                                               |
|  +--------------------+   +---+   +--------------------+   +---+   +-----------------------+  |
|  | Matrix A & B Write |-->| S |-->| Compute Execution  |-->| R |-->|   Result Matrix Read  |  |
|  |     (Loading)      |   | T |   |   (Array Active)   |   | D |   |       (Readback)      |  |
|  +--------------------+   +---+   +--------------------+   +---+   +-----------------------+  |
|  <--- 2*M^2 cycles --->    *      <--- Compute cycles ->    *      <----- M^2 cycles ----->   |
+-----------------------------------------------------------------------------------------------+
  * ST: Protocol start handshake transition (1-2 cycles)
  * RD: Result valid capture to host read ready transition (1 cycle)
```

1. **Matrix Input Loading ($T_{\text{load}}$)**:
   - **Start Event**: Assertion of `host_write_en` for the first element ($A_{0,0}$).
   - **Completion Event**: Deassertion of `host_write_en` following the last element ($B_{M-1,M-1}$), coinciding with the assertion of `matrices_ready`.
   - **Formula**: For an $M\times M$ matrix, $T_{\text{load}} = 2 \times M^2$ streaming cycles.
2. **Computation Latency ($T_{\text{comp}}$)**:
   - **Start Event**: Rising clock edge where `host_start` is acknowledged via `start_ack = 1` and `host_busy` transitions high.
   - **Completion Event**: Assertion of `host_done` indicating completion of array computation and accumulator capture.
3. **Result Readback ($T_{\text{read}}$)**:
   - **Start Event**: Assertion of `host_read_en` for address 0 while `host_result_available = 1`.
   - **Completion Event**: Clock cycle where `host_read_valid` qualifies the final element ($C_{M-1,M-1}$).
   - **Formula**: For an $M\times M$ matrix, $T_{\text{read}} = M^2$ streaming cycles.
4. **Active Phase Sum ($T_{\text{active}}$)**:
   - Direct summation of productive operational phases:
     $$T_{\text{active}} = T_{\text{load}} + T_{\text{comp}} + T_{\text{read}}$$
5. **End-to-End Latency ($T_{\text{e2e}}$)**:
   - Total wall-clock elapsed cycles from the initial write beat to the final read valid pulse:
     $$T_{\text{e2e}} = T_{\text{active}} + T_{\text{transitions}}$$
   - Includes physical protocol transition states: write completion to start qualification (1 cycle), start registration (1 cycle), and compute completion to read enable (1 cycle).

---

## 3. Mathematical Formulations & Operation Conventions

For an $M\times M$ matrix multiplication ($C = A \times B$):

### 3.1 Arithmetic Operation Counts
- **Scalar Multiplications**: $M^3$ operations.
- **Scalar Additions**: $M^2 \times (M - 1)$ operations.
- **Multiply-Accumulate (MAC) Operations**: $M^3$ operations.
  - *Standard Convention*: 1 MAC operation comprises exactly one scalar multiplication and one accumulation ($A \times B + C_{\text{prev}}$).
- **FLOP Equivalent (Floating-Point / High-Level Equivalent)**: $2 M^3$ arithmetic operations.

### 3.2 Computational Throughput
Throughput quantifies the rate of completed operations per unit time or per clock cycle:

$$\text{MACs / cycle} = \frac{M^3}{\text{Latency (cycles)}}$$

$$\text{Throughput (MMAC/s)} = (\text{MACs / cycle}) \times f_{\text{clk}} \times 10^{-6}$$

*Note on Clock Frequency*: A reference clock frequency of $f_{\text{clk}} = 100.0\text{ MHz}$ ($T_{\text{clk}} = 10.0\text{ ns}$) is assumed solely for illustrative conversion. Measured simulation cycle counts are clock-frequency independent.

### 3.3 Processing Element (PE) Utilisation
The physical systolic core comprises $N \times N = 3 \times 3 = 9$ processing elements, each capable of 1 MAC operation per clock cycle under 100% active utilization.

- **Peak Compute Capacity**: $C_{\text{peak}} = N^2 = 9\text{ MACs/cycle}$.
- **Average MAC Rate**: $\bar{\mu} = \frac{M^3}{T_{\text{interval}}}$.
- **PE Utilisation ($\rho$)**:
  $$\rho = \frac{\bar{\mu}}{C_{\text{peak}}} = \frac{M^3}{N^2 \times T_{\text{interval}}}$$

#### Derivation of Compute Active PE Utilisation
In a 2D output-stationary systolic array of dimension $N$, computation of an $N\times N$ tile requires $(3N - 2)$ cycles. Due to the 2D spatial skewing required for systolic data alignment:
- PE $(i,j)$ receives valid non-zero operands from cycle $i + j$ to cycle $i + j + N - 1$.
- Total active compute cycles per PE is exactly $N$.
- Total productive MAC operations across all $N^2$ PEs is $N \times N^2 = N^3 = 27$ MACs.
- During the $(3N - 2)$ active compute window, the spatial array utilisation is:
  $$\rho_{\text{active}} = \frac{N^3}{N^2 \times (3N - 2)} = \frac{N}{3N - 2}$$
  For $N = 3$:
  $$\rho_{\text{active}} = \frac{3}{3(3) - 2} = \frac{3}{7} \approx 42.86\%$$

Including the initial $N = 3$ load cycles and 1 done cycle ($4N - 1 = 11$ total compute residency cycles):
$$\rho_{\text{compute\_residency}} = \frac{27}{9 \times 11} = \frac{27}{99} \approx 27.27\%$$

---

## 4. Performance Characterization & Measurement Results

The table below summarizes measured simulation cycle counts, computed operational throughput, and PE utilisation across all evaluated architectures.

| Metric | 3×3 Standalone (`top_module`) | 3×3 Tiled Top (`tiled_gemm_top`) | 6×6 Tiled Top (`tiled_gemm_top`) |
| :--- | :---: | :---: | :---: |
| **Matrix Dimension ($M \times M$)** | **3 × 3** | **3 × 3** | **6 × 6** |
| **Total Elements per Matrix ($M^2$)** | 9 | 9 | 36 |
| **Total Scalar Multiplications ($M^3$)** | 27 | 27 | 216 |
| **Total MAC Operations ($M^3$)** | 27 | 27 | 216 |
| **Number of $3\times 3$ Tile Operations** | 1 | 1 | 8 |
| **Input Loading Latency ($T_{\text{load}}$)** | **18 cycles** | **18 cycles** | **72 cycles** |
| **Compute Latency ($T_{\text{comp}}$)** | **11 cycles** | **15 cycles** | **113 cycles** |
| **Output Readback Latency ($T_{\text{read}}$)** | **9 cycles** | **9 cycles** | **36 cycles** |
| **Active Phase Sum ($T_{\text{active}}$)** | **38 cycles** | **42 cycles** | **221 cycles** |
| **End-to-End Elapsed Latency ($T_{\text{e2e}}$)** | **41 cycles** | **45 cycles** | **224 cycles** |
| **Compute MACs / cycle** | **2.4545** | **1.8000** | **1.9115** |
| **Active MACs / cycle** | **0.7105** | **0.6429** | **0.9774** |
| **End-to-End MACs / cycle** | **0.6585** | **0.6000** | **0.9643** |
| **Compute Throughput (@ 100 MHz reference)** | **245.45 MMAC/s** | **180.00 MMAC/s** | **191.15 MMAC/s** |
| **End-to-End Throughput (@ 100 MHz reference)** | **65.85 MMAC/s** | **60.00 MMAC/s** | **96.43 MMAC/s** |
| **Compute PE Utilisation ($\rho_{\text{comp}}$)** | **27.27 %** | **20.00 %** | **21.24 %** |
| **Active PE Utilisation ($\rho_{\text{active}}$)** | **7.89 %** | **7.14 %** | **10.86 %** |
| **End-to-End PE Utilisation ($\rho_{\text{e2e}}$)** | **7.32 %** | **6.67 %** | **10.71 %** |
| **Sequential Baseline Speedup** | *Pending (Sep Task)* | *Pending (Sep Task)* | *Pending (Sep Task)* |

> [!IMPORTANT]
> **Simulation vs. Physical Hardware Disclaimer**:
> Cycle counts in this table represent exact, deterministic simulation cycle measurements derived from Verilog RTL. Throughput figures (MMAC/s) assume a nominal 100.0 MHz reference clock for comparative convenience. They do not represent post-synthesis timing closure, physical FPGA operating frequencies, or board-level propagation delays.

---

## 5. In-Depth Performance and Throughput Analysis

### 5.1 Standalone $3\times 3$ Core Analysis
- **Compute Latency**: $4N - 1 = 11$ cycles.
  - Phase 1: 3 cycles for operand staging and systolic pre-load.
  - Phase 2: $3N - 2 = 7$ cycles for systolic wave propagation across the $3\times 3$ grid.
  - Phase 3: 1 cycle for accumulator snapshot capture into the output buffer.
- **Compute Throughput**: Achieves $2.4545\text{ MACs/cycle}$ ($245.45\text{ MMAC/s}$ at 100 MHz).
- **Transport Bottleneck**: Host matrix loading (18 cycles) and readback (9 cycles) comprise 27 of the 38 active cycles ($71.05\%$). Because the single-tile architecture relies on single-port streaming host interfaces, host I/O dominates latency for isolated matrix operations.

### 5.2 Tiling Overhead in $3\times 3$ Single-Tile Execution
- When executing a single $3\times 3$ matrix through the tiled wrapper (`tiled_gemm_top`), compute latency increases from 11 cycles to 15 cycles.
- The 4-cycle overhead consists of:
  - 1 cycle for dimension decoding and sub-controller start pulse generation.
  - 1 cycle for tile index initialization (`tile_i = 0, tile_j = 0, tile_k = 0`).
  - 1 cycle for accumulator capture enable and inter-tile accumulation check.
  - 1 cycle for `ST_DONE` handshake to host.
- This overhead represents a fixed protocol penalty ($36.4\%$) when invoking the scalable framework on a minimal single tile.

### 5.3 Scaling and Multi-Tile Efficiency in $6\times 6$ GEMM
- **Tile Decomposition**: A $6\times 6$ matrix multiplication with a $3\times 3$ physical array requires:
  $$K_{\text{tiles}} = \left(\frac{M}{N}\right)^3 = \left(\frac{6}{3}\right)^3 = 2^3 = 8\text{ tile operations}$$
- **Compute Latency Breakdown**:
  $$T_{\text{comp}} = 8 \times 14\text{ cycles/tile} + 1\text{ cycle final transition} = 113\text{ cycles}$$
  Each tile executes in 14 cycles (11 array cycles + 3 tiling coordination cycles).
- **Throughput Amortization**:
  - The computational throughput for $6\times 6$ reaches $1.9115\text{ MACs/cycle}$ ($191.15\text{ MMAC/s}$), significantly outpacing the single-tile wrapped throughput ($1.8000\text{ MACs/cycle}$).
  - End-to-end throughput increases from $0.6000\text{ MACs/cycle}$ ($3\times 3$ tiled) to $0.9643\text{ MACs/cycle}$ ($6\times 6$ tiled), representing a **$60.7\%$ throughput improvement**.
  - PE utilisation across the complete end-to-end execution rises from $6.67\%$ to $10.71\%$, as the computation workload ($M^3 = 216$) grows faster than the I/O transfer workload ($3 M^2 = 108$).

```
Throughput Scaling Behavior:
  3x3 Tiled:  [======= 0.600 MACs/cycle E2E =======]
  6x6 Tiled:  [============ 0.964 MACs/cycle E2E ============]
  Compute:    [======================== 1.912 MACs/cycle ========================]
```

### 5.4 Data-Independence and Zero-Jitter Determinism
As demonstrated in Suites 3, 4, and 5 of `tb_performance.v`:
- Positive operand matrices and mixed-sign boundary operand matrices ($-128, +127, -1, 0, +1$) exhibit **identical cycle counts**:
  - Loading: 72 cycles.
  - Compute: 113 cycles.
  - Readback: 36 cycles.
  - End-to-End: 224 cycles.
- Repeated back-to-back runs exhibit **zero timing variance (jitter = 0)**. The architecture operates entirely without data-dependent stalls, branch penalties, or cache misses.

---

## 6. Sequential Baseline Comparison Framework

To evaluate acceleration efficiency against traditional sequential processing, a standard baseline is defined.

### 6.1 Baseline Definition & Analytical Model
A single-MAC sequential matrix multiplication engine consists of:
- One single-cycle MAC unit identical in precision (8-bit signed inputs, 32-bit accumulator).
- Sequential triple nested loop ($i, j, k$) executing:
  $$C[i,j] \leftarrow C[i,j] + A[i,k] \times B[k,j]$$
- Compute latency for 1-MAC sequential baseline:
  $$T_{\text{seq\_comp}} = M^3\text{ cycles}$$
  - $3\times 3$ Matrix: $3^3 = 27\text{ cycles}$.
  - $6\times 6$ Matrix: $6^3 = 216\text{ cycles}$.

### 6.2 Speedup Formulation
$$\text{Speedup}_{\text{comp}} = \frac{T_{\text{seq\_comp}}}{T_{\text{systolic\_comp}}}$$

$$\text{Speedup}_{\text{e2e}} = \frac{T_{\text{seq\_e2e}}}{T_{\text{systolic\_e2e}}}$$

- **Analytical Compute Speedup ($3\times 3$ Standalone)**:
  $$\text{Speedup}_{\text{comp}} = \frac{27}{11} \approx 2.4545\times$$
- **Analytical Compute Speedup ($6\times 6$ Tiled)**:
  $$\text{Speedup}_{\text{comp}} = \frac{216}{113} \approx 1.9115\times$$

> [!NOTE]
> **Pending Empirical Comparison**:
> In accordance with strict modular development guidelines, empirical RTL cycle counts and waveform comparisons for the sequential baseline are maintained under the dedicated baseline task directory (`phase2/baseline/`). Once the hardware implementation of the sequential baseline is committed under its respective task, measured baseline cycle counts will populate empirical speedup tables.

---

## 7. Verification and Reproducibility

The performance measurement testbench is fully automated, non-terminating on silent failures, and self-checking against software reference models.

### 7.1 Running the Performance Testbench
Execute the dedicated Makefile target from the repository root:

```bash
make test-performance
```

### 7.2 Testbench Test Suite Summary
The testbench executes six rigorous test suites:
- **Suite 1**: $3\times 3$ Standalone Core cycle verification and numerical match.
- **Suite 2**: $3\times 3$ Single-Tile execution on `tiled_gemm_top`.
- **Suite 3**: $6\times 6$ Multi-Tile execution on `tiled_gemm_top` with positive operands.
- **Suite 4**: $6\times 6$ Multi-Tile execution with signed boundary operands ($-128, +127, -1, 0, +1$).
- **Suite 5**: Zero-variance determinism across consecutive back-to-back executions.
- **Suite 6**: Watchdog timeout, protocol boundary error handling, and illegal dimension rejection.

### 7.3 Verification Outcome
```
==================================================================
PERFORMANCE VERIFICATION SUMMARY:
  PASSED CHECKS : 192
  FAILED CHECKS : 0
==================================================================
RESULT: ALL PERFORMANCE TESTS AND MEASUREMENTS PASSED!
```
