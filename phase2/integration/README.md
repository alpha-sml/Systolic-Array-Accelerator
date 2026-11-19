# Phase II Task 3 — System Integration & Top-Level Architecture

## 1. Executive Summary

`phase2/integration/phase2_top_module.v` is the top-level integration module for the Phase II Scalable Systolic-Array Accelerator. It integrates:
- The **High-Bandwidth Burst Host Interface** (`phase2/interface/burst_matrix_interface.v`),
- The **Multi-Tile Input Buffer** (`phase2/scalability/tiled_input_buffer.v`),
- The **Matrix Tiling Controller** (`phase2/scalability/matrix_tiling_controller.v`),
- The **Partial Result Accumulator Buffer** (`phase2/scalability/partial_result_buffer.v`),
- And reuses the unmodified, golden Phase I **Systolic Controller** (`rtl/systolic_controller.v`) and **Systolic Array Core** (`rtl/systolic_array.v`).

The resulting architecture supports both single-tile ($3 \times 3$) and multi-tile ($6 \times 6$) General Matrix Multiplication (GEMM) using 8-bit signed two's-complement inputs and 32-bit signed accumulators, with high-bandwidth packed-word data transfers, active backpressure, comprehensive error detection, and skid-buffered result readback.

---

## 2. Top-Level System Hierarchy & Interconnect

```
========================================================================================================
                                      PHASE 2 TOP-LEVEL SYSTEM HIERARCHY
========================================================================================================

                                        HOST INTERFACE (32-bit Bus)
                                                    │
                 ┌──────────────────────────────────┴──────────────────────────────────┐
                 │                                                                     │
                 ▼                                                                     ▼
     [Burst Write Channel]                                                 [Burst Read Channel]
     burst_write_{req, packed,                                             burst_read_{req, addr,
                  addr, len, data}                                                     len, ready}
                 │                                                                     ▲
                 ▼                                                                     │
       ┌───────────────────┐               Control Handshake             ┌───────────────────┐
       │                   │ ───────────── (host_start / busy) ────────> │                   │
       │                   │                                             │                   │
       │                   │ <──────────── (matrices_ready) ──────────── │                   │
       │                   │                                             │                   │
       │                   │ ─────── res_read_{en, addr} ──────────────> │                   │
       │                   │ <────── res_read_{data, valid} ──────────── │                   │
       │                   │                                             │                   │
       │   burst_matrix_   │                                             │  burst_matrix_    │
       │     interface     │                                             │    interface      │
       │  (Write Engine &  │                                             │  (2-Stage Skid    │
       │  Packed Unpacker) │                                             │  Buffer Readback) │
       └─────────┬─────────┘                                             └───────────────────┘
                 │                                                                 ▲
        buf_write_{en, is_b,                                                       │
                   addr, data}                                                c_read_{data,
                 │                                                                    valid}
                 ▼                                                                 │
       ┌───────────────────┐                                             ┌───────────────────┐
       │                   │                                             │                   │
       │ tiled_input_buffer│                                             │  partial_result_  │
       │                   │                                             │      buffer       │
       │ (Matrix A & B RAM,│                                             │ (Intermediate Sum │
       │ Skew Generation)  │                                             │  & Inter-Tile Acc)│
       └─────────┬─────────┘                                             └─────────▲─────────┘
                 │                                                                 │
           {a_west, b_north}                                                  acc_out[9]
                 │                                                                 │
                 ▼                                                                 │
       ┌───────────────────────────────────────────────────────────────────────────┴─────────┐
       │                                                                                     │
       │                                 systolic_array                                      │
       │                      (3x3 Output-Stationary Array Core)                             │
       │                                 9 x MAC / PE                                        │
       │                                                                                     │
       └──────────────────────────────────────────▲──────────────────────────────────────────┘
                                                  │
                                            {compute_en,
                                             array_clear}
                                                  │
       ┌──────────────────────────────────────────┴──────────────────────────────────────────┐
       │                                                                                     │
       │                               systolic_controller                                   │
       │                          (Phase 1 Timing Engine: 7-state FSM)                       │
       │                                                                                     │
       └──────────────────────────────────────────▲──────────────────────────────────────────┘
                                                  │
                                          sub_start / sub_done
                                                  │
       ┌──────────────────────────────────────────┴──────────────────────────────────────────┐
       │                                                                                     │
       │                             matrix_tiling_controller                                │
       │                    (Tile Triple (i, j, k) Generator & Coordinator)                  │
       │                                                                                     │
       └─────────────────────────────────────────────────────────────────────────────────────┘
========================================================================================================
```

