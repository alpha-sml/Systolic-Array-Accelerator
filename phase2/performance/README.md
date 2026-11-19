# Phase II – Task 2: Performance Measurement and Throughput Analysis

## 1. Executive Summary

This document presents the complete performance evaluation, cycle-accurate latency characterization, computational throughput analysis, and processing-element (PE) utilisation metrics for the **Design and Verification of a Parameterised Output-Stationary Systolic Array Matrix Multiplication Accelerator**.

The performance analysis evaluates three accelerator operational configurations through cycle-accurate RTL simulation:
1. **$3\times 3$ Standalone Accelerator Core** (`rtl/top_module.v`): The baseline Phase I accelerator executing single $3\times 3$ matrix multiplications.
2. **$3\times 3$ Tiled Accelerator** (`phase2/scalability/tiled_gemm_top.v`, dimension set to 3): Single-tile execution through the Phase II matrix tiling controller.
3. **$6\times 6$ Tiled Accelerator** (`phase2/scalability/tiled_gemm_top.v`, dimension set to 6): Full multi-tile execution decomposing a $6\times 6$ matrix multiplication into 8 sequential $3\times 3$ tile operations with on-chip inter-tile accumulation.

All metrics are measured using cycle-accurate simulation counters and control-signal handshakes within the dedicated testbench [`phase2/performance/tb_performance.v`](tb_performance.v).

---

## 2. Hardware Measurement Boundaries & Cycle Definitions

To ensure scientific rigor and reproducible comparisons, all measurement boundaries are anchored to exact hardware interface events:

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
   - **Formula**: For an $M\times M$ matrix, $T_{\text{load}} = 2 \times M^2$ streaming cycles (18 cycles for $3\times 3$, 72 cycles for $6\times 6$).
2. **Computation Latency ($T_{\text{comp}}$)**:
   - **Start Event**: Rising clock edge where `host_start` is acknowledged via `start_ack = 1` and `host_busy` transitions high.
   - **Completion Event**: Assertion of `host_done` indicating completion of array computation and accumulator capture.
   - **Formula**: 
     - Standalone $3\times 3$: $4N - 1 = 11$ cycles ($N=3$ load, $3N-2=7$ compute, $1$ done).
     - Tiled $3\times 3$: 15 cycles (11 array cycles + 4 tiling wrapper cycles).
     - Tiled $6\times 6$: 113 cycles ($8\text{ tiles} \times 14\text{ cycles/tile} + 1\text{ cycle final transition}$).
3. **Result Readback ($T_{\text{read}}$)**:
   - **Start Event**: Assertion of `host_read_en` for address 0 while `host_result_available = 1`.
   - **Completion Event**: Clock cycle where `host_read_valid` qualifies the final element ($C_{M-1,M-1}$).
   - **Formula**: For an $M\times M$ matrix, $T_{\text{read}} = M^2$ streaming cycles (9 cycles for $3\times 3$, 36 cycles for $6\times 6$).
4. **Active Phase Sum ($T_{\text{active}}$)**:
   - Direct summation of productive operational phases:
     $$T_{\text{active}} = T_{\text{load}} + T_{\text{comp}} + T_{\text{read}}$$
     - $3\times 3$ Standalone: $18 + 11 + 9 = \mathbf{38\text{ cycles}}$.
     - $3\times 3$ Tiled: $18 + 15 + 9 = \mathbf{42\text{ cycles}}$.
     - $6\times 6$ Tiled: $72 + 113 + 36 = \mathbf{221\text{ cycles}}$.
5. **End-to-End Latency ($T_{\text{e2e}}$)**:
   - Total wall-clock elapsed cycles from the initial write beat to the final read valid pulse:
     $$T_{\text{e2e}} = T_{\text{active}} + T_{\text{transitions}}$$

---

## 3. Investigation & Resolution of the 223 vs 224 Cycle Discrepancy

### 3.1 Background of the Discrepancy
- **Task 1 Documentation (`phase2/scalability/README.md`)**: Reported **223 cycles** for the $6\times 6$ host-boundary elapsed measurement in Test 9 of `tb_tiled_gemm.v`.
- **Initial Task 2 Implementation**: Reported and asserted **224 cycles** for the $6\times 6$ host-boundary elapsed measurement.

### 3.2 Root Cause Analysis
A cycle-by-cycle waveform audit of both testbenches and the RTL interface revealed the exact origin of the 1-cycle variance:

