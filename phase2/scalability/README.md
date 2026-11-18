# Phase II Task 1 — Tiled Matrix Multiplication and Controller Extensions

## 1. Overview and Architectural Objective

Phase I established a verified $3 \times 3$ output-stationary systolic array matrix multiplication accelerator (`rtl/`). In Phase I, the matrix dimensions were strictly constrained to the physical array dimensions ($N = 3$), requiring exactly one matrix load and compute pass without inter-tile accumulation.

Task 1 extends the accelerator to support larger matrices ($M > N$) via **matrix tiling**, specifically demonstrating at least $6 \times 6$ matrix multiplication using the existing physical $3 \times 3$ systolic array. The implementation partitions larger matrices into $3 \times 3$ operand tiles, sequences tile multiplications through the unmodified Phase I systolic array and controller, preserves intermediate accumulator states, and accumulates partial results into complete output tiles.

All Phase II scalability modules are located under `phase2/scalability/`. All Phase I RTL modules remain 100% functional, unmodified, and regression-verified.

---

## 2. Directory Structure and Module Descriptions

```
phase2/scalability/
├── matrix_tiling_controller.v   # FSM sequencing tile execution, sub-controller triggering, and capture strobes
├── tiled_input_buffer.v         # Multi-tile operand memory, element tracking, and boundary operand skewing
├── partial_result_buffer.v      # Intermediate result storage, signed inter-tile accumulator, and readback logic
├── tiled_gemm_top.v             # Top-level integration module interfacing host, controllers, buffers, and array
├── tb_tiled_gemm.v              # Comprehensive self-checking testbench (1,143 checks, 9 test suites)
└── README.md                    # Technical documentation, cycle breakdown, and verification audit report
```

### Module Roles and Port Contracts

### 1. `matrix_tiling_controller.v`
- **Role:** High-level coordinator that manages matrix-level operation requests, generates tile index triples $(i, j, k)$, coordinates execution with the single-tile `systolic_controller`, and triggers accumulation into `partial_result_buffer`.
- **Key Ports:**
  - `host_start`, `matrices_ready`, `matrix_dim` ($3$ or $6$): Host control inputs.
  - `host_ready`, `host_busy`, `host_done`, `start_ack`, `start_err`: Host status handshake.
  - `sub_start`: 1-cycle launch strobe to Phase I `systolic_controller`.
  - `sub_done`, `sub_result_valid`: Completion flag from Phase I `systolic_controller`.
  - `tile_i[1:0]`, `tile_j[1:0]`, `tile_k[1:0]`: Active tile coordinates.
  - `accumulate_en`: High when $k > 0$, instructing the partial-result buffer to add the incoming tile product to stored intermediate results.
  - `capture_en`: Strobe pulse instructing `partial_result_buffer` to capture/accumulate on tile completion.
  - `out_buf_clear`: Invalidation strobe asserted on accepted new operation start.

### 2. `tiled_input_buffer.v`
- **Role:** Storage for full Matrix A and Matrix B (up to $MAX\_MATRIX\_DIM \times MAX\_MATRIX\_DIM = 36$ elements each). Tracks write status per element, drives `matrices_ready`, stages active tile rows/columns during the LOAD phase, and produces correctly skewed boundary inputs (`a_west`, `b_north`) during COMPUTE.
- **Key Features:**
  - Independent host write port with element-level linear addressing ($addr = row \times dim + col$).
  - Dimension enforcement: writes and `matrices_ready` gating strictly validate `matrix_dim`.
  - Staging registers loaded in 3 clock beats during sub-controller LOAD phase:
    - Beat $r$: row $r$ of tile $A(i, k)$ and column $r$ of tile $B(k, j)$.
  - Combinational skew generator matching Phase I systolic array interface.

### 3. `partial_result_buffer.v`
- **Role:** Result storage and inter-tile accumulator memory.
- **Key Features:**
  - Stores up to $36$ elements of $32$-bit signed accumulators ($MAX\_MATRIX\_DIM = 6$).
  - When $accumulate\_en = 0$ ($k = 0$): overwrites destination tile $C(i, j)$ with initial product.
  - When $accumulate\_en = 1$ ($k > 0$): computes $C(i, j)[r][c] \leftarrow C(i, j)[r][c] + P[r][c]$ using signed 32-bit addition.
  - Retains completed result matrix until cleared by new operation start or reset.
  - Synchronous indexed readback interface matching Phase I `output_buffer` handshake.

