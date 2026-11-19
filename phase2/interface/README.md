# Phase II Task 3 — High-Bandwidth Host Burst Interface

## 1. Overview and Architectural Motivation

In Phase I and early Phase II designs, host data loading was restricted to single element-by-element transactions over an 8-bit bus. Loading an entire $6 \times 6$ GEMM operation ($36$ elements of Matrix A and $36$ elements of Matrix B, totaling $72$ elements) required $72$ distinct individual write transactions. Each element transfer required an independent handshake, consuming significant host bus bandwidth and preventing multi-element DMA-style burst transfers.

The **High-Bandwidth Burst Host Interface** (`phase2/interface/burst_matrix_interface.v`) addresses this throughput limitation by providing:
1. **Multi-Beat Streaming Bursts:** The host specifies a starting linear address and burst length ($L$), continuously streaming data beats without re-issuing address or command signals on every beat.
2. **32-Bit Packed-Word Transfers:** The host transfers four 8-bit matrix elements simultaneously within each 32-bit word (`[31:24]`, `[23:16]`, `[15:8]`, `[7:0]`), quadrupling bus data payload capacity.
3. **Active Backpressure & Skid-Buffer Readback:** The interface provides full bidirectional flow control:
   - For writes, `burst_write_ready` indicates interface readiness and asserts backpressure while unpacking words.
   - For reads, an integrated 2-stage skid buffer guarantees lossless result streaming and decoupled host pauses without bubbling or dropping data from synchronous memory.
4. **Comprehensive Error Qualification:** Invalid addresses, burst lengths that exceed matrix boundaries, busy-state write attempts, and unsupported dimensions are detected and flagged immediately with distinct error codes.
5. **Start Lockout & Qualification:** Launch requests (`host_start`) are edge-detected and gated by matrix readiness, preventing premature launches, held-high auto-restarts, or post-reset race conditions.

---

## 2. Directory Structure and Files

```
phase2/interface/
├── burst_matrix_interface.v   # High-bandwidth burst controller RTL
├── tb_burst_interface.v       # Self-checking unit testbench (12 test suites, 215 checks)
└── README.md                  # Protocol specification and architectural documentation
```

---

## 3. Signal Specification & Interface Definitions

### 3.1 Parameter Summary

| Parameter | Default | Description |
|:---|:---:|:---|
| `ARRAY_SIZE` | `3` | Physical systolic array dimension ($N = 3$) |
| `MAX_MATRIX_SIZE` | `6` | Maximum matrix dimension supported ($M = 6$) |
| `DATA_WIDTH` | `8` | Bit width of each signed matrix element |
| `ACC_WIDTH` | `32` | Bit width of signed accumulator / result element |
| `WORDS_PER_BEAT` | `4` | Elements packed per 32-bit word beat |
| `BUS_DATA_WIDTH` | `32` | Width of host data bus (`WORDS_PER_BEAT * DATA_WIDTH`) |
| `ADDR_WIDTH` | `6` | Linear element address width ($2^6 = 64 \ge 36$) |
| `BURST_LEN_WIDTH` | `7` | Burst length width ($2^7 = 128 \ge 36$) |

### 3.2 Host Signal Definitions

| Signal | Width | Direction | Protocol / Description |
|:---|:---:|:---:|:---|
| `clk` | 1 | Input | System clock (nominal 100 MHz) |
| `rst_n` | 1 | Input | Asynchronous active-low reset |
| `cfg_matrix_dim` | 4 | Input | Configured dimension ($3$ for $3 \times 3$, $6$ for $6 \times 6$) |
| **Burst Write Channel** | | | |
| `burst_write_req` | 1 | Input | Strobe initiating a burst write transaction |
| `burst_write_is_b` | 1 | Input | Matrix target selection: `0` for Matrix A, `1` for Matrix B |
| `burst_write_packed` | 1 | Input | Mode: `0` = streaming 8-bit beats, `1` = packed 32-bit words |
| `burst_write_addr` | `ADDR_WIDTH` | Input | Starting linear base element address ($0 \le \text{addr} < M^2$) |
| `burst_write_len` | `BURST_LEN_WIDTH` | Input | Total matrix elements in burst ($1 \le L \le M^2$) |
| `burst_write_valid` | 1 | Input | Host payload valid strobe |
| `burst_write_data` | `BUS_DATA_WIDTH` | Input | Host data payload (lower 8 bits in streaming mode; 4 packed elements in packed mode) |
| `burst_write_ready` | 1 | Output | Interface flow control: `1` = ready to accept beat, `0` = backpressure |
| `burst_write_ack` | 1 | Output | 1-cycle acknowledgement pulse per latched element |
| `burst_write_done` | 1 | Output | 1-cycle transaction completion pulse on final element beat |
| `burst_write_err` | 1 | Output | 1-cycle strobe indicating transaction rejection |
| `burst_err_code` | 3 | Output | 3-bit error cause enumeration |
| **Accelerator Control Channel** | | | |
| `host_start` | 1 | Input | Execution start request |
| `host_ready` | 1 | Output | System ready flag (idle, matrices ready, write idle) |
| `host_busy` | 1 | Output | High when accelerator or interface is processing |
| `host_done` | 1 | Output | 1-cycle completion pulse when GEMM finishes |
| `start_ack` | 1 | Output | 1-cycle acknowledgement pulse for accepted start |
| `start_err` | 1 | Output | 1-cycle error strobe when start is rejected |
| `matrices_ready` | 1 | Output | Status flag indicating full A and B matrices loaded |
| `host_result_available`| 1 | Output | High when valid result matrix resides in output buffer |
| **Burst Read Channel** | | | |
| `burst_read_req` | 1 | Input | Strobe initiating a burst result readback transaction |
| `burst_read_addr` | `ADDR_WIDTH` | Input | Starting linear result element address |
| `burst_read_len` | `BURST_LEN_WIDTH` | Input | Number of 32-bit accumulator results to read |
| `burst_read_ready` | 1 | Input | Host flow control: `1` = ready to accept data beat, `0` = pause |
| `burst_read_valid` | 1 | Output | Read data valid strobe |
| `burst_read_data` | `ACC_WIDTH` | Output | 32-bit signed accumulator result element |
| `burst_read_done` | 1 | Output | 1-cycle completion pulse asserted on final read beat |
| `burst_read_err` | 1 | Output | 1-cycle error pulse on invalid read request |