1. **Task 1 Protocol (Seamless Pipelined Handoff = 223 Cycles)**:
   - In `phase2/scalability/tb_tiled_gemm.v`, the testbench asserts `host_start = 1` on the negative clock edge of the 72nd write beat.
   - On the very next positive clock edge, `matrices_ready` is valid and `start_ack` asserts immediately.
   - **Transition Breakdown**:
     - Write-to-Start handoff: **1 cycle** (`last_write -> start_ack`).
     - Done-to-Read handoff: **1 cycle** (`host_done -> result_available / read_en`).
     - Total transition overhead: $1 + 1 = \mathbf{2\text{ cycles}}$.
     - Total elapsed time: $221\text{ (active)} + 2\text{ (transitions)} = \mathbf{223\text{ cycles}}$.

2. **Decoupled Protocol (Non-Seamless Host Bubble = 224 Cycles)**:
   - When a host interface deasserts `host_write_en`, allows one quiescent clock cycle to elapse (`@(posedge clk)` idle bubble), and then pulses `host_start = 1` on a subsequent cycle, an additional cycle is introduced.
   - **Transition Breakdown**:
     - Write-completion-to-start-issue bubble: **1 cycle**.
     - Start-issue-to-start_ack: **1 cycle**.
     - Done-to-Read handoff: **1 cycle**.
     - Total transition overhead: $1 + 1 + 1 = \mathbf{3\text{ cycles}}$.
     - Total elapsed time: $221\text{ (active)} + 3\text{ (transitions)} = \mathbf{224\text{ cycles}}$.

### 3.3 Resolution and Harmonization
- **Primary Standard**: Task 2's primary measurement has been **harmonized to the optimal seamless protocol matching Task 1 exactly (223 cycles)**.
- **Verification Audit**: Suite 7 of `phase2/performance/tb_performance.v` explicitly executes both protocols back-to-back, asserting:
  - Seamless $6\times 6$ E2E latency: **223 cycles** (exact match with Task 1).
  - Decoupled $6\times 6$ E2E latency: **224 cycles** ($223 + 1\text{ bubble}$).
  - Difference: **exactly 1 cycle**, with identical active operational phase sums (**221 cycles**).
- Similarly, for the $3\times 3$ standalone and tiled accelerators:
  - $3\times 3$ Standalone: **40 cycles** (seamless) vs **41 cycles** (decoupled).
  - $3\times 3$ Tiled: **44 cycles** (seamless) vs **45 cycles** (decoupled).

---

## 4. Mathematical Formulations & Operation Conventions

For an $M\times M$ matrix multiplication ($C = A \times B$):

### 4.1 Arithmetic Operation Counts
- **Scalar Multiplications**: $M^3$ operations.
- **Scalar Additions**: $M^2 \times (M - 1)$ operations.
- **Multiply-Accumulate (MAC) Operations**: $M^3$ operations.
  - *Standard Convention*: 1 MAC operation comprises exactly one scalar multiplication and one accumulation ($A \times B + C_{\text{prev}}$).
- **FLOP Equivalent (Floating-Point / High-Level Equivalent)**: $2 M^3$ arithmetic operations ($M^3$ multiplications + $M^3$ additions with 0 initialization).

### 4.2 Computational Throughput
Throughput quantifies the rate of completed operations per unit time or per clock cycle:

$$\text{MACs / cycle} = \frac{M^3}{\text{Latency (cycles)}}$$

$$\text{Throughput (MMAC/s)} = (\text{MACs / cycle}) \times f_{\text{clk}} \times 10^{-6}$$

*Note on Clock Frequency*: A reference clock frequency of $f_{\text{clk}} = 100.0\text{ MHz}$ ($T_{\text{clk}} = 10.0\text{ ns}$) is assumed solely for illustrative conversion. Measured simulation cycle counts are clock-frequency independent.

### 4.3 Processing Element (PE) Utilisation
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

## 5. Performance Characterization & Measurement Results

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
| **Seamless E2E Elapsed ($T_{\text{e2e}}$)** | **40 cycles** | **44 cycles** | **223 cycles** |
| **Decoupled E2E Elapsed ($T_{\text{e2e\_dec}}$)** | **41 cycles** | **45 cycles** | **224 cycles** |
| **Compute MACs / cycle** | **2.4545** | **1.8000** | **1.9115** |
| **Active MACs / cycle** | **0.7105** | **0.6429** | **0.9774** |
| **Seamless E2E MACs / cycle** | **0.6750** | **0.6136** | **0.9686** |
| **Compute Throughput (@ 100 MHz reference)** | **245.45 MMAC/s** | **180.00 MMAC/s** | **191.15 MMAC/s** |
| **Seamless E2E Throughput (@ 100 MHz reference)** | **67.50 MMAC/s** | **61.36 MMAC/s** | **96.86 MMAC/s** |
| **Compute PE Utilisation ($\rho_{\text{comp}}$)** | **27.27 %** | **20.00 %** | **21.24 %** |
| **Active PE Utilisation ($\rho_{\text{active}}$)** | **7.89 %** | **7.14 %** | **10.86 %** |
| **Seamless E2E PE Utilisation ($\rho_{\text{e2e}}$)** | **7.50 %** | **6.82 %** | **10.76 %** |
| **Compute Speedup vs. Sequential Baseline** | **2.4545x** | **1.8000x** | **1.9115x** |
| **Seamless E2E Speedup vs. Sequential Baseline** | **1.4000x** | **1.2727x** | **1.4619x** |