### 4. `tiled_gemm_top.v`
- **Role:** Integrates `matrix_tiling_controller`, `tiled_input_buffer`, `partial_result_buffer`, and reuses the Phase I `systolic_controller` and `systolic_array` unmodified.
- **Dimension Gating:** Intercepts `cfg_matrix_dim` and rejects unsupported dimensions at top level before writes or start handshakes can proceed.

---

## 3. Supported Matrix Dimensions and Constraints

### Supported Dimensions
The physical systolic array has fixed size $N = 3$. The tiled architecture natively supports:
1. **$3 \times 3$ Matrix Multiplication (`cfg_matrix_dim = 3`):**
   - Single-tile pass ($K_{\text{dim}} = 1$).
   - Exactly 1 tile operation evaluated: $C_{00} = A_{00} \times B_{00}$.
   - No inter-tile accumulation ($k=0$ only).
2. **$6 \times 6$ Matrix Multiplication (`cfg_matrix_dim = 6` or `cfg_matrix_dim = 0`):**
   - Four output tiles, two reduction steps ($K_{\text{dim}} = 2$).
   - Exactly 8 tile operations evaluated: $(0,0,0)$ through $(1,1,1)$.
   - Full inter-tile accumulation across reduction index $k \in \{0, 1\}$.
   - Dimension `0` defaults to $6$ for backwards compatibility.

### Unsupported Dimensions and Error Mechanism
- Any other value on `cfg_matrix_dim` (e.g., $1, 2, 4, 5,$ or $> 6$) is **strictly rejected**:
  - `dim_unsupported` asserts high within `tiled_gemm_top`.
  - Host writes are rejected: `host_write_ack` remains deasserted (`0`).
  - Input buffer gating blocks `matrices_ready` from asserting (`0`).
  - Start requests are rejected: `start_err` pulses high for 1 clock cycle, `start_ack` remains `0`.
  - The controller never leaves `ST_IDLE`, and no sub-controller operations are initiated.
  - Arbitrary dimensions are **never** silently treated as valid configurations.

---

## 4. Matrix Tiling Mathematical Formulation and Scheduling

For an $M \times M$ matrix multiplication evaluated on an $N \times N$ physical systolic array ($N = 3$):
$$K_{\text{dim}} = \frac{M}{N}$$

For $M = 6, N = 3$, $K_{\text{dim}} = 2$. Matrices $A$, $B$, and $C$ are partitioned into four $3 \times 3$ tiles:
$$A = \begin{bmatrix} A_{00} & A_{01} \\ A_{10} & A_{11} \end{bmatrix}, \quad B = \begin{bmatrix} B_{00} & B_{01} \\ B_{10} & B_{11} \end{bmatrix}, \quad C = \begin{bmatrix} C_{00} & C_{01} \\ C_{10} & C_{11} \end{bmatrix}$$

Output tile equations:
$$C_{00} = A_{00} \times B_{00} + A_{01} \times B_{10}$$
$$C_{01} = A_{00} \times B_{01} + A_{01} \times B_{11}$$
$$C_{10} = A_{10} \times B_{00} + A_{11} \times B_{10}$$
$$C_{11} = A_{10} \times B_{01} + A_{11} \times B_{11}$$

### Tile Execution Order and Traversal
Tile operations are sequenced with reduction loop $k$ innermost, column loop $j$ middle, and row loop $i$ outermost:
$$(i, j, k) \in \{0, 1\}^3$$

| Op Index | Coordinate $(i, j, k)$ | Operand A Tile | Operand B Tile | Accumulate En ($k > 0$) | Destination Output Tile Operation |
|:---:|:---:|:---:|:---:|:---:|:---|
| 0 | $(0, 0, 0)$ | $A_{00}$ | $B_{00}$ | 0 (Overwrite) | $C_{00} \leftarrow A_{00} B_{00}$ |
| 1 | $(0, 0, 1)$ | $A_{01}$ | $B_{10}$ | 1 (Accumulate) | $C_{00} \leftarrow C_{00} + A_{01} B_{10}$ |
| 2 | $(0, 1, 0)$ | $A_{00}$ | $B_{01}$ | 0 (Overwrite) | $C_{01} \leftarrow A_{00} B_{01}$ |
| 3 | $(0, 1, 1)$ | $A_{01}$ | $B_{11}$ | 1 (Accumulate) | $C_{01} \leftarrow C_{01} + A_{01} B_{11}$ |
| 4 | $(1, 0, 0)$ | $A_{10}$ | $B_{00}$ | 0 (Overwrite) | $C_{10} \leftarrow A_{10} B_{00}$ |
| 5 | $(1, 0, 1)$ | $A_{11}$ | $B_{10}$ | 1 (Accumulate) | $C_{10} \leftarrow C_{10} + A_{11} B_{10}$ |
| 6 | $(1, 1, 0)$ | $A_{10}$ | $B_{01}$ | 0 (Overwrite) | $C_{11} \leftarrow A_{10} B_{01}$ |
| 7 | $(1, 1, 1)$ | $A_{11}$ | $B_{11}$ | 1 (Accumulate) | $C_{11} \leftarrow C_{11} + A_{11} B_{11}$ |