---

## 4. Transfer Modes & Data Path

```
                    +------------------------------------+
                    |        Host 32-bit Data Bus        |
                    +------------------------------------+
                                      |
                     [burst_write_packed] Demux
                     /                          \
             Mode 0 (Streaming)          Mode 1 (Packed Word)
                    |                             |
             burst_write_data[7:0]      w_holding_data[31:0]
                    |                             |
                    |                   4:1 Byte Unpack Mux
                    |                  (w_sub_idx: 0, 1, 2, 3)
                    \                             /
                     +---------------------------+
                     |    buf_write_data [7:0]   |
                     |   Linear Addressing Engine|
                     +---------------------------+
                                  |
                                  v
                     tiled_input_buffer (A or B)
```

### 4.1 Mode 0: Streaming Element Burst Mode (`burst_write_packed = 0`)
- The host asserts `burst_write_req`, starting `burst_write_addr`, and `burst_write_len`.
- On each clock cycle where `burst_write_valid && burst_write_ready`, one 8-bit element from `burst_write_data[7:0]` is latched into the downstream buffer.
- `buf_write_addr` auto-increments each cycle from `burst_write_addr` to `burst_write_addr + burst_write_len - 1`.
- `burst_write_ack` pulses for every accepted element.
- `burst_write_done` pulses on the final element beat.

### 4.2 Mode 1: Packed 32-Bit Word Burst Mode (`burst_write_packed = 1`)
- Data is packed little-endian across the 32-bit bus:
  - Sub-word 0: `burst_write_data[7:0]`   (Address $A + 0$)
  - Sub-word 1: `burst_write_data[15:8]`  (Address $A + 1$)
  - Sub-word 2: `burst_write_data[23:16]` (Address $A + 2$)
  - Sub-word 3: `burst_write_data[31:24]` (Address $A + 3$)
- Sub-word 0 is written to `tiled_input_buffer` combinational-synchronously on the request cycle (0 bubbles).
- While draining sub-words 1, 2, and 3, the FSM transitions to `W_PACKED_DRAIN` and deasserts `burst_write_ready = 0` (active backpressure).
- Once all sub-words of the word are drained, `burst_write_ready` returns high, ready to accept the next packed word beat.

---

## 5. Flow Control, Acknowledgement & Handshaking

### 5.1 Zero-Bubble Downstream Memory Write
Downstream buffer memory (`tiled_input_buffer`) registers memory writes on clock rising edges (`always @(posedge clk)` conditioned on `buf_write_en`). Driving `buf_write_en` combinationally on valid host beats achieves **zero pipeline bubbles**:
```verilog
assign buf_write_en = (state_w == W_IDLE) ?
    (burst_write_req && valid_request && burst_write_valid && !ctrl_busy) :
    ((state_w == W_STREAM) ? (burst_write_valid && !ctrl_busy) :
    ((state_w == W_PACKED_WAIT) ? (burst_write_valid && !ctrl_busy) :
    (state_w == W_PACKED_DRAIN)));
```

### 5.2 Active Backpressure Timing
```text
Clock Cycle:       | 0 | 1 | 2 | 3 | 4 | 5 |
burst_write_req:   --~~~--------------------
burst_write_packed:--~~~~~~~~~~~~~~~~-------
burst_write_ready: ~~~~____~~~~~~~~~~~~~~~-- (deasserts for 3 cycles during drain)
buf_write_addr:    | A |A+1|A+2|A+3|A+4| ...
burst_write_ack:   --~---~---~---~---~---~--
burst_write_done:  --------------------~~~-- (asserts on final element beat)
```

---

## 6. Error Detection and Reporting

