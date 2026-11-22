# Core Systolic Array Architecture (Phase I)

This document describes the core 3×3 output-stationary systolic array matrix multiplication accelerator (`rtl/core/` and `rtl/interface/`). It represents the foundational project implementation documented in [the final combined Phase I + Phase II IEEE project report](../../report/report.pdf).

---

## 1. Design Configuration

| Parameter | Default / Scope | Notes |
| :--- | :--- | :--- |
| Array Dimension (`ARRAY_SIZE`, $N$) | `3` (default; `2` also verified in array tests) | Physical $N \times N$ PE mesh |
| Input Operand Width (`DATA_WIDTH`, $D$) | `8` bits, signed two's complement | Range $[-128, +127]$ |
| Internal Product Width | `16` bits ($2D$), signed | Full-precision combinational multiplication |
| Accumulator Width (`ACC_WIDTH`, $W_{\text{acc}}$) | `32` bits, signed | Sufficient bound $2D + \lceil \log_2 N \rceil = 18$ bits for $N=3$; 14 bits headroom |
| Dataflow | Output-stationary | Each PE holds one element $C[i][j]$ |
| Addressing | Row-major (`addr = row * N + col`) | Valid range $[0, N^2 - 1]$ |
| Clock & Reset | Single clock (`clk`), active-low async reset (`rst_n`) | Synchronous `clr` has priority over `en` |

---

## 2. Core and Interface Module Inventory

### Compute Core (`rtl/core/`)
- [`mac_unit.v`](../../rtl/core/mac_unit.v): Computes signed `a * b` combinationally at $2D$ bits and sign-extends into the 32-bit `acc` register. Asynchronous `rst_n` resets `acc` to zero; synchronous `clr` has priority over `en`; overflow wraps as two's-complement modulo $2^{32}$.
- [`processing_element.v`](../../rtl/core/processing_element.v): Instantiates one `mac_unit` alongside two $D$-bit registers (`a_out`, `b_out`) enabled by `compute_en`. The MAC consumes the current cycle's inputs (`a_in`, `b_in`) while forwarding registered copies eastward and southward on the next clock edge.
- [`pe_interconnect.v`](../../rtl/core/pe_interconnect.v): Pure combinational structural routing connecting `a_west` to column 0, `b_north` to row 0, and registered neighbor links across the $N \times N$ grid. Contains zero registers and zero combinational bypasses.
- [`systolic_array.v`](../../rtl/core/systolic_array.v): Instantiates the $N \times N$ grid of `processing_element` modules and `pe_interconnect` via `genvar` loops, broadcasting `clk`, `rst_n`, `compute_en`, and `array_clear`.
- [`control_fsm.v`](../../rtl/core/control_fsm.v): Four-state Moore FSM (`ST_IDLE`, `ST_LOAD`, `ST_COMPUTE`, `ST_DONE`) with one-hot state output flags.
- [`systolic_controller.v`](../../rtl/core/systolic_controller.v): Control-only unit (no data ports) containing a start rising-edge detector with post-reset lockout, load counter (`0 .. N-1`), compute counter (`0 .. 3N-3`), and control strobes (`load_en`, `load_idx`, `array_clear`, `compute_en`, `cycle_count`, `result_valid`).
- [`top_module.v`](../../rtl/core/top_module.v): Structural top-level integration connecting the compute core, controller, buffers, and host interface.

### Data Management & Host Interface (`rtl/interface/`)
- [`input_buffer.v`](../../rtl/interface/input_buffer.v): Stores $N \times N$ matrices `A` and `B` with per-element `written_a` / `written_b` flags (`matrices_ready` asserts only when all $2N^2$ elements are written). During `LOAD`, stages row `load_idx` of `A` and column `load_idx` of `B`; during `COMPUTE`, drives the skewed boundary vectors combinationally (driving zeros outside the valid skew window).
- [`output_buffer.v`](../../rtl/interface/output_buffer.v): Captures the $N^2$-element accumulator plane on the single-cycle `result_valid` strobe (`result_valid` takes priority over `clear`), maintains `result_available`, and provides synchronous indexed readback (`read_valid` pulses for 1 cycle on valid reads).
- [`matrix_interface.v`](../../rtl/interface/matrix_interface.v): Qualifies host requests: accepts writes only when `controller_idle` and address $< N^2$; accepts `host_start` rising edges only when `controller_idle && matrices_ready`, emitting `start_ack` + `out_buf_clear` (or `start_err` on invalid starts); suppresses held-high restarts and post-reset glitches.