The testbench monitors every coordinate transition directly on hardware events to verify zero missing, repeated, or out-of-order tiles.

---

## 5. Tiling Controller Finite State Machine (FSM)

The controller sequences tile operations via a 6-state FSM:

```
[ST_IDLE] --(host_start & matrices_ready)--> [ST_TILE_START]
     ^                                              |
     |                                          (sub_start = 1)
     |                                              v
 [ST_DONE] <--(all tiles complete)-- [ST_TILE_NEXT] <--- [ST_TILE_EXEC]
                                            ^               | (sub_done)
                                            |               v
                                            +------ [ST_TILE_CAPTURE]
```

1. **`ST_IDLE`:** Waits for `host_start`. On valid start with `matrices_ready`, asserts `start_ack` and `out_buf_clear`, initializes $(i=0, j=0, k=0)$, and transitions to `ST_TILE_START`.
2. **`ST_TILE_START`:** Emits 1-cycle `sub_start` pulse to `systolic_controller` to launch Tile 0.
3. **`ST_TILE_EXEC`:** Sub-controller runs LOAD ($N=3$ cycles), COMPUTE ($3N-2=7$ cycles), and DONE ($1$ cycle). Upon `sub_done`, asserts `capture_en` to `partial_result_buffer` and transitions to `ST_TILE_CAPTURE`.
4. **`ST_TILE_CAPTURE`:** Guarantees that result data from `systolic_array` has been latched/accumulated into `partial_result_buffer` before any subsequent operation begins.
5. **`ST_TILE_NEXT`:** Advances $(k \to j \to i)$. If more tiles remain, asserts `sub_start <= 1'b1` directly and transitions back to `ST_TILE_EXEC` (achieving exact 14-cycle scheduling spacing). If all 8 tiles are complete, transitions to `ST_DONE`.
6. **`ST_DONE`:** Asserts `host_done` (1-cycle pulse) and `all_tiles_done`, setting `result_available = 1` for host readback.

---

## 6. Performance and Exact Cycle Analysis

### Cycle Count Definitions and Measurement Conventions

To ensure absolute precision, cycle measurements are anchored to specific hardware interface events:

1. **Per-Tile Scheduling Interval ($T_{\text{tile}} = 14$ cycles):**
   - **Start Event:** Rising edge of `dut.sub_start` for Tile $n$.
   - **Stop Event:** Rising edge of `dut.sub_start` for Tile $n+1$.
   - **Constituents:**
     - Sub-controller / Systolic array execution: $3\text{ (LOAD)} + 7\text{ (COMPUTE)} + 1\text{ (DONE)} = 11\text{ cycles}$.
     - Capture / Accumulate strobe state (`ST_TILE_CAPTURE`): $1\text{ cycle}$.
     - Next coordinate update & launch state (`ST_TILE_NEXT`): $1\text{ cycle}$.
     - Handshake synchronization: $1\text{ cycle}$.
     - Total interval: $11 + 1 + 1 + 1 = \mathbf{14\text{ cycles}}$.

2. **Total Tiled Compute Latency ($T_{\text{compute}} = 113$ cycles):**
   - **Start Event:** Positive clock edge where `host_start` is accepted, asserting `start_ack = 1` and launching Tile 0 (`sub_start = 1`). In the testbench cycle tracker, this occurs at Cycle 1.
   - **Stop Event:** Positive clock edge where `host_done` asserts high upon entering `ST_DONE`. In the testbench cycle tracker, this occurs at Cycle 114.
   - **Duration:** $114 - 1 = \mathbf{113\text{ cycles}}$.
   - **Constituents:** $8\text{ tiles} \times 14\text{ cycles/tile} + 1\text{ cycle in ST\_DONE} = 112 + 1 = \mathbf{113\text{ cycles}}$.