When an illegal transaction request is detected, `burst_write_err` pulses for 1 cycle, `burst_write_ready` remains high, the transaction is rejected with 0 downstream writes, and `burst_err_code` reports the specific cause:

| Error Code | Name | Value | Trigger Condition |
|:---|:---:|:---:|:---|
| `ERR_NONE` | None | `3'b000` | Successful transaction |
| `ERR_BUSY` | Busy Lockout | `3'b001` | Transaction requested while `ctrl_busy = 1` |
| `ERR_ADDR` | Address Fault | `3'b010` | `burst_write_addr >= total_elements` |
| `ERR_LEN`  | Length Fault | `3'b011` | `burst_write_len == 0` or `addr + len > total_elements` |
| `ERR_DIM`  | Dimension Fault| `3'b100` | `cfg_matrix_dim != 3` and `cfg_matrix_dim != 6` |

---

## 7. Accelerator Launch & Start Lockout

To protect systolic computation integrity:
1. **Rising-Edge Detection:** `host_start` is sampled through `host_start_q`. Only rising transitions (`host_start && !host_start_q`) produce execution launches (`ctrl_start`).
2. **Matrix Readiness Qualification:** If `host_start` pulses while `matrices_ready == 0`, `start_ack` is suppressed, `ctrl_start` remains 0, and `start_err` pulses for 1 cycle.
3. **Sticky Held-High Lockout:** If a host leaves `host_start` held high across completion, the accelerator completes without re-triggering. A transition back to `0` and a new rising edge is mandatory.
4. **Post-Reset Lockout:** Following reset deassertion (`rst_n: 0 -> 1`), any pre-existing high level on `host_start` is ignored until cleared.

---

## 8. Result Readback Subsystem & 2-Stage Skid Buffer

`partial_result_buffer` exhibits a 1-cycle synchronous read latency. When reading streaming results, backpressure from the host (`burst_read_ready = 0`) must not drop data in flight from the RAM.

```
+-----------------------+     res_read_data     +-------------------+     burst_read_data
| partial_result_buffer | --------------------> | 2-Stage Skid      | ------------------> Host
| (1-cycle synchronous) |                       | Buffer Engine     |
+-----------------------+                       +-------------------+
         ^                                                |
         | res_read_en                                    v
         +--------------------------------------- burst_read_ready
```

### 8.1 Two-Stage Skid Buffer Architecture
1. **Holding Register 0 (`r_holding_data`):** Preserves the element currently presented on `burst_read_data` when the host deasserts `burst_read_ready`.
2. **Holding Register 1 (`r_skid_data`):** Captures the in-flight element emerging from synchronous RAM 1 cycle after `res_read_en` drops.
3. **Lossless Recovery:** When `burst_read_ready` returns high, held elements are presented sequentially without bubbles and memory reading resumes seamlessly.

---

## 9. Verification & Unit Test Suite

The module is verified via `phase2/interface/tb_burst_interface.v` across 12 distinct test suites:

- **Suite 1:** System Reset & Idle State Verification (zero status, ready flags).
- **Suite 2:** Single-Element Transfers ($L = 1$) for Matrix A and B.
- **Suite 3:** Multi-Element Streaming Transfers ($L = 3$).
- **Suite 4:** Full Matrix 6x6 Streaming Transfer ($L = 36$, 36 elements verified sequentially).
- **Suite 5:** Packed-Word Burst Mode ($4 \times 8$-bit) & Active Backpressure Verification.
- **Suite 6:** Interrupted Transfers with Host Valid Deassertion.
- **Suite 7:** Busy-State Rejection & Error Code Generation.
- **Suite 8:** Invalid Address, Zero Length, Out-of-Bounds, and Dimension Rejections.
- **Suite 9:** Asynchronous Reset Mid-Burst with Clean Abort.
- **Suite 10:** Back-to-Back Repeated Bursts without Reset.
- **Suite 11:** Host Start Qualification, Lockout, and Edge Detection.
- **Suite 12:** Result Readback Streaming, 2-Stage Skid-Buffer Backpressure, and Completion Handshake.

### Test Results
```text
==================================================================
BURST MATRIX INTERFACE TEST SUMMARY:
  PASSED CHECKS : 215
  FAILED CHECKS : 0
==================================================================
RESULT: ALL BURST INTERFACE TESTS PASSED SUCCESSFULLY!
```

---

## 10. Simulation Commands

```bash
# Run unit testbench directly with Icarus Verilog
make test-burst-interface

# Or run via manual invocation:
iverilog -g2012 -Wall -s tb_burst_interface -o build/tb_burst_interface.vvp \
    rtl/mac_unit.v rtl/processing_element.v rtl/pe_interconnect.v rtl/systolic_array.v \
    rtl/control_fsm.v rtl/systolic_controller.v phase2/scalability/tiled_input_buffer.v \
    phase2/scalability/matrix_tiling_controller.v phase2/scalability/partial_result_buffer.v \
    phase2/interface/burst_matrix_interface.v phase2/interface/tb_burst_interface.v
vvp build/tb_burst_interface.vvp
```
