// burst_matrix_interface.v
// Phase II Interface - High-Bandwidth Burst & Block Matrix Interface
//
// Responsibilities:
//   - High-bandwidth host matrix input transfers:
//       * Streaming burst mode (1 element/beat across consecutive cycles).
//       * Packed-word burst mode (multiple elements packed per beat, e.g. 4 elements in 32-bit word).
//       * Matrix selection for Matrix A and Matrix B (burst_write_is_b).
//       * Automatic address progression and transfer-length management.
//       * Beat-level write acknowledgement (burst_write_ack) and transaction completion (burst_write_done).
//       * Active backpressure via burst_write_ready (when busy, unpacking, or receiving buffer is unready).
//       * Comprehensive error detection: out-of-range address, invalid length, unsupported dimension,
//         and write attempts during busy states (burst_write_err and burst_err_code).
//   - Host accelerator control and synchronization:
//       * Evaluates matrices_ready and controller_idle before issuing a clean 1-cycle start pulse.
//       * Generates out_buf_clear pulse on accepted start to invalidate stale prior results.
//       * Provides start_ack on acceptance and start_err on rejection.
//       * Start-edge qualification with reset-lockout and held-high suppression (preserves Phase I semantics).
//   - High-bandwidth result readback:
//       * Burst read requests with base address and transfer length.
//       * Synchronous streaming readback with burst_read_valid, burst_read_data, and burst_read_done.
//       * Host backpressure handling via burst_read_ready (skid buffer prevents data loss or duplication).
//       * Error detection for unready results, out-of-range addresses, or invalid read lengths.

`timescale 1ns / 1ps
`default_nettype none