---

## 3. Dataflow and Execution Schedule

During `COMPUTE` (cycle index $c \in [0, 3N-3]$), the input buffer drives:

$$a_{\text{west}}[i](c) = \begin{cases} A[i][c - i], & 0 \le c - i \le N - 1 \\ 0, & \text{otherwise} \end{cases}$$

$$b_{\text{north}}[j](c) = \begin{cases} B[c - j][j], & 0 \le c - j \le N - 1 \\ 0, & \text{otherwise} \end{cases}$$

Because each PE forwards operands by one hop per cycle, $A[i][k]$ and $B[k][j]$ meet at $\text{PE}(i, j)$ on cycle $c = i + j + k$. The final product at $\text{PE}(N-1, N-1)$ completes on cycle $3N - 3$.

For the verified $3 \times 3$ array ($N = 3$):
1. **Host Load ($2N^2 = 18$ beats):** Host writes 9 elements of `A` and 9 elements of `B` while idle.
2. **LOAD ($N = 3$ cycles):** Stages one row of `A` and one column of `B` per beat; asserts `array_clear` on beat $N - 1$.
3. **COMPUTE ($3N - 2 = 7$ cycles):** Streams skewed boundary operands across 7 cycles (the final 2 cycles drain the diagonal wavefront to $\text{PE}(2,2)$).
4. **DONE ($1$ cycle):** `result_valid` and `host_done` pulse; `output_buffer` captures all 9 accumulators.
5. **Host Readback ($N^2 = 9$ beats):** Host reads $C[0..8]$ sequentially.

Controller residency is $T_{\text{ctrl}} = 4N - 1 = 11$ cycles (`12` cycles at the host boundary from `start_ack` to `host_result_available` due to the interface start register).

---

## 4. Core Verification Summary (`make test-core`, `make demo`)

All core testbenches compute golden reference products independently via triple-loop software tasks and terminate with `$fatal` on any mismatch:

| Testbench | Target Module(s) | Coverage | Result |
| :--- | :--- | :--- | :--- |
| [`tb_mac_unit.v`](../../testbench/core/tb_mac_unit.v) | `mac_unit` | Async reset, `clr` priority over `en`, signed quadrants, `-128`/`+127` bounds, wraparound | **32 checks, 0 fail** |
| [`tb_processing_element.v`](../../testbench/core/tb_processing_element.v) | `processing_element` | East/south 1-cycle propagation, hold on `!compute_en`, reset | **26 checks, 0 fail** |
| [`tb_systolic_array.v`](../../testbench/core/tb_systolic_array.v) | `systolic_array`, `pe_interconnect` | 3×3 positive & mixed-sign GEMM, back-to-back, 2×2 parameterization | **77 checks, 0 fail** |
| [`tb_systolic_controller.v`](../../testbench/core/tb_systolic_controller.v) | `systolic_controller`, `control_fsm` | Cycle-accurate FSM transitions, `LOAD=3`, `COMPUTE=7`, start lockout | **PASS (94 cycles)** |
| [`tb_data_management.v`](../../testbench/interface/tb_data_management.v) | `input_buffer`, `output_buffer`, `matrix_interface` | Staging, skew timing, capture-over-clear priority, invalid access rejection | **80 checks, 0 fail** |
| [`tb_top_module.v`](../../testbench/core/tb_top_module.v) | `top_module` | Full host protocol, positive/signed/identity products, held-high start, mid-compute reset | **161 checks, 0 fail** |
| [`tb_prototype_demo.v`](../../testbench/core/tb_prototype_demo.v) | `top_module` | End-to-end 3×3 demonstration ($A \times B = C$ verification) | **PASS (9/9 elements)** |