---

## 3. Data Flow & Operational Lifecycle

### 3.1 Stage 1: Host Burst Matrix Ingestion
1. The host sets `cfg_matrix_dim` ($3$ or $6$).
2. The host initiates a burst write for Matrix A by asserting `burst_write_req = 1`, `burst_write_is_b = 0`, `burst_write_packed = 1`, `burst_write_len = 36`, and streaming 9 packed 32-bit words (each carrying four 8-bit elements).
3. The interface asserts `burst_write_ready = 1` for each word beat, writes sub-word 0 combinationally to `tiled_input_buffer` with zero pipeline bubbles, asserts active backpressure (`burst_write_ready = 0`) for 3 clock cycles while draining sub-words 1, 2, and 3, and pulses `burst_write_ack` for each element.
4. Matrix B is loaded identically with `burst_write_is_b = 1`.
5. Upon the final element write of Matrix B, `tiled_input_buffer` asserts `matrices_ready = 1`.

### 3.2 Stage 2: Host Launch & Lockout
1. The host pulses `host_start = 1`.
2. `burst_matrix_interface` verifies `matrices_ready == 1` and `ctrl_idle == 1`, generates a 1-cycle launch strobe `ctrl_start`, pulses `start_ack = 1`, pulses `out_buf_clear = 1` to invalidate stale results in `partial_result_buffer`, and asserts `host_busy = 1`.
3. If `host_start` is asserted while matrices are incomplete or when unsupported dimensions are selected, the launch is rejected with `start_err = 1`.

### 3.3 Stage 3: Tiled Execution & Partial Accumulation Pipeline
1. `matrix_tiling_controller` sequences tile coordinate triples $(i, j, k)$:
   - For $3 \times 3$: exactly 1 tile pass $(0, 0, 0)$.
   - For $6 \times 6$: 8 tile passes $(0,0,0), (0,0,1), (0,1,0), (0,1,1), (1,0,0), (1,0,1), (1,1,0), (1,1,1)$.
2. For each tile pass:
   - `matrix_tiling_controller` pulses `sub_start` to `systolic_controller`.
   - `tiled_input_buffer` stages row $r$ of tile $A(i, k)$ and column $r$ of tile $B(k, j)$ during the 3-cycle LOAD phase.
   - `tiled_input_buffer` streams skewed operands (`a_west`, `b_north`) across 7 compute cycles into `systolic_array`.
   - Upon tile completion (`sub_done`), `matrix_tiling_controller` pulses `capture_en`.
   - `partial_result_buffer` captures the $3 \times 3$ outputs: if $k = 0$, the tile product is stored directly; if $k > 0$ (`accumulate_en = 1`), the tile product is accumulated into the stored partial sum using signed 32-bit addition.
3. When all tiles complete, `matrix_tiling_controller` pulses `host_done` for 1 cycle.

### 3.4 Stage 4: Result Readback & Skid-Buffered Streaming
1. On the cycle following `host_done` (Done-to-Read handoff), `host_result_available` asserts high and `host_busy` drops to 0.
2. The host initiates result readback by asserting `burst_read_req = 1`, `burst_read_addr = 0`, `burst_read_len = 36`, and `burst_read_ready = 1`.
3. The interface issues synchronous read addresses to `partial_result_buffer` and delivers 32-bit signed accumulator elements continuously (`burst_read_valid = 1`).
4. If the host temporarily pauses reading (`burst_read_ready = 0`), the integrated **2-stage skid buffer** captures both the active output element and the in-flight RAM output, pausing memory reads with zero drops and zero bubbles.
5. On the 36th element, `burst_read_done` pulses for 1 cycle, concluding the operation.

---

## 4. Architectural Contracts & Cross-Phase Guarantees

| Contract | Implementation | Guarantee |
|:---|:---|:---|
| **Phase I Immutability** | `rtl/` modules instantiated unmodified | 100% Phase I baseline preserved |
| **Arithmetic Integrity** | Signed 8-bit inputs $\times$ 32-bit accumulators | No premature saturation or truncation |
| **Reset Semantics** | Active-low asynchronous `rst_n` | Immediate clearing of all registers, buffers, and FSMs |
| **Zero-Bubble Write** | Combinational `buf_write_en` decoding | 0 dead cycles between host valid beat and memory latch |
| **Done-to-Read Handoff**| `host_done` at $T$, `result_available` at $T+1$ | Synchronous handoff without race conditions |
| **Start Lockout** | Sticky edge detection and `matrices_ready` gating | Immune to held-high starts and post-reset spikes |
| **Lossless Skid Buffer** | 2-stage holding registers (`r_holding_data`, `r_skid_data`) | Zero dropped beats during host backpressure |