module burst_matrix_interface #(
    parameter integer ARRAY_SIZE      = 3,
    parameter integer MAX_MATRIX_SIZE = 6,
    parameter integer DATA_WIDTH      = 8,
    parameter integer ACC_WIDTH       = 32,
    parameter integer WORDS_PER_BEAT  = 4,
    parameter integer BUS_DATA_WIDTH  = WORDS_PER_BEAT * DATA_WIDTH,
    parameter integer ADDR_WIDTH      = (MAX_MATRIX_SIZE * MAX_MATRIX_SIZE <= 1) ? 1 : $clog2(MAX_MATRIX_SIZE * MAX_MATRIX_SIZE),
    parameter integer BURST_LEN_WIDTH = $clog2(MAX_MATRIX_SIZE * MAX_MATRIX_SIZE + 1) + 1
) (
    input  wire                               clk,
    input  wire                               rst_n,

    // Runtime Matrix Dimension Configuration (3 for 3x3, 6 for 6x6)
    input  wire [3:0]                         cfg_matrix_dim,

    // -------------------------------------------------------------
    // Host Burst Write Interface
    // -------------------------------------------------------------
    input  wire                               burst_write_req,     // Initiates burst write transaction
    input  wire                               burst_write_is_b,   // 0: Matrix A, 1: Matrix B
    input  wire [ADDR_WIDTH-1:0]              burst_write_addr,   // Base element address [0 .. total_elements-1]
    input  wire [BURST_LEN_WIDTH-1:0]         burst_write_len,    // Number of elements in burst [1 .. total_elements]
    input  wire                               burst_write_packed, // 0: Streaming element beats, 1: Packed word beats
    input  wire                               burst_write_valid,  // Host drives valid data beat
    output wire                               burst_write_ready,  // Interface ready to accept data beat (backpressure)
    input  wire [BUS_DATA_WIDTH-1:0]          burst_write_data,   // Data beat: [DATA_WIDTH-1:0] if unpacked, full word if packed
    output reg                                burst_write_ack,    // 1-cycle registered pulse per accepted element
    output reg                                burst_write_done,   // 1-cycle pulse when burst completes
    output reg                                burst_write_err,    // 1-cycle pulse if transaction rejected or invalid
    output reg  [2:0]                         burst_err_code,     // Detailed error code

    // -------------------------------------------------------------
    // Host Accelerator Control & Status Interface
    // -------------------------------------------------------------
    input  wire                               host_start,         // Host operation request
    output wire                               host_ready,         // Idle and matrices ready
    output wire                               host_busy,          // Accelerator is active or writing
    output wire                               host_done,          // Operation completion pulse
    output reg                                start_ack,          // Start accepted pulse
    output reg                                start_err,          // Start rejected pulse
    output wire                               matrices_ready,     // Matrices A and B ready
    output wire                               host_result_available, // Result matrix valid in buffer

    // -------------------------------------------------------------
    // Host Burst Result Readback Interface
    // -------------------------------------------------------------
    input  wire                               burst_read_req,     // Initiates burst read transaction
    input  wire [ADDR_WIDTH-1:0]              burst_read_addr,    // Base read address
    input  wire [BURST_LEN_WIDTH-1:0]         burst_read_len,     // Number of result elements to read
    input  wire                               burst_read_ready,   // Host ready to accept read data (host backpressure)
    output wire                               burst_read_valid,   // Interface drives valid read data
    output wire signed [ACC_WIDTH-1:0]        burst_read_data,    // Result data
    output wire                               burst_read_done,    // 1-cycle pulse when read transaction completes
    output reg                                burst_read_err,     // 1-cycle pulse if read request rejected
    output wire [ADDR_WIDTH-1:0]              curr_read_addr,     // Current read address

    // -------------------------------------------------------------
    // Downstream Input Buffer Interface (Element writes)
    // -------------------------------------------------------------
    output wire                               buf_write_en,
    output wire                               buf_write_is_b,
    output wire [ADDR_WIDTH-1:0]              buf_write_addr,
    output wire signed [DATA_WIDTH-1:0]       buf_write_data,
    input  wire                               buf_matrices_ready,

    // -------------------------------------------------------------
    // Downstream Controller Interface
    // -------------------------------------------------------------
    output reg                                ctrl_start,
    input  wire                               ctrl_idle,
    input  wire                               ctrl_busy,
    input  wire                               ctrl_done,

    // -------------------------------------------------------------
    // Downstream Output / Result Buffer Interface
    // -------------------------------------------------------------
    output reg                                out_buf_clear,
    output reg                                res_read_en,
    output reg  [ADDR_WIDTH-1:0]              res_read_addr,
    input  wire signed [ACC_WIDTH-1:0]        res_read_data,
    input  wire                               res_read_valid,
    input  wire                               res_available
);

    // Error code definitions
    localparam [2:0]
        ERR_NONE  = 3'b000,
        ERR_BUSY  = 3'b001, // Write/start attempted while accelerator is busy
        ERR_ADDR  = 3'b010, // Starting address out of range
        ERR_LEN   = 3'b011, // Invalid length (len == 0 or addr + len > total_elements)
        ERR_DIM   = 3'b100, // Unsupported matrix dimension (not 3 and not 6)
        ERR_ABORT = 3'b101; // Transaction aborted / interrupted

    // Active dimension checks
    wire dim_supported = (cfg_matrix_dim == 4'd3) || (cfg_matrix_dim == 4'd6);
    wire [ADDR_WIDTH+1:0] total_elements = (cfg_matrix_dim == 4'd3) ? (4'd3 * 4'd3) :
                                           (cfg_matrix_dim == 4'd6) ? (4'd6 * 4'd6) : { (ADDR_WIDTH+2){1'b0} };

    // =============================================================
    // Write Subsystem FSM & Datapath
    // =============================================================
    localparam [1:0]
        W_IDLE         = 2'b00,
        W_STREAM       = 2'b01, // Streaming element beats (1 element per beat)
        W_PACKED_DRAIN = 2'b10, // Unpacking sub-words to input buffer (backpressure asserted)
        W_PACKED_WAIT  = 2'b11; // Waiting for next packed word beat from host

    reg [1:0] state_w;

    reg                          w_is_b;
    reg [ADDR_WIDTH-1:0]         w_curr_addr;
    reg [BURST_LEN_WIDTH-1:0]    w_rem_len;
    reg                          w_packed_mode;
    reg [BUS_DATA_WIDTH-1:0]     w_holding_data;
    reg [3:0]                    w_sub_idx;
    reg [3:0]                    w_sub_limit;

    // Backpressure to host on write:
    // Ready in W_IDLE (if idle and supported dimension), in W_STREAM (if not busy),
    // and in W_PACKED_WAIT (when ready for next packed word).
    // NOT ready in W_PACKED_DRAIN (backpressure active while unpacking sub-words).
    assign burst_write_ready = (state_w == W_IDLE)        ? (!ctrl_busy && !ctrl_start && dim_supported) :
                               (state_w == W_STREAM)      ? (!ctrl_busy) :
                               (state_w == W_PACKED_WAIT) ? (!ctrl_busy) : 1'b0;

    // Boundary check helper
    wire [BURST_LEN_WIDTH+1:0] write_end_addr = {2'b00, burst_write_addr} + {2'b00, burst_write_len};

    // Words per beat calculations
    wire [3:0] words_in_first_beat = (burst_write_len < WORDS_PER_BEAT) ? burst_write_len[3:0] : WORDS_PER_BEAT[3:0];
    wire [3:0] words_in_next_beat  = (w_rem_len < WORDS_PER_BEAT) ? w_rem_len[3:0] : WORDS_PER_BEAT[3:0];

    // Combinational buffer write signals
    wire write_beat_active = ((state_w == W_IDLE) && burst_write_req && burst_write_valid && burst_write_ready) ||
                             ((state_w == W_STREAM) && burst_write_valid && burst_write_ready) ||
                             ((state_w == W_PACKED_WAIT) && burst_write_valid && burst_write_ready);

    wire write_drain_active = (state_w == W_PACKED_DRAIN);

    assign buf_write_en = write_beat_active || write_drain_active;

    assign buf_write_is_b = (state_w == W_IDLE) ? burst_write_is_b : w_is_b;

    assign buf_write_addr = (state_w == W_IDLE) ? burst_write_addr : w_curr_addr;

    assign buf_write_data = write_drain_active ? w_holding_data[(w_sub_idx * DATA_WIDTH) +: DATA_WIDTH] :
                                                 burst_write_data[DATA_WIDTH-1:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_w          <= W_IDLE;
            burst_write_ack  <= 1'b0;
            burst_write_done <= 1'b0;
            burst_write_err  <= 1'b0;
            burst_err_code   <= ERR_NONE;
            w_is_b           <= 1'b0;
            w_curr_addr      <= {ADDR_WIDTH{1'b0}};
            w_rem_len        <= {BURST_LEN_WIDTH{1'b0}};
            w_packed_mode    <= 1'b0;
            w_holding_data   <= {BUS_DATA_WIDTH{1'b0}};
            w_sub_idx        <= 4'd0;
            w_sub_limit      <= 4'd0;
        end else begin
            burst_write_ack  <= buf_write_en;
            burst_write_done <= 1'b0;
            burst_write_err  <= 1'b0;

            case (state_w)
                W_IDLE: begin
                    burst_err_code <= ERR_NONE;
                    if (burst_write_req) begin
                        if (ctrl_busy || ctrl_start) begin
                            burst_write_err <= 1'b1;
                            burst_err_code  <= ERR_BUSY;
                        end else if (!dim_supported) begin
                            burst_write_err <= 1'b1;
                            burst_err_code  <= ERR_DIM;
                        end else if (burst_write_len == 0) begin
                            burst_write_err <= 1'b1;
                            burst_err_code  <= ERR_LEN;
                        end else if (burst_write_addr >= total_elements[ADDR_WIDTH-1:0]) begin
                            burst_write_err <= 1'b1;
                            burst_err_code  <= ERR_ADDR;
                        end else if (write_end_addr > total_elements) begin
                            burst_write_err <= 1'b1;
                            burst_err_code  <= ERR_LEN;
                        end else begin
                            // Transaction accepted
                            w_is_b        <= burst_write_is_b;
                            w_packed_mode <= burst_write_packed;

                            if (!burst_write_packed) begin
                                // Streaming element mode
                                if (burst_write_valid) begin
                                    w_curr_addr <= burst_write_addr + 1'b1;
                                    w_rem_len   <= burst_write_len - 1'b1;

                                    if (burst_write_len == 1) begin
                                        burst_write_done <= 1'b1;
                                        state_w          <= W_IDLE;
                                    end else begin
                                        state_w          <= W_STREAM;
                                    end
                                end else begin
                                    w_curr_addr <= burst_write_addr;
                                    w_rem_len   <= burst_write_len;
                                    state_w     <= W_STREAM;
                                end
                            end else begin
                                // Packed word mode
                                if (burst_write_valid) begin
                                    w_holding_data <= burst_write_data;
                                    w_curr_addr    <= burst_write_addr + 1'b1;
                                    w_rem_len      <= burst_write_len - 1'b1;

                                    if (words_in_first_beat > 1) begin
                                        w_sub_idx   <= 4'd1;
                                        w_sub_limit <= words_in_first_beat;
                                        state_w     <= W_PACKED_DRAIN;
                                    end else begin
                                        if (burst_write_len == 1) begin
                                            burst_write_done <= 1'b1;
                                            state_w          <= W_IDLE;
                                        end else begin
                                            state_w          <= W_PACKED_WAIT;
                                        end
                                    end
                                end else begin
                                    w_curr_addr <= burst_write_addr;
                                    w_rem_len   <= burst_write_len;
                                    state_w     <= W_PACKED_WAIT;
                                end
                            end
                        end
                    end
                end

                W_STREAM: begin
                    if (ctrl_busy) begin
                        burst_write_err <= 1'b1;
                        burst_err_code  <= ERR_BUSY;
                        state_w         <= W_IDLE;
                    end else if (burst_write_valid) begin
                        w_curr_addr <= w_curr_addr + 1'b1;
                        w_rem_len   <= w_rem_len - 1'b1;

                        if (w_rem_len == 1) begin
                            burst_write_done <= 1'b1;
                            state_w          <= W_IDLE;
                        end
                    end
                end

                W_PACKED_DRAIN: begin
                    w_curr_addr <= w_curr_addr + 1'b1;
                    w_rem_len   <= w_rem_len - 1'b1;
                    w_sub_idx   <= w_sub_idx + 1'b1;

                    if (w_sub_idx + 1'b1 == w_sub_limit) begin
                        // Finished unpacking this word
                        if (w_rem_len == 1) begin
                            burst_write_done <= 1'b1;
                            state_w          <= W_IDLE;
                        end else begin
                            state_w          <= W_PACKED_WAIT;
                        end
                    end
                end

                W_PACKED_WAIT: begin
                    if (ctrl_busy) begin
                        burst_write_err <= 1'b1;
                        burst_err_code  <= ERR_BUSY;
                        state_w         <= W_IDLE;
                    end else if (burst_write_valid) begin
                        w_holding_data <= burst_write_data;
                        w_curr_addr    <= w_curr_addr + 1'b1;
                        w_rem_len      <= w_rem_len - 1'b1;

                        if (words_in_next_beat > 1) begin
                            w_sub_idx   <= 4'd1;
                            w_sub_limit <= words_in_next_beat;
                            state_w     <= W_PACKED_DRAIN;
                        end else begin
                            if (w_rem_len == 1) begin
                                burst_write_done <= 1'b1;
                                state_w          <= W_IDLE;
                            end else begin
                                state_w          <= W_PACKED_WAIT;
                            end
                        end
                    end
                end

                default: state_w <= W_IDLE;
            endcase
        end
    end

    // =============================================================
    // Readback Subsystem FSM & 2-Stage Skid Buffer
    // =============================================================
    localparam [1:0]
        R_IDLE   = 2'b00,
        R_ACTIVE = 2'b01,
        R_HOLD   = 2'b11;

    reg [1:0] state_r;

    reg [ADDR_WIDTH-1:0]              r_curr_addr;
    reg [BURST_LEN_WIDTH-1:0]         r_req_rem;
    reg [BURST_LEN_WIDTH-1:0]         r_rem_len;
    reg signed [ACC_WIDTH-1:0]        r_holding_data;
    reg                               r_holding_valid;
    reg signed [ACC_WIDTH-1:0]        r_skid_data;
    reg                               r_skid_valid;
    wire [BURST_LEN_WIDTH+1:0] read_end_addr = {2'b00, burst_read_addr} + {2'b00, burst_read_len};

    assign curr_read_addr = r_curr_addr;

    assign burst_read_valid = (state_r == R_IDLE) ? 1'b0 :
                              (r_holding_valid ? 1'b1 : res_read_valid);
    assign burst_read_data  = r_holding_valid ? r_holding_data : res_read_data;
    assign burst_read_done  = burst_read_valid && (r_rem_len == 1);

    wire read_beat_accepted = burst_read_valid && burst_read_ready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_r          <= R_IDLE;
            burst_read_err   <= 1'b0;
            res_read_en      <= 1'b0;
            res_read_addr    <= {ADDR_WIDTH{1'b0}};
            r_curr_addr      <= {ADDR_WIDTH{1'b0}};
            r_req_rem        <= {BURST_LEN_WIDTH{1'b0}};
            r_rem_len        <= {BURST_LEN_WIDTH{1'b0}};
            r_holding_data   <= {ACC_WIDTH{1'b0}};
            r_holding_valid  <= 1'b0;
            r_skid_data      <= {ACC_WIDTH{1'b0}};
            r_skid_valid     <= 1'b0;
        end else begin
            burst_read_err   <= 1'b0;

            case (state_r)
                R_IDLE: begin
                    res_read_en     <= 1'b0;
                    r_holding_valid <= 1'b0;
                    r_skid_valid    <= 1'b0;
                    if (burst_read_req) begin
                        if (!res_available || out_buf_clear) begin
                            burst_read_err <= 1'b1;
                        end else if (!dim_supported) begin
                            burst_read_err <= 1'b1;
                        end else if (burst_read_len == 0) begin
                            burst_read_err <= 1'b1;
                        end else if (burst_read_addr >= total_elements[ADDR_WIDTH-1:0]) begin
                            burst_read_err <= 1'b1;
                        end else if (read_end_addr > total_elements) begin
                            burst_read_err <= 1'b1;
                        end else begin
                            // Issue first read to memory
                            r_curr_addr   <= burst_read_addr + 1'b1;
                            r_req_rem     <= burst_read_len - 1'b1;
                            r_rem_len     <= burst_read_len;
                            res_read_en   <= 1'b1;
                            res_read_addr <= burst_read_addr;
                            state_r       <= R_ACTIVE;
                        end
                    end
                end

                R_ACTIVE: begin
                    // Backpressure capture
                    if (res_read_valid && !burst_read_ready && !r_holding_valid) begin
                        res_read_en     <= 1'b0;
                        r_holding_data  <= res_read_data;
                        r_holding_valid <= 1'b1;
                        state_r         <= R_HOLD;
                    end

                    // Beat consumption
                    if (read_beat_accepted) begin
                        if (r_holding_valid) begin
                            r_holding_valid <= 1'b0;
                        end
                        r_rem_len <= r_rem_len - 1'b1;
                        if (r_rem_len == 1) begin
                            res_read_en <= 1'b0;
                            state_r     <= R_IDLE;
                        end
                    end

                    // Memory pipelining
                    if (r_rem_len > 1) begin
                        if (r_req_rem > 0 && burst_read_ready) begin
                            res_read_en   <= 1'b1;
                            res_read_addr <= r_curr_addr;
                            r_curr_addr   <= r_curr_addr + 1'b1;
                            r_req_rem     <= r_req_rem - 1'b1;
                        end else if (!burst_read_ready) begin
                            res_read_en   <= 1'b0;
                        end
                    end
                end

                R_HOLD: begin
                    // Skid buffer active: capture newly arrived in-flight data into second register
                    if (!r_skid_valid && res_read_valid) begin
                        r_skid_data  <= res_read_data;
                        r_skid_valid <= 1'b1;
                    end

                    // Skid buffer active: host accepts held beat
                    if (read_beat_accepted) begin
                        r_rem_len <= r_rem_len - 1'b1;
                        if (r_rem_len == 1) begin
                            r_holding_valid <= 1'b0;
                            r_skid_valid    <= 1'b0;
                            res_read_en     <= 1'b0;
                            state_r         <= R_IDLE;
                        end else if (r_skid_valid || res_read_valid) begin
                            // Advance in-flight skid element to holding register
                            r_holding_data  <= r_skid_valid ? r_skid_data : res_read_data;
                            r_holding_valid <= 1'b1;
                            r_skid_valid    <= 1'b0;

                            // Resume memory pipelining if host is ready
                            if (burst_read_ready) begin
                                if (r_req_rem > 0) begin
                                    res_read_en   <= 1'b1;
                                    res_read_addr <= r_curr_addr;
                                    r_curr_addr   <= r_curr_addr + 1'b1;
                                    r_req_rem     <= r_req_rem - 1'b1;
                                end
                            end else begin
                                res_read_en <= 1'b0;
                            end
                        end else begin
                            // No skid element held: return directly to R_ACTIVE
                            r_holding_valid <= 1'b0;
                            state_r         <= R_ACTIVE;
                            if (r_req_rem > 0) begin
                                res_read_en   <= 1'b1;
                                res_read_addr <= r_curr_addr;
                                r_curr_addr   <= r_curr_addr + 1'b1;
                                r_req_rem     <= r_req_rem - 1'b1;
                            end
                        end
                    end
                end

                default: state_r <= R_IDLE;
            endcase
        end
    end

    // =============================================================
    // Accelerator Control, Synchronization & Start Lockout
    // =============================================================
    reg host_start_q;
    reg reset_lock;
    wire host_start_pulse = host_start & ~host_start_q & ~reset_lock;

    assign matrices_ready        = buf_matrices_ready && dim_supported;
    assign host_ready            = ctrl_idle && matrices_ready && (state_w == W_IDLE) && !ctrl_start;
    assign host_busy             = ctrl_busy || (state_w != W_IDLE) || ctrl_start;
    assign host_done             = ctrl_done;
    assign host_result_available = res_available;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            host_start_q  <= 1'b0;
            reset_lock    <= 1'b1;
            ctrl_start    <= 1'b0;
            start_ack     <= 1'b0;
            start_err     <= 1'b0;
            out_buf_clear <= 1'b0;
        end else begin
            host_start_q  <= host_start;
            reset_lock    <= 1'b0;
            ctrl_start    <= 1'b0;
            start_ack     <= 1'b0;
            start_err     <= 1'b0;
            out_buf_clear <= 1'b0;

            if (host_start_pulse) begin
                if (ctrl_idle && buf_matrices_ready && dim_supported && (state_w == W_IDLE)) begin
                    ctrl_start    <= 1'b1;
                    start_ack     <= 1'b1;
                    out_buf_clear <= 1'b1;
                end else begin
                    start_err     <= 1'b1;
                end
            end
        end
    end

endmodule

`default_nettype wire