> [!IMPORTANT]
> **Simulation vs. Physical Hardware Disclaimer**:
> Cycle counts in this table represent exact, deterministic simulation cycle measurements derived from Verilog RTL. Throughput figures (MMAC/s) assume a nominal 100.0 MHz reference clock for comparative convenience. They do not represent post-synthesis timing closure, physical FPGA operating frequencies, or board-level propagation delays.

---

## 6. In-Depth Performance and Throughput Analysis

### 6.1 Parallel Computation Mechanics & Systolic Wavefronts
The output-stationary systolic array computes matrix multiplications in parallel by circulating operands through a 2D mesh of Processing Elements:
- Operands $A$ flow horizontally from the west boundary.
- Operands $B$ flow vertically from the north boundary.
- Accumulators remain stationary inside each PE, avoiding high-fanout accumulator buses.
- **Wavefront Propagation**: Because boundary inputs are skewed by row index ($i$ cycles) and column index ($j$ cycles), computation propagates diagonally across the array. PE $(0,0)$ begins active MAC computation on cycle 0, while PE $(2,2)$ completes computation on cycle $3N-3 = 6$.

### 6.2 Fill and Drain Overheads
- The spatial skewing introduces fill and drain latency:
  - Fill phase: $2N - 2$ cycles for operands to reach the bottom-right PE.
  - Drain phase: trailing edges of matrices clear the array.
- This fill/drain overhead limits instantaneous PE utilisation to $\rho_{\text{active}} = N / (3N - 2) = 42.86\%$ for $N = 3$. As $N$ scales, $\rho_{\text{active}} \to 33.3\%$.

### 6.3 Transport Bottleneck in Isolated Operations
- For isolated $3\times 3$ standalone execution:
  - Input write: 18 cycles.
  - Output read: 9 cycles.
  - Total transport: 27 cycles ($71.05\%$ of active operational time).
- Because operands and results are transferred over single-port streaming buses, host I/O dominates latency for small, isolated matrix multiplications.

### 6.4 Multi-Tile Scaling Advantage in $6\times 6$ GEMM
- **Decomposition**: $K_{\text{tiles}} = (M/N)^3 = (6/3)^3 = 8$ tile operations.
- **Computational Scaling**:
  - The computational workload scales cubically: $M^3 = 6^3 = 216\text{ MACs}$ (an $8\times$ increase over $3\times 3$).
  - Host I/O transfer scales quadratically: $3 M^2 = 108\text{ cycles}$ (a $4\times$ increase over $3\times 3$).
- **Throughput Amortization**:
  - End-to-end throughput increases from $0.6136\text{ MACs/cycle}$ ($3\times 3$ tiled) to $0.9686\text{ MACs/cycle}$ ($6\times 6$ tiled), representing a **$57.9\%$ throughput improvement**.
  - PE utilisation across the complete end-to-end execution rises from $6.82\%$ to $10.76\%$.

### 6.5 Data-Independence & Zero-Jitter Determinism
As verified in Suites 3, 4, and 5 of `tb_performance.v`:
- Positive integer operands and full-range mixed-sign boundary operands ($-128, +127, -1, 0, +1$) exhibit **identical cycle counts**:
  - Loading: 72 cycles.
  - Compute: 113 cycles.
  - Readback: 36 cycles.
  - Seamless E2E: 223 cycles.
- Repeated back-to-back executions exhibit **zero timing variance (jitter = 0)**. The pipeline contains no data-dependent branching, stalls, or caches.

---

## 7. Sequential Baseline Comparison Framework

To evaluate acceleration efficiency against traditional sequential processing, a standard baseline is defined.

