# Phase II – Task 4: Baseline Comparison and Quantitative Performance Evaluation

## 1. Executive Summary

This document presents the complete architectural specification, verification results, and quantitative performance evaluation for **Task 4: Baseline Comparison and Quantitative Performance Evaluation** of the **Systolic Array Matrix Multiplication Accelerator** project.

To objectively evaluate the architectural advantages and trade-offs of the parallel systolic array architecture, a synthesizable, cycle-accurate **Sequential Matrix Multiplication Baseline** (`phase2/baseline/sequential_gemm.v`) was designed, implemented, and verified. 

The evaluation benchmarks the sequential baseline against the three previously verified systolic accelerator configurations:
1. **Sequential Baseline (1-MAC)**: Genuinely sequential execution using a single MAC datapath, executing 1 multiply-accumulate per cycle ($T_{\text{comp}} = M^3$).
2. **Phase I Standalone Systolic Accelerator (`top_module`)**: $3 \times 3$ physical systolic array core (9 parallel PEs).
3. **Phase II Tiled Systolic Accelerator (`tiled_gemm_top`, $3 \times 3$)**: Single-tile execution through the matrix tiling controller.
4. **Phase II Tiled Systolic Accelerator (`tiled_gemm_top`, $6 \times 6$)**: Multi-tile execution decomposing a $6 \times 6$ matrix into 8 sequential $3 \times 3$ tile operations with on-chip inter-tile accumulation.

All metrics are experimentally measured using the dedicated self-checking testbench [`phase2/baseline/tb_sequential_gemm.v`](tb_sequential_gemm.v) and cross-validated against [`phase2/performance/tb_performance.v`](../performance/tb_performance.v).

---

## 2. Baseline Architecture & Sequential Nature

### 2.1 Why This Implementation Is Genuinely Sequential
A common pitfall when evaluating hardware accelerators is benchmarking against an unpipelined or multi-unit baseline that misrepresents sequential execution. In this project:
- **Single MAC Datapath**: The module contains **exactly one 16-bit multiplier and one 32-bit accumulator**. There are **no parallel processing elements**, no systolic interconnects, and no spatial wavefront pipelines.
- **Strictly Sequential Scheduling**: The triple nested loop $(i, j, k)$ for matrix multiplication:
  $$C[i][j] = \sum_{k=0}^{M-1} A[i][k] \times B[k][j]$$
  is evaluated one scalar product and accumulation per clock cycle.
- **No Concurrent Dot Products**: Each output element $C[i][j]$ is evaluated strictly one after another.

### 2.2 Datapath & Storage Architecture
- **Operand Storage**:
  - `mem_a[0:35]`: Flat array of 36 8-bit signed registers storing Matrix A in row-major order.
  - `mem_b[0:35]`: Flat array of 36 8-bit signed registers storing Matrix B in row-major order.
  - `mem_c[0:35]`: Flat array of 36 32-bit signed registers storing Result Matrix C.
- **Arithmetic Units**:
  - Combinational multiplier: Computes 16-bit signed product $P = A[i][k] \times B[k][j]$.
  - Sign-extension unit: Extends 16-bit signed product to 32 bits.
  - Accumulator register (`acc_reg`):
    - When $k = 0$: initializes with the first signed product ($P$).
    - When $k > 0$: accumulates $acc\_reg + P$.
    - When $k = M - 1$: registers the final dot product directly into `mem_c[i * M + j]`.

```
                  +---------------------------------------------------+
                  |            Sequential Baseline Datapath           |
                  |                                                   |
  mem_a [i*M+k] ->| [8-bit signed]                                    |
                  |       \                                           |
                  |        ( * ) ---> [16-bit Product] -> Sign Ext    |
                  |       /                                    \      |
  mem_b [k*M+j] ->| [8-bit signed]                              \     |
                  |                                              v    |
                  |                                            ( + )  |
                  |                                           /     \ |
                  |            +-----------------------------+       ||
                  |            |                                     ||
                  |            v                                     ||
                  |      [ k==0 ? Product : acc_reg + Product ]      ||
                  |            |                                     ||
                  |            +---------> [ acc_reg ] --------------+|
                  |            |                                      |
                  |            +-(k==M-1)-> [ mem_c[i*M+j] ]          |
                  +---------------------------------------------------+
```