---

## 5. Verification Strategy & Testbench Coverage

`phase2/integration/tb_phase2_top.v` executes an exhaustive, self-checking verification suite (808 checks, 8 test suites) comparing hardware outputs against an independent software GEMM reference model ($C_{\text{golden}} = A \times B$):

```
========================================================================================================
Suite 1: System Reset & Idle State Verification
         - Verifies default flags: host_ready=0, host_busy=0, host_done=0, matrices_ready=0.
         - Validates burst_write_ready asserts immediately upon reset release.
--------------------------------------------------------------------------------------------------------
Suite 2: 3x3 Single-Tile GEMM via Streaming Bursts
         - Streams 9 elements of Matrix A and 9 elements of Matrix B.
         - Validates start_ack, execution cycle counts, host_done, and 9-element readback.
         - 100% match with golden model.
--------------------------------------------------------------------------------------------------------
Suite 3: 6x6 Multi-Tile GEMM via 32-Bit Packed Bursts
         - Loads 36 elements per matrix using 9 packed 32-bit words (4 elements/word).
         - Validates 4-sub-word active backpressure on every word beat.
         - Executes complete 8-tile accumulation sequence.
         - Reads back all 36 accumulator values against reference model.
--------------------------------------------------------------------------------------------------------
Suite 4: 6x6 Tiled GEMM with Extreme Signed Boundaries
         - Boundary operands: -128, +127, zero, and alternating positive/negative values.
         - Stresses signed accumulator dynamic range and inter-tile additive cancellation.
         - 100% bit-exact match with golden reference.
--------------------------------------------------------------------------------------------------------
Suite 5: Back-to-Back Operations Without Reset
         - Executes a 6x6 GEMM, followed immediately by another 6x6 GEMM without pulsing rst_n.
         - Verifies result buffer auto-invalidation on accepted start and no stale data leakage.
--------------------------------------------------------------------------------------------------------
Suite 6: Host Error Detection & Rejection Qualification
         - Verifies rejection of incomplete-matrix starts (matrices_ready = 0).
         - Verifies rejection of writes while accelerator is busy (ERR_BUSY).
         - Verifies rejection of out-of-range addresses (ERR_ADDR) and lengths (ERR_LEN).
         - Verifies rejection of unsupported dimensions (ERR_DIM).
--------------------------------------------------------------------------------------------------------
Suite 7: Asynchronous Reset Mid-Compute & System Recovery
         - Pulses rst_n = 0 mid-way through 6x6 computation.
         - Verifies immediate return to idle, clearing of host_busy and matrices_ready.
         - Reloads fresh matrices and executes a full 6x6 GEMM to verify flawless recovery.
--------------------------------------------------------------------------------------------------------
Suite 8: Result Readback with Host Backpressure
         - Reads back all 36 elements of a 6x6 result matrix.
         - Deasserts burst_read_ready = 0 for 2-cycle pauses at elements 8, 18, and 28.
         - Validates 2-stage skid buffer: data remains stable with zero dropped or duplicate beats.
========================================================================================================
```

### Verification Results Summary
```text
==================================================================
PHASE 2 SYSTEM INTEGRATION TEST SUMMARY:
  PASSED CHECKS : 808
  FAILED CHECKS : 0
==================================================================
RESULT: ALL PHASE 2 INTEGRATION TESTS PASSED SUCCESSFULLY!
```

---

## 6. Synthesis and Gate-Level Structural Verification

The top-level hierarchy was elaborated and structurally checked using **Yosys Open Synthesis Suite**:
- Command: `hierarchy -check -top phase2_top_module; proc; opt; check`
- **Results:**
  - `Found and reported 0 problems.`
  - **Zero inferred latches:** All control logic, FSMs, and buffers are fully synchronous.
  - **Zero undriven nets or multi-driver conflicts:** All internal buses and port mappings are 100% resolved.

---

## 7. Execution Commands

```bash
# Run all Phase 2 tests (Task 1 tiled + Task 2 perf + Task 3 burst IF + Task 3 top)
make test-phase2

# Run Phase 2 top integration testbench specifically
make test-phase2-top

# Run Yosys structural synthesis check on phase2_top_module
make synth-check-phase2-top

# Run full project regression (Phase 1 + Phase 2)
make test
make test-phase2
```