3. **Complete End-to-End Operation ($T_{\text{total}} = 221$ active cycles / $223$ boundary cycles):**
   - **Documented Active Cycles (221 cycles):**
     - Host Matrix Write: $2 \times M^2 = 2 \times 36 = \mathbf{72\text{ clock beats}}$ (consecutive streaming writes without wait states).
     - Compute Phase: $\mathbf{113\text{ clock cycles}}$ from start acknowledgment to `host_done`.
     - Host Matrix Read: $M^2 = 1 \times 36 = \mathbf{36\text{ clock beats}}$ (consecutive streaming reads).
     - Sum of Active Phases: $72 + 113 + 36 = \mathbf{221\text{ cycles}}$.
   - **Testbench Host-Boundary Measurement (223 cycles):**
     - **Start Event:** Cycle 0 (first write beat: `host_write_en = 1`, `host_write_addr = 0` for Matrix A).
     - **Stop Event:** Cycle 223 (final read beat: `host_read_valid = 1` for element 35 of Matrix C).
     - Measured interval: $223 - 0 = \mathbf{223\text{ cycles}}$.
     - **Difference Explanation:** Exactly 2 cycles of host protocol boundary transitions:
       - 1 cycle between final matrix write completion and `host_start` assertion.
       - 1 cycle between `host_done` pulse deassertion and readback enable assertion.

### Analytical Formulation vs. Simulation Results Table

| Phase / Metric | Analytical Formula | Analytical Value ($6 \times 6$) | Simulation Result ($6 \times 6$) | Status |
|:---|:---|:---:|:---:|:---:|
| Number of Tile Operations ($N_{\text{tiles}}$) | $(M/N)^3 = (6/3)^3$ | **8 tiles** | **8 tiles** | Verified |
| Physical Array Residency per Tile ($T_{\text{array}}$) | $N + (3N - 2) + 1 = 4N - 1$ | **11 cycles** | **11 cycles** | Verified |
| Scheduling Overhead per Tile ($T_{\text{sched}}$) | $\text{CAPTURE}(1) + \text{NEXT}(1) + \text{SYNC}(1)$ | **3 cycles** | **3 cycles** | Verified |
| Interval Between Successive Tile Launches | $T_{\text{array}} + T_{\text{sched}}$ | **14 cycles** | **14 cycles** | Verified |
| Total Compute Latency ($T_{\text{compute}}$) | $N_{\text{tiles}} \times 14 + \text{DONE}(1)$ | **113 cycles** | **113 cycles** | Verified |
| Host Streaming Write Beats ($2 \times M^2$) | $2 \times 36$ elements | **72 cycles** | **72 cycles** | Verified |
| Host Streaming Read Beats ($M^2$) | $1 \times 36$ elements | **36 cycles** | **36 cycles** | Verified |
| Active Phase Sum ($T_{\text{active}}$) | $T_{\text{write}} + T_{\text{compute}} + T_{\text{read}}$ | **221 cycles** | **221 cycles** | Verified |
| End-to-End Elapsed Boundary Time ($T_{\text{boundary}}$) | $T_{\text{active}} + T_{\text{handshake}}$ | **223 cycles** | **223 cycles** | Verified |

---

## 7. Verification Summary and Audit Evidence

### Testbench Architecture (`phase2/scalability/tb_tiled_gemm.v`)
- **Zero Silent Failures:** Every assertion routes through the `check` task. Any failing condition displays the failure timestamp, logs an error message, and immediately invokes `$fatal(1, ...)` terminating the simulation with exit code `1`.
- **Deliberate Failure Confirmation:** Confirmed that intentional check mutations trigger `$fatal(1)` and produce a non-zero exit code (`1`) under Icarus Verilog `vvp`.
- **Pure Software Reference:** Reference calculations are performed independently in software tasks using nested loops. No internal DUT state or signals are used to generate golden matrices.
- **Actual Accelerator Output Readback:** In Test 2, `display_matrix_6x6` reads values from `actual_c` (captured sequentially from the DUT output bus `host_read_data`) rather than printing golden reference values.

### Test Execution Results

```
==================================================================
TILED GEMM TEST SUMMARY:
  PASSED CHECKS : 1143
  FAILED CHECKS : 0
==================================================================
RESULT: ALL TILED GEMM TESTS PASSED SUCCESSFULLY!
```

### Breakdown of Test Suites