---

## 3. Finite State Machine (FSM) & Schedule

The controller FSM operates with three distinct states:

```
        +-------------------------------------------------------+
        |                                                       |
        v                                                       |
  +-----------+  host_start && matrices_ready   +-----------+   |
  |  ST_IDLE  | ------------------------------> |  ST_COMP  |   |
  +-----------+                                 +-----------+   |
        ^                                             |         |
        |                                             | k==M-1  |
        |                                             | j==M-1  |
        |                                             | i==M-1  |
        |                                             v         |
        |         host_done (1-cycle pulse)     +-----------+   |
        +-------------------------------------- |  ST_DONE  |   |
                  (writes rejected)             +-----------+   |
```

1. **`ST_IDLE` (2'b00)**:
   - Host streams Matrix A and Matrix B through `host_write_en`, `host_write_is_b`, `host_write_addr`, `host_write_data`.
   - Host writes are accepted **only in `ST_IDLE`** (`state == ST_IDLE`).
   - Element write masks `written_a` and `written_b` track loading. When all $2 M^2$ elements are loaded, `matrices_ready` asserts.
   - Start qualification: When `host_start` asserts:
     - If dimension is invalid or `!matrices_ready`, emits single-cycle `start_err` pulse and stays idle.
     - If valid, emits single-cycle `start_ack` pulse, sets `host_busy = 1`, clears loop counters, and enters `ST_COMP`.

2. **`ST_COMP` (2'b01)**:
   - Loops through indices $i \in [0, M-1]$, $j \in [0, M-1]$, $k \in [0, M-1]$.
   - Each clock cycle executes exactly 1 multiply-accumulate operation.
   - Host writes are strictly rejected (`write_accepted = 0`, `host_write_ack = 0`) to prevent data corruption during computation.
   - Any concurrent `host_start` is rejected with `start_err = 1`.
   - On the final computation clock edge ($i = M-1, j = M-1, k = M-1$):
     - Registers the final dot product into `mem_c[M*M - 1]`.
     - Asserts `host_done = 1` (a one-cycle active-high completion pulse).
     - Asserts `host_result_available = 1` and deasserts `host_busy = 0`.
     - Transitions the FSM from `ST_COMP` to `ST_DONE`.

3. **`ST_DONE` (2'b10)**:
   - The FSM resides in `ST_DONE` for exactly one cycle while `host_done` remains high.
   - Host writes remain strictly rejected (`state != ST_IDLE`, `host_write_ack = 0`), ensuring write attempts cannot corrupt matrix storage before the FSM settles.
   - On the subsequent clock edge, `host_done` deasserts to 0 and the FSM returns to `ST_IDLE`.
   - Result data in `mem_c` remains valid and accessible for host readback as long as `host_result_available = 1`.

### Cycle-by-Cycle Computation Latency Formula
Because every cycle in `ST_COMP` executes 1 productive MAC with zero pipeline stalls or pipeline bubbles:
$$T_{\text{comp}} = M^3\text{ cycles}$$
- **$3 \times 3$ Matrix**: $3^3 = \mathbf{27\text{ cycles}}$.
- **$6 \times 6$ Matrix**: $6^3 = \mathbf{216\text{ cycles}}$.

---

## 4. Hardware Measurement Conventions

To maintain 100% scientific consistency with Task 1, Task 2, and Task 3:
1. **$T_{\text{load}}$ (Matrix Loading)**:
   - Number of clock cycles required to stream all elements of Matrix A and Matrix B over the single-beat host interface.
   - Formula: $T_{\text{load}} = 2 \times M^2$ cycles (18 cycles for $3 \times 3$, 72 cycles for $6 \times 6$).
2. **$T_{\text{comp}}$ (Computation Latency)**:
   - Measured from the clock edge where `start_ack = 1` until the clock edge where `host_done = 1`.
   - Baseline: Exactly $M^3$ cycles (27 cycles for $3 \times 3$, 216 cycles for $6 \times 6$).
3. **$T_{\text{read}}$ (Result Readback)**:
   - Streaming readback latency for all $M^2$ elements of Matrix C.
   - Formula: $T_{\text{read}} = M^2$ cycles (9 cycles for $3 \times 3$, 36 cycles for $6 \times 6$).
4. **$T_{\text{active}}$ (Active Phase Sum)**:
   $$T_{\text{active}} = T_{\text{load}} + T_{\text{comp}} + T_{\text{read}}$$
5. **$T_{\text{e2e}}$ (Seamless Host-Boundary Elapsed Latency)**:
   $$T_{\text{e2e}} = T_{\text{active}} + 2\text{ transition handoffs}$$
   (1 cycle write-to-start handoff + 1 cycle done-to-read handoff).

---

## 5. Quantitative Performance Comparison Results

The table below presents the cycle-accurate hardware measurements and derived throughput/efficiency metrics comparing the Sequential Baseline against the systolic accelerators:

| Metric | Sequential Baseline (3×3) | Standalone Systolic (3×3) | Tiled Systolic (3×3) | Sequential Baseline (6×6) | Tiled Systolic (6×6) |
| :--- | :---: | :---: | :---: | :---: | :---: |
| **Matrix Dimension ($M \times M$)** | **3 × 3** | **3 × 3** | **3 × 3** | **6 × 6** | **6 × 6** |
| **Total Elements ($M^2$)** | 9 | 9 | 9 | 36 | 36 |
| **Total MAC Operations ($M^3$)** | 27 | 27 | 27 | 216 | 216 |
| **Active Processing Elements ($N_{\text{PE}}$)** | **1** | **9** | **9** | **1** | **9** |
| **Input Loading Latency ($T_{\text{load}}$)** | **18 cycles** | **18 cycles** | **18 cycles** | **72 cycles** | **72 cycles** |
| **Compute Latency ($T_{\text{comp}}$)** | **27 cycles** | **11 cycles** | **15 cycles** | **216 cycles** | **113 cycles** |
| **Output Readback Latency ($T_{\text{read}}$)** | **9 cycles** | **9 cycles** | **9 cycles** | **36 cycles** | **36 cycles** |
| **Active Phase Sum ($T_{\text{active}}$)** | **54 cycles** | **38 cycles** | **42 cycles** | **324 cycles** | **221 cycles** |
| **Seamless E2E Latency ($T_{\text{e2e}}$)** | **56 cycles** | **40 cycles** | **44 cycles** | **326 cycles** | **223 cycles** |
| **Compute Throughput (MACs / cycle)** | **1.0000** | **2.4545** | **1.8000** | **1.0000** | **1.9115** |
| **Seamless E2E Throughput (MACs / cycle)**| **0.4821** | **0.6750** | **0.6136** | **0.6626** | **0.9686** |
| **Compute Throughput (@ 100 MHz reference)** | **100.00 MMAC/s**| **245.45 MMAC/s**| **180.00 MMAC/s**| **100.00 MMAC/s**| **191.15 MMAC/s**|
| **Seamless E2E Throughput (@ 100 MHz)** | **48.21 MMAC/s** | **67.50 MMAC/s** | **61.36 MMAC/s** | **66.26 MMAC/s** | **96.86 MMAC/s** |
| **Compute PE Utilisation ($\rho_{\text{comp}}$)**| **100.00 %** | **27.27 %** | **20.00 %** | **100.00 %** | **21.24 %** |
| **Seamless E2E PE Utilisation ($\rho_{\text{e2e}}$)**| **48.21 %** | **7.50 %** | **6.82 %** | **66.26 %** | **10.76 %** |
| **Compute Speedup vs. Sequential** | *1.0000x (Ref)* | **2.4545x** | **1.8000x** | *1.0000x (Ref)* | **1.9115x** |
| **Seamless E2E Speedup vs. Sequential** | *1.0000x (Ref)* | **1.4000x** | **1.2727x** | *1.0000x (Ref)* | **1.4619x** |
| **Compute Cycle Reduction ($\Delta_{\text{comp}}$)**| *0.00 %* | **59.26 %** | **44.44 %** | *0.00 %* | **47.69 %** |
| **E2E Cycle Reduction ($\Delta_{\text{e2e}}$)** | *0.00 %* | **28.57 %** | **21.43 %** | *0.00 %* | **31.60 %** |

---

## 6. Speedup and Efficiency Analysis

### 6.1 Compute Speedup Analysis
$$\text{Speedup}_{\text{comp}} = \frac{T_{\text{baseline\_comp}}}{T_{\text{systolic\_comp}}}$$

1. **$3 \times 3$ Standalone Core Speedup**:
   $$\text{Speedup}_{\text{comp}} = \frac{27}{11} \approx \mathbf{2.4545\times} \quad (59.26\%\text{ cycle reduction})$$
   - Matches the analytical prediction from Task 2 ($27 / 11 = 2.4545\times$) with zero error.
2. **$3 \times 3$ Tiled Architecture Speedup**:
   $$\text{Speedup}_{\text{comp}} = \frac{27}{15} = \mathbf{1.8000\times} \quad (44.44\%\text{ cycle reduction})$$
   - Reflects the 4-cycle FSM handshake and staging overhead of the tiling controller wrapper.
3. **$6 \times 6$ Tiled Architecture Speedup**:
   $$\text{Speedup}_{\text{comp}} = \frac{216}{113} \approx \mathbf{1.9115\times} \quad (47.69\%\text{ cycle reduction})$$
   - Multi-tile decomposition decomposes $6 \times 6$ GEMM into 8 tile operations ($8 \times 14\text{ cyc} + 1 = 113\text{ cyc}$).
   - The parallel systolic array finishes in 113 cycles what requires 216 consecutive cycles sequentially.

### 6.2 End-to-End Speedup & Transport Bottleneck (Amdahl's Law in Action)
While pure computation achieves a **$2.45\times$ speedup** for $3 \times 3$ and **$1.91\times$ speedup** for $6 \times 6$, the seamless end-to-end speedups are lower:
- $3 \times 3$ Standalone E2E Speedup: $\mathbf{1.4000\times}$
- $6 \times 6$ Tiled E2E Speedup: $\mathbf{1.4619\times}$

**Root Cause**:
Both the baseline and the systolic accelerator use identical single-word streaming host interfaces:
- For $3 \times 3$: $T_{\text{transport}} = 18\text{ (write)} + 9\text{ (read)} = 27\text{ cycles}$.
  - In the systolic accelerator, transport represents $27 / 38 \approx \mathbf{71.05\%}$ of total active cycles!
- For $6 \times 6$: $T_{\text{transport}} = 72\text{ (write)} + 36\text{ (read)} = 108\text{ cycles}$.
  - Transport represents $108 / 221 \approx \mathbf{48.87\%}$ of total active cycles.
As predicted by Amdahl's Law, when a significant fraction of execution time is bound to non-accelerated serialized I/O transport, increasing parallel compute units yields diminishing end-to-end returns unless high-bandwidth host burst/DMA mechanisms (developed in Task 3) are deployed.

### 6.3 Processing Element (PE) Utilisation Trade-Off
A key computer architecture insight emerges from comparing PE utilisation:
- **Sequential Baseline**: Achieves **100% compute PE utilisation** ($\rho = 1.0000$) because its single MAC unit is kept actively saturated on every clock cycle of computation.
- **Systolic Array**: Employs $9$ parallel PEs, achieving higher aggregate throughput ($245.45\text{ MMAC/s}$ vs. $100.00\text{ MMAC/s}$), but has lower spatial PE utilisation:
  - $3 \times 3$ Standalone: $\rho_{\text{comp}} = 27.27\%$
  - $6 \times 6$ Tiled: $\rho_{\text{comp}} = 21.24\%$

**Origin of Systolic Overhead**:
1. **Wavefront Skew**: PEs must wait for diagonal data wavefronts to enter and exit the 2D mesh (fill and drain time).
2. **Tile Scheduling Bubbles**: In multi-tile execution, inter-tile partial result capture and accumulator clear inject 3 cycles of overhead per tile.

---

## 7. Verification and Reproducibility

The verification testbench [`tb_sequential_gemm.v`](tb_sequential_gemm.v) is fully self-checking, deterministic, and non-terminating on silent failures.

### 7.1 Test Suites Covered
- **Suite 1: Power-on Reset & Default Signal States**: Confirms all status flags (`host_busy`, `host_done`, `start_ack`, `start_err`, `host_result_available`) and data buses initialize cleanly.
- **Suite 2: Protocol Boundary & Error Handling**:
  - Rejects unsupported dimensions (`cfg_matrix_dim` = 0, 1, 2, 4, 5, 7) via `start_err = 1`.
  - Rejects premature starts before matrices are fully loaded.
  - Rejects out-of-range write addresses and reads when result is not available.
  - **Targeted Write Rejection during `ST_COMP`**: Writes attempted during active computation fail to acknowledge (`host_write_ack == 0`) and do not modify matrix memory.
  - **Targeted Write Rejection during `ST_DONE`**: Writes attempted while the FSM is in `ST_DONE` (`host_busy == 0`, `host_done == 1`) are strictly rejected (`host_write_ack == 0`) without corrupting stored matrices.
  - **Clean Write Recovery in `ST_IDLE`**: After returning to `ST_IDLE`, valid matrix writes are properly acknowledged (`host_write_ack == 1`) and update storage correctly.
- **Suite 3: 3×3 GEMM (Positive Operands)**: Validates numerical correctness and verifies $T_{\text{comp}} = 27$ cycles exactly.
- **Suite 4: 3×3 Signed Boundary Operands**: Tests extreme values ($-128, +127, -1, 0, +1$) and confirms zero data-dependent timing jitter.
- **Suite 5: 6×6 GEMM (Positive Operands)**: Validates all 36 output elements and verifies $T_{\text{comp}} = 216$ cycles exactly.
- **Suite 6: 6×6 Signed Boundary Operands**: Validates signed accumulation across 6-term dot products.
- **Suite 7: Consecutive Back-to-Back Operations**: Confirms seamless multi-run execution without intermediate reset.
- **Suite 8: Asynchronous Reset During Active Computation**: Proves mid-flight reset returns cleanly to idle and recovers immediately.
- **Suite 9: Performance Comparison Table**: Automated reporting of measured latencies and speedups.

### 7.2 Execution and Structural Synthesis Commands

To compile and execute the sequential baseline testbench:
```bash
make test-baseline
```

To run baseline structural hierarchy, process lowering, and design rule checking via Yosys:
```bash
make synth-check-baseline
```

To run all Phase II test suites (tiled GEMM, performance analysis, burst interface, phase2 top, and sequential baseline):
```bash
make test-phase2
```

### 7.3 Verification Outcome
```
==================================================================
SEQUENTIAL BASELINE VERIFICATION SUMMARY:
  PASSED CHECKS : 636
  FAILED CHECKS : 0
==================================================================
RESULT: ALL SEQUENTIAL BASELINE TESTS AND MEASUREMENTS PASSED!
```

---

## 8. Limitations and Scope

1. **Clock Frequency Assumptions**: Throughput figures in MMAC/s assume a nominal reference frequency of $100.0\text{ MHz}$ ($10.0\text{ ns}$ clock period) for standardized comparison. Physical achievable clock frequencies depend on target FPGA synthesis and place-and-route constraints (addressed in Task 5).
2. **Structural Checking Scope**: The `synth-check-baseline` target executes non-technology-mapped RTL elaboration, process lowering (`proc`), and structural design-rule checks in Yosys. It validates hierarchy, latch-free sequential logic, and driver consistency, but does not perform FPGA technology mapping, placement, routing, or static timing analysis.
3. **Dimension Constraints**: The baseline hardware supports runtime configurations of $3 \times 3$ and $6 \times 6$ matrices, matching the supported configurations of the tiled systolic accelerator.
4. **Host Transport Coupling**: All latency comparisons in Section 5 utilize the standard element-by-element streaming protocol to guarantee fair evaluation under identical interface constraints.