### 7.1 Baseline Definition & Analytical Model
A single-MAC sequential matrix multiplication engine consists of:
- One single-cycle MAC unit identical in precision (8-bit signed inputs, 32-bit accumulator).
- Sequential triple nested loop ($i, j, k$) executing:
  $$C[i,j] \leftarrow C[i,j] + A[i,k] \times B[k,j]$$
- Compute latency for 1-MAC sequential baseline:
  $$T_{\text{seq\_comp}} = M^3\text{ cycles}$$
  - $3\times 3$ Matrix: $3^3 = 27\text{ cycles}$.
  - $6\times 6$ Matrix: $6^3 = 216\text{ cycles}$.

### 7.2 Speedup Formulation
$$\text{Speedup}_{\text{comp}} = \frac{T_{\text{seq\_comp}}}{T_{\text{systolic\_comp}}}$$

$$\text{Speedup}_{\text{e2e}} = \frac{T_{\text{seq\_e2e}}}{T_{\text{systolic\_e2e}}}$$

- **Analytical Compute Speedup ($3\times 3$ Standalone)**:
  $$\text{Speedup}_{\text{comp}} = \frac{27}{11} \approx \mathbf{2.4545\times}$$
- **Analytical Compute Speedup ($6\times 6$ Tiled)**:
  $$\text{Speedup}_{\text{comp}} = \frac{216}{113} \approx \mathbf{1.9115\times}$$

> [!NOTE]
> **Empirical Comparison Completed**:
> The synthesizable 1-MAC sequential baseline has been implemented in [`phase2/baseline/sequential_gemm.v`](../baseline/sequential_gemm.v) and verified with [`phase2/baseline/tb_sequential_gemm.v`](../baseline/tb_sequential_gemm.v). The measured cycle counts ($T_{\text{comp}} = 27$ cycles for 3×3, $216$ cycles for 6×6) match the analytical predictions with 100% precision. Complete documentation and speedup tables are detailed in [`phase2/baseline/README.md`](../baseline/README.md).

---

## 8. Verification and Reproducibility

The performance measurement testbench is fully automated, non-terminating on silent failures, and self-checking against software reference models.

### 8.1 Reproducible Execution Commands
Execute the dedicated Makefile target from the repository root:

```bash
make test-performance
```

To run all system regressions:
```bash
make test               # All Phase I suites (MAC, PE, Array, Controller, Data, Top)
make test-tiled         # Phase II Task 1 tiled GEMM testbench
make test-performance   # Phase II Task 2 performance testbench
make synth-check        # Yosys structural hierarchy check (Phase I top_module)
make synth-check-tiled  # Yosys structural hierarchy check (Phase II tiled_gemm_top)
```

### 8.2 Tool Versions & Environment
- **Simulator**: Icarus Verilog `iverilog` version 13.0 (devel) with `vvp` runtime.
- **Synthesis Linter**: Yosys 0.70+post (git sha1 0c11ea098be065e585a90a06e7b7da49936cf231).
- **Compilation Flags**: `-g2012 -Wall`.

### 8.3 Test Suite Breakdown
The testbench executes seven rigorous test suites:
- **Suite 1**: $3\times 3$ Standalone Core cycle verification and numerical match.
- **Suite 2**: $3\times 3$ Single-Tile execution on `tiled_gemm_top`.
- **Suite 3**: $6\times 6$ Multi-Tile execution on `tiled_gemm_top` with positive operands.
- **Suite 4**: $6\times 6$ Multi-Tile execution with signed boundary operands ($-128, +127, -1, 0, +1$).
- **Suite 5**: Zero-variance determinism across consecutive back-to-back executions.
- **Suite 6**: Watchdog timeout, protocol boundary error handling, and illegal dimension rejection.
- **Suite 7**: Protocol timing audit proving exact 223 vs 224 cycle boundary conditions.

### 8.4 Verification Outcome
```
==================================================================
PERFORMANCE VERIFICATION SUMMARY:
  PASSED CHECKS : 240
  FAILED CHECKS : 0
==================================================================
RESULT: ALL PERFORMANCE TESTS AND MEASUREMENTS PASSED!
```

---

## 9. Known Limitations

1. **Host I/O Bandwidth**: Matrices are transferred sequentially over a single-beat streaming interface. Adding double-buffering or wide multi-word memory interfaces would allow overlapping loading with computation.
2. **Fixed Physical Dimensions**: The physical systolic array is configured for $N = 3$. Tile dimensions must be integer multiples of $N = 3$. Arbitrary non-multiple dimensions require padding in software.
3. **Reference Clock Scope**: All throughput figures (MMAC/s) are derived assuming a reference clock of 100.0 MHz. Actual operating frequencies depend on FPGA device family, logic placement, and timing closure.