| Suite | Description | Key Verifications | Checks Passed | Status |
|:---:|:---|:---|:---:|:---:|
| **Test 1** | $3 \times 3$ Multiplication via Tiled Top | Verifies single-tile mode (`cfg_matrix_dim = 3`), correct mapping, software reference equivalence | 20 | **PASS** |
| **Test 2** | $6 \times 6$ Positive-Valued Multiplication | Verifies all 36 elements, exact 14-cycle per-tile interval, exact 113-cycle compute latency, monitors tile order $(0,0,0) \to (1,1,1)$, displays actual readback matrix | 64 | **PASS** |
| **Test 3** | $6 \times 6$ Mixed-Sign Multiplication | Verifies signed boundary operands ($-128, +127, -1, 0$), sign extension, no saturation | 56 | **PASS** |
| **Test 4** | Signed Partial-Result Accumulation | Verifies positive and negative tile partial sum cancellation ($+50 + (-30) = +20$) | 20 | **PASS** |
| **Test 5** | Unsupported Dimension Rejection | Tests invalid dimensions (e.g., 5, 4); verifies write rejection (`host_write_ack = 0`), gating of `matrices_ready`, assertion of `start_err = 1`, and suppression of `start_ack` | 13 | **PASS** |
| **Test 6** | Asynchronous Reset Recovery | Asserts `rst_n = 0` mid-flight; verifies clean abort to `ST_IDLE`, deassertion of busy flags, and flawless second-run recovery | 62 | **PASS** |
| **Test 7** | Back-to-Back Operations | Runs two full $6 \times 6$ matrix operations without reset; verifies buffer clear on new start and independent correctness | 80 | **PASS** |
| **Test 8** | Host Interface Protocol Guarantees | Verifies incomplete matrix rejection, held-high start suppression, busy write rejection, and out-of-range read address gating | 772 | **PASS** |
| **Test 9** | Exact 221-Cycle Complete Operation | Validates exact streaming write (72 beats), compute (113 cycles), and streaming read (36 beats), within 221–223 cycle envelope | 56 | **PASS** |
| **Total** | **All 9 Verification Suites** | **Comprehensive Functional & Protocol Coverage** | **1,143** | **PASS** |

### Verified $6 \times 6$ Sample Matrix Multiplication Output

Input Matrix A:
```
  [ 1,  2,  3,  4,  5,  6 ]
  [ 7,  1,  2,  3,  4,  5 ]
  [ 6,  7,  1,  2,  3,  4 ]
  [ 5,  6,  7,  1,  2,  3 ]
  [ 4,  5,  6,  7,  1,  2 ]
  [ 3,  4,  5,  6,  7,  1 ]
```

Input Matrix B:
```
  [ 1,  4,  2,  5,  3,  1 ]
  [ 4,  2,  5,  3,  1,  4 ]
  [ 2,  5,  3,  1,  4,  2 ]
  [ 5,  3,  1,  4,  2,  5 ]
  [ 3,  1,  4,  2,  5,  3 ]
  [ 1,  4,  2,  5,  3,  1 ]
```

Result Matrix C ($C = A \times B$ read back from accelerator `actual_c`):
```
  [ 56,  64,  57,  70,  68,  56 ]
  [ 47,  73,  54,  85,  71,  47 ]
  [ 59,  68,  72,  86,  60,  59 ]
  [ 57,  84,  76,  73,  70,  57 ]
  [ 76,  86,  66,  81,  66,  76 ]
  [ 81,  74,  77,  75,  83,  81 ]
```
Every element read through the host interface identically matches the independent reference.

---

## 8. Build, Simulation, and Synthesis Commands

### Compilation and Simulation Targets

1. **Clean build artifacts:**
   ```bash
   make clean
   ```

2. **Run Tiled Matrix Multiplication Testbench (Phase II):**
   ```bash
   make test-tiled
   ```
   Compiles with `iverilog -g2012 -Wall` and runs via `vvp`.

3. **Check Structural Synthesis of Tiled Top (Phase II):**
   ```bash
   make synth-check-tiled
   ```
   Runs structural hierarchy elaboration and cell linting using Yosys (`yosys -Q`). Verifies zero latches, unresolved modules, or multi-driver conflicts.

4. **Run Phase I Baseline Regression:**
   ```bash
   make test
   ```
   Executes all 6 Phase I unit testbenches (MAC, PE, interconnect, systolic array, controller, and top).

5. **Check Phase I Baseline Synthesis:**
   ```bash
   make synth-check
   ```
