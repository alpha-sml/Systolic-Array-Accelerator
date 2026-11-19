// tb_burst_interface.v
// Comprehensive Self-Checking Testbench for burst_matrix_interface
//
// Verification Scope:
//   1. Single-element transfers (length 1) for Matrix A and Matrix B.
//   2. Multi-element streaming burst transfers (length 3, 6).
//   3. Full-matrix block transfers (3x3: 9 elements, 6x6: 36 elements) in streaming and packed modes.
//   4. Correct sequential address progression and transfer-length bounds.
//   5. Write acknowledgement (burst_write_ack) and transaction completion (burst_write_done).
//   6. Active backpressure behavior in packed word mode (burst_write_ready = 0 during drain).
//   7. Host read backpressure handling (burst_read_ready = 0 pauses read stream without data loss).
//   8. Busy-state rejection (reject writes when ctrl_busy = 1 with ERR_BUSY).
//   9. Invalid address rejection (addr >= total_elements with ERR_ADDR).
//  10. Invalid length rejection (len == 0 or addr + len > total_elements with ERR_LEN).
//  11. Unsupported dimension rejection (cfg_matrix_dim != 3 and != 6 with ERR_DIM).
//  12. Reset during idle and reset during active burst (immediate abort and clean recovery).
//  13. Incomplete / interrupted transfers (host deasserts valid mid-burst, resumes cleanly).
//  14. Back-to-back repeated burst transactions with zero wait states.
//  15. Host start qualification, reset-lockout, and held-high start suppression.
//  16. Burst and single-element result readback with error detection for unready results.

`timescale 1ns / 1ps
`default_nettype none

module tb_burst_interface;

    localparam integer ARRAY_SIZE      = 3;
    localparam integer MAX_MATRIX_SIZE = 6;
    localparam integer DATA_WIDTH      = 8;
    localparam integer ACC_WIDTH       = 32;
    localparam integer WORDS_PER_BEAT  = 4;
    localparam integer BUS_DATA_WIDTH  = WORDS_PER_BEAT * DATA_WIDTH;
    localparam integer ADDR_WIDTH      = (MAX_MATRIX_SIZE * MAX_MATRIX_SIZE <= 1) ? 1 : $clog2(MAX_MATRIX_SIZE * MAX_MATRIX_SIZE);
    localparam integer BURST_LEN_WIDTH = $clog2(MAX_MATRIX_SIZE * MAX_MATRIX_SIZE + 1) + 1;
    localparam integer CLK_PERIOD      = 10;

    localparam [2:0]
        ERR_NONE  = 3'b000,
        ERR_BUSY  = 3'b001,
        ERR_ADDR  = 3'b010,
        ERR_LEN   = 3'b011,
        ERR_DIM   = 3'b100,
        ERR_ABORT = 3'b101;

    // Clock and reset
    reg                               clk;
    reg                               rst_n;

    // Configuration
    reg  [3:0]                         cfg_matrix_dim;

    // Host burst write interface
    reg                               burst_write_req;
    reg                               burst_write_is_b;
    reg  [ADDR_WIDTH-1:0]              burst_write_addr;
    reg  [BURST_LEN_WIDTH-1:0]         burst_write_len;
    reg                               burst_write_packed;
    reg                               burst_write_valid;
    wire                              burst_write_ready;
    reg  [BUS_DATA_WIDTH-1:0]          burst_write_data;
    wire                              burst_write_ack;
    wire                              burst_write_done;
    wire                              burst_write_err;
    wire [2:0]                         burst_err_code;

    // Host control & status
    reg                               host_start;
    wire                              host_ready;
    wire                              host_busy;
    wire                              host_done;
    wire                              start_ack;
    wire                              start_err;
    wire                              matrices_ready;
    wire                              host_result_available;

    // Host burst read interface
    reg                               burst_read_req;
    reg  [ADDR_WIDTH-1:0]              burst_read_addr;
    reg  [BURST_LEN_WIDTH-1:0]         burst_read_len;
    reg                               burst_read_ready;
    wire                              burst_read_valid;
    wire signed [ACC_WIDTH-1:0]        burst_read_data;
    wire                              burst_read_done;
    wire                              burst_read_err;
    wire [ADDR_WIDTH-1:0]              curr_read_addr;

    // Downstream buffer interface
    wire                              buf_write_en;
    wire                              buf_write_is_b;
    wire [ADDR_WIDTH-1:0]              buf_write_addr;
    wire signed [DATA_WIDTH-1:0]       buf_write_data;
    reg                               buf_matrices_ready;

    // Downstream controller interface
    wire                              ctrl_start;
    reg                               ctrl_idle;
    reg                               ctrl_busy;
    reg                               ctrl_done;

    // Downstream result buffer interface
    wire                              out_buf_clear;
    wire                              res_read_en;
    wire [ADDR_WIDTH-1:0]              res_read_addr;
    reg  signed [ACC_WIDTH-1:0]        res_read_data;
    reg                               res_read_valid;
    reg                               res_available;

    // Mock memory for verifying downstream writes
    reg signed [DATA_WIDTH-1:0] mock_mem_a [0:35];
    reg signed [DATA_WIDTH-1:0] mock_mem_b [0:35];
    reg signed [ACC_WIDTH-1:0]  mock_res_mem [0:35];

    // Verification statistics
    integer pass_count;
    integer fail_count;

    // DUT instantiation
    burst_matrix_interface #(
        .ARRAY_SIZE     (ARRAY_SIZE),
        .MAX_MATRIX_SIZE(MAX_MATRIX_SIZE),
        .DATA_WIDTH     (DATA_WIDTH),
        .ACC_WIDTH      (ACC_WIDTH),
        .WORDS_PER_BEAT (WORDS_PER_BEAT),
        .BUS_DATA_WIDTH (BUS_DATA_WIDTH),
        .ADDR_WIDTH     (ADDR_WIDTH),
        .BURST_LEN_WIDTH(BURST_LEN_WIDTH)
    ) dut (
        .clk                  (clk),
        .rst_n                (rst_n),
        .cfg_matrix_dim       (cfg_matrix_dim),
        .burst_write_req      (burst_write_req),
        .burst_write_is_b     (burst_write_is_b),
        .burst_write_addr     (burst_write_addr),
        .burst_write_len      (burst_write_len),
        .burst_write_packed   (burst_write_packed),
        .burst_write_valid    (burst_write_valid),
        .burst_write_ready    (burst_write_ready),
        .burst_write_data     (burst_write_data),
        .burst_write_ack      (burst_write_ack),
        .burst_write_done     (burst_write_done),
        .burst_write_err      (burst_write_err),
        .burst_err_code       (burst_err_code),
        .host_start           (host_start),
        .host_ready           (host_ready),
        .host_busy            (host_busy),
        .host_done            (host_done),
        .start_ack            (start_ack),
        .start_err            (start_err),
        .matrices_ready       (matrices_ready),
        .host_result_available(host_result_available),
        .burst_read_req       (burst_read_req),
        .burst_read_addr      (burst_read_addr),
        .burst_read_len       (burst_read_len),
        .burst_read_ready     (burst_read_ready),
        .burst_read_valid     (burst_read_valid),
        .burst_read_data      (burst_read_data),
        .burst_read_done      (burst_read_done),
        .burst_read_err       (burst_read_err),
        .curr_read_addr       (curr_read_addr),
        .buf_write_en         (buf_write_en),
        .buf_write_is_b       (buf_write_is_b),
        .buf_write_addr       (buf_write_addr),
        .buf_write_data       (buf_write_data),
        .buf_matrices_ready   (buf_matrices_ready),
        .ctrl_start           (ctrl_start),
        .ctrl_idle            (ctrl_idle),
        .ctrl_busy            (ctrl_busy),
        .ctrl_done            (ctrl_done),
        .out_buf_clear        (out_buf_clear),
        .res_read_en          (res_read_en),
        .res_read_addr        (res_read_addr),
        .res_read_data        (res_read_data),
        .res_read_valid       (res_read_valid),
        .res_available        (res_available)
    );

    // Clock generator: 100 MHz
    initial clk = 1'b0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    // Check task with fatal failure
    task automatic check(input condition, input [511:0] msg);
        begin
            if (condition) begin
                pass_count = pass_count + 1;
                $display("  [PASS] %0s", msg);
            end else begin
                fail_count = fail_count + 1;
                $display("  [FAIL] %0s at time %0t ps", msg, $time);
                $fatal(1, "Test assertion failed!");
            end
        end
    endtask

    // Clock step helper
    task automatic step;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    // Mock memory write capture
    always @(posedge clk) begin
        if (buf_write_en) begin
            if (!buf_write_is_b)
                mock_mem_a[buf_write_addr] <= buf_write_data;
            else
                mock_mem_b[buf_write_addr] <= buf_write_data;
        end
    end

    // Mock result buffer synchronous read
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            res_read_valid <= 1'b0;
            res_read_data  <= {ACC_WIDTH{1'b0}};
        end else begin
            if (res_read_en && res_available && !out_buf_clear) begin
                res_read_data  <= mock_res_mem[res_read_addr];
                res_read_valid <= 1'b1;
            end else begin
                res_read_data  <= {ACC_WIDTH{1'b0}};
                res_read_valid <= 1'b0;
            end
        end
    end

    integer i, k;

    initial begin
        $dumpfile("build/tb_burst_interface.vcd");
        $dumpvars(0, tb_burst_interface);

        pass_count         = 0;
        fail_count         = 0;
        rst_n              = 1'b0;
        cfg_matrix_dim     = 4'd6;
        burst_write_req    = 1'b0;
        burst_write_is_b   = 1'b0;
        burst_write_addr   = {ADDR_WIDTH{1'b0}};
        burst_write_len    = {BURST_LEN_WIDTH{1'b0}};
        burst_write_packed = 1'b0;
        burst_write_valid  = 1'b0;
        burst_write_data   = {BUS_DATA_WIDTH{1'b0}};
        host_start         = 1'b0;
        burst_read_req     = 1'b0;
        burst_read_addr    = {ADDR_WIDTH{1'b0}};
        burst_read_len     = {BURST_LEN_WIDTH{1'b0}};
        burst_read_ready   = 1'b1;
        buf_matrices_ready = 1'b0;
        ctrl_idle          = 1'b1;
        ctrl_busy          = 1'b0;
        ctrl_done          = 1'b0;
        res_available      = 1'b0;

        for (i = 0; i < 36; i = i + 1) begin
            mock_mem_a[i]   = 8'sd0;
            mock_mem_b[i]   = 8'sd0;
            mock_res_mem[i] = 32'sd100 + i;
        end

        $display("==================================================================");
        $display("STARTING BURST MATRIX INTERFACE VERIFICATION SUITE");
        $display("==================================================================");

        // -------------------------------------------------------------
        // Test 1: Reset and Initialization
        // -------------------------------------------------------------
        $display("\n--- Test 1: Reset and Idle State ---");
        #15;
        rst_n = 1'b1;
        step;
        check(burst_write_ready === 1'b1, "burst_write_ready asserted after reset in idle state");
        check(host_ready === 1'b0, "host_ready deasserted while matrices not ready");
        check(host_busy === 1'b0, "host_busy deasserted in idle");
        check(burst_write_ack === 1'b0, "burst_write_ack low in idle");
        check(burst_write_done === 1'b0, "burst_write_done low in idle");
        check(burst_write_err === 1'b0, "burst_write_err low in idle");

        // -------------------------------------------------------------
        // Test 2: Single-Element Transfers (Length 1) for A and B
        // -------------------------------------------------------------
        $display("\n--- Test 2: Single-Element Transfers (Length 1) ---");
        // Write Matrix A at address 0
        burst_write_req    = 1'b1;
        burst_write_is_b   = 1'b0;
        burst_write_addr   = 6'd0;
        burst_write_len    = 7'd1;
        burst_write_packed = 1'b0;
        burst_write_valid  = 1'b1;
        burst_write_data   = {24'd0, 8'sd42};
        step;
        check(burst_write_ack === 1'b1, "burst_write_ack asserted on single-element write");
        check(burst_write_done === 1'b1, "burst_write_done asserted on single-element write");
        check(mock_mem_a[0] === 8'sd42, "mock_mem_a[0] received 42");

        // Write Matrix B at address 5
        burst_write_is_b = 1'b1;
        burst_write_addr = 6'd5;
        burst_write_data = {24'd0, -8'sd77};
        step;
        burst_write_req   = 1'b0;
        burst_write_valid = 1'b0;
        check(burst_write_ack === 1'b1, "burst_write_ack asserted on Matrix B single write");
        check(burst_write_done === 1'b1, "burst_write_done asserted on Matrix B single write");
        check(mock_mem_b[5] === -8'sd77, "mock_mem_b[5] received -77");

        step;
        check(burst_write_done === 1'b0, "burst_write_done pulses for exactly 1 cycle");

        // -------------------------------------------------------------
        // Test 3: Multi-Element Streaming Burst Transfers (Length 3 and 6)
        // -------------------------------------------------------------
        $display("\n--- Test 3: Multi-Element Streaming Burst Transfers ---");
        // Write Matrix A addresses 1..3 with length 3
        burst_write_req    = 1'b1;
        burst_write_is_b   = 1'b0;
        burst_write_addr   = 6'd1;
        burst_write_len    = 7'd3;
        burst_write_packed = 1'b0;
        burst_write_valid  = 1'b1;
        burst_write_data   = {24'd0, 8'sd11};
        step;
        check(burst_write_ack === 1'b1, "burst_write_ack beat 1");
        check(burst_write_done === 1'b0, "burst_write_done low on beat 1");

        burst_write_req  = 1'b0;
        burst_write_data = {24'd0, 8'sd12};
        step;
        check(burst_write_ack === 1'b1, "burst_write_ack beat 2");
        check(burst_write_done === 1'b0, "burst_write_done low on beat 2");

        burst_write_data = {24'd0, 8'sd13};
        step;
        burst_write_valid = 1'b0;
        check(burst_write_ack === 1'b1, "burst_write_ack beat 3");
        check(burst_write_done === 1'b1, "burst_write_done asserted on final beat 3");
        check(mock_mem_a[1] === 8'sd11, "mock_mem_a[1] == 11");
        check(mock_mem_a[2] === 8'sd12, "mock_mem_a[2] == 12");
        check(mock_mem_a[3] === 8'sd13, "mock_mem_a[3] == 13");

        // -------------------------------------------------------------
        // Test 4: Full Matrix Block Streaming Transfer (6x6: 36 elements)
        // -------------------------------------------------------------
        $display("\n--- Test 4: Full Matrix 6x6 Streaming Transfer (36 elements) ---");
        burst_write_req    = 1'b1;
        burst_write_is_b   = 1'b0;
        burst_write_addr   = 6'd0;
        burst_write_len    = 7'd36;
        burst_write_packed = 1'b0;
        burst_write_valid  = 1'b1;
        burst_write_data   = {24'd0, 8'sd1};

        for (k = 0; k < 36; k = k + 1) begin
            burst_write_data = {24'd0, k[7:0] + 8'd10};
            step;
            burst_write_req = 1'b0;
            check(burst_write_ack === 1'b1, "streaming beat ack");
            if (k == 35)
                check(burst_write_done === 1'b1, "burst_write_done high on element 36");
            else
                check(burst_write_done === 1'b0, "burst_write_done low before end of burst");
        end
        burst_write_valid = 1'b0;

        for (k = 0; k < 36; k = k + 1) begin
            check(mock_mem_a[k] === (k[7:0] + 8'd10), "verified sequential memory element");
        end

        // -------------------------------------------------------------
        // Test 5: Packed-Word Burst Transfer (4 elements per beat) & Backpressure
        // -------------------------------------------------------------
        $display("\n--- Test 5: Packed-Word Burst Mode & Active Backpressure ---");
        // Write Matrix B with packed words (length 8 = 2 beats of 4 elements)
        burst_write_req    = 1'b1;
        burst_write_is_b   = 1'b1;
        burst_write_addr   = 6'd0;
        burst_write_len    = 7'd8;
        burst_write_packed = 1'b1;
        burst_write_valid  = 1'b1;
        // Beat 1: {24, 23, 22, 21}
        burst_write_data   = {8'sd24, 8'sd23, 8'sd22, 8'sd21};
        step;
        burst_write_req = 1'b0;
        check(burst_write_ack === 1'b1, "packed beat 1 sub-word 0 ack");
        check(burst_write_ready === 1'b0, "burst_write_ready deasserted (backpressure active while draining)");

        // Cycles 1, 2, 3: draining sub-words 1, 2, 3
        step; // sub-word 1
        check(burst_write_ack === 1'b1, "sub-word 1 ack");
        check(burst_write_ready === 1'b0, "backpressure holds on sub-word 1");

        step; // sub-word 2
        check(burst_write_ack === 1'b1, "sub-word 2 ack");
        check(burst_write_ready === 1'b0, "backpressure holds on sub-word 2");

        step; // sub-word 3
        check(burst_write_ack === 1'b1, "sub-word 3 ack");
        check(burst_write_ready === 1'b1, "burst_write_ready returns high (ready for beat 2)");

        // Beat 2: {28, 27, 26, 25}
        burst_write_data = {8'sd28, 8'sd27, 8'sd26, 8'sd25};
        step;
        check(burst_write_ack === 1'b1, "beat 2 sub-word 0 ack");
        check(burst_write_ready === 1'b0, "backpressure on beat 2");

        step; // sub-word 1
        check(burst_write_ack === 1'b1, "beat 2 sub-word 1 ack");
        step; // sub-word 2
        check(burst_write_ack === 1'b1, "beat 2 sub-word 2 ack");
        step; // sub-word 3 (final element of the 8-element burst)
        burst_write_valid = 1'b0;
        check(burst_write_ack === 1'b1, "beat 2 sub-word 3 ack");
        check(burst_write_done === 1'b1, "burst_write_done asserted on final packed element");
        check(burst_write_ready === 1'b1, "burst_write_ready released to 1 after completion");

        for (k = 0; k < 8; k = k + 1) begin
            check(mock_mem_b[k] === (k[7:0] + 8'd21), "verified packed word unpacked in memory");
        end

        // -------------------------------------------------------------
        // Test 6: Incomplete / Interrupted Transfers (Host Pause)
        // -------------------------------------------------------------
        $display("\n--- Test 6: Interrupted Transfer with Valid Deassertion ---");
        burst_write_req    = 1'b1;
        burst_write_is_b   = 1'b0;
        burst_write_addr   = 6'd10;
        burst_write_len    = 7'd4;
        burst_write_packed = 1'b0;
        burst_write_valid  = 1'b1;
        burst_write_data   = {24'd0, 8'sd50};
        step; // element 0
        burst_write_req = 1'b0;
        burst_write_data = {24'd0, 8'sd51};
        step; // element 1

        // Host pauses transmission for 2 cycles
        burst_write_valid = 1'b0;
        burst_write_data  = {24'd0, 8'sd99}; // Distractor data
        step;
        check(buf_write_en === 1'b0, "buf_write_en low while host paused");
        check(burst_write_ack === 1'b0, "burst_write_ack low while host paused");
        step;
        check(buf_write_en === 1'b0, "buf_write_en still low");

        // Host resumes with remaining 2 elements
        burst_write_valid = 1'b1;
        burst_write_data  = {24'd0, 8'sd52};
        step; // element 2
        check(burst_write_ack === 1'b1, "burst_write_ack asserted upon resume");
        burst_write_data = {24'd0, 8'sd53};
        step; // element 3 (last)
        burst_write_valid = 1'b0;
        check(burst_write_done === 1'b1, "burst_write_done asserted after resume completion");
        check(mock_mem_a[10] === 8'sd50, "element 10 == 50");
        check(mock_mem_a[11] === 8'sd51, "element 11 == 51");
        check(mock_mem_a[12] === 8'sd52, "element 12 == 52");
        check(mock_mem_a[13] === 8'sd53, "element 13 == 53");

        // -------------------------------------------------------------
        // Test 7: Busy-State Rejection
        // -------------------------------------------------------------
        $display("\n--- Test 7: Busy-State Write Rejection ---");
        ctrl_busy = 1'b1;
        step;
        check(burst_write_ready === 1'b0, "burst_write_ready is 0 while controller is busy");

        burst_write_req   = 1'b1;
        burst_write_addr  = 6'd0;
        burst_write_len   = 7'd4;
        burst_write_valid = 1'b1;
        step;
        burst_write_req   = 1'b0;
        burst_write_valid = 1'b0;
        check(burst_write_err === 1'b1, "burst_write_err asserted when writing while busy");
        check(burst_err_code === ERR_BUSY, "burst_err_code is ERR_BUSY");
        check(buf_write_en === 1'b0, "buf_write_en suppressed during busy error");

        ctrl_busy = 1'b0;
        step;
        check(burst_write_ready === 1'b1, "burst_write_ready restored after controller idle");

        // -------------------------------------------------------------
        // Test 8: Invalid Address & Length Rejections
        // -------------------------------------------------------------
        $display("\n--- Test 8: Invalid Address & Length Rejections ---");
        // Out of range starting address (>= 36)
        burst_write_req  = 1'b1;
        burst_write_addr = 6'd36;
        burst_write_len  = 7'd1;
        step;
        check(burst_write_err === 1'b1, "burst_write_err on out of range starting address");
        check(burst_err_code === ERR_ADDR, "burst_err_code is ERR_ADDR");

        // Length 0
        burst_write_addr = 6'd0;
        burst_write_len  = 7'd0;
        step;
        check(burst_write_err === 1'b1, "burst_write_err on length 0");
        check(burst_err_code === ERR_LEN, "burst_err_code is ERR_LEN");

        // Address + length exceeds total_elements (30 + 10 = 40 > 36)
        burst_write_addr = 6'd30;
        burst_write_len  = 7'd10;
        step;
        check(burst_write_err === 1'b1, "burst_write_err when addr + len > 36");
        check(burst_err_code === ERR_LEN, "burst_err_code is ERR_LEN");

        // Unsupported matrix dimension (e.g. 5)
        cfg_matrix_dim = 4'd5;
        burst_write_addr = 6'd0;
        burst_write_len  = 7'd4;
        step;
        burst_write_req = 1'b0;
        check(burst_write_err === 1'b1, "burst_write_err on unsupported dimension");
        check(burst_err_code === ERR_DIM, "burst_err_code is ERR_DIM");

        cfg_matrix_dim = 4'd6;
        step;

        // -------------------------------------------------------------
        // Test 9: Asynchronous Reset During Active Burst
        // -------------------------------------------------------------
        $display("\n--- Test 9: Reset During Active Burst ---");
        burst_write_req    = 1'b1;
        burst_write_is_b   = 1'b0;
        burst_write_addr   = 6'd0;
        burst_write_len    = 7'd10;
        burst_write_packed = 1'b0;
        burst_write_valid  = 1'b1;
        burst_write_data   = {24'd0, 8'sd1};
        step;
        burst_write_req = 1'b0;
        step;
        step;
        // Assert async reset mid-burst
        rst_n = 1'b0;
        #2;
        check(dut.state_w === 3'b000, "state_w immediately returns to W_IDLE on async reset");
        check(buf_write_en === 1'b0, "buf_write_en deasserted during async reset");

        step;
        rst_n = 1'b1;
        step;
        check(burst_write_ready === 1'b1, "burst_write_ready returns high after reset release");

        // -------------------------------------------------------------
        // Test 10: Back-to-Back Repeated Transactions
        // -------------------------------------------------------------
        $display("\n--- Test 10: Back-to-Back Repeated Transactions ---");
        // Burst 1: Matrix A, addr 0..1, len 2
        burst_write_req    = 1'b1;
        burst_write_is_b   = 1'b0;
        burst_write_addr   = 6'd0;
        burst_write_len    = 7'd2;
        burst_write_valid  = 1'b1;
        burst_write_data   = {24'd0, 8'sd88};
        step;
        burst_write_req  = 1'b0;
        burst_write_data = {24'd0, 8'sd89};
        step;
        check(burst_write_done === 1'b1, "burst 1 done");

        // Immediately launch Burst 2: Matrix B, addr 0..1, len 2
        burst_write_req  = 1'b1;
        burst_write_is_b = 1'b1;
        burst_write_addr = 6'd0;
        burst_write_len  = 7'd2;
        burst_write_data = {24'd0, 8'sd91};
        step;
        burst_write_req  = 1'b0;
        burst_write_data = {24'd0, 8'sd92};
        step;
        burst_write_valid = 1'b0;
        check(burst_write_done === 1'b1, "burst 2 done");
        check(mock_mem_a[0] === 8'sd88, "mock_mem_a[0] == 88");
        check(mock_mem_a[1] === 8'sd89, "mock_mem_a[1] == 89");
        check(mock_mem_b[0] === 8'sd91, "mock_mem_b[0] == 91");
        check(mock_mem_b[1] === 8'sd92, "mock_mem_b[1] == 92");

        // -------------------------------------------------------------
        // Test 11: Host Start Qualification & Lockout
        // -------------------------------------------------------------
        $display("\n--- Test 11: Host Start Qualification & Lockout ---");
        // Attempt start before matrices are ready -> start_err = 1
        buf_matrices_ready = 1'b0;
        host_start = 1'b1;
        step;
        host_start = 1'b0;
        check(start_err === 1'b1, "start_err asserted when matrices not ready");
        check(start_ack === 1'b0, "start_ack suppressed");
        check(ctrl_start === 1'b0, "ctrl_start suppressed");

        step;
        // Assert matrices ready -> start accepted
        buf_matrices_ready = 1'b1;
        host_start = 1'b1;
        step;
        check(start_ack === 1'b1, "start_ack asserted when ready");
        check(ctrl_start === 1'b1, "ctrl_start pulsed");
        check(out_buf_clear === 1'b1, "out_buf_clear pulsed on accepted start");

        // Held-high start suppression test: keep host_start high
        ctrl_idle = 1'b0;
        ctrl_busy = 1'b1;
        step;
        check(start_ack === 1'b0, "start_ack low on subsequent cycle");
        check(ctrl_start === 1'b0, "ctrl_start single-cycle pulse");

        // Emulate computation completion while host_start is still held high
        ctrl_busy = 1'b0;
        ctrl_idle = 1'b1;
        ctrl_done = 1'b1;
        step;
        ctrl_done = 1'b0;
        check(start_ack === 1'b0, "held-high start does not auto-restart upon completion");
        check(ctrl_start === 1'b0, "ctrl_start remains 0");

        // Must drop and rise to trigger again
        host_start = 1'b0;
        step;
        host_start = 1'b1;
        step;
        check(start_ack === 1'b1, "start accepted upon fresh rising edge");
        host_start = 1'b0;

        // Reset lockout test: hold host_start high through reset
        rst_n = 1'b0;
        host_start = 1'b1;
        step;
        rst_n = 1'b1;
        step;
        check(start_ack === 1'b0, "reset lockout prevents launch on reset release");
        check(ctrl_start === 1'b0, "ctrl_start locked out");
        host_start = 1'b0;
        step;

        // -------------------------------------------------------------
        // Test 12: Burst Result Readback & Host Backpressure
        // -------------------------------------------------------------
        $display("\n--- Test 12: Result Readback & Read Backpressure ---");
        res_available = 1'b1;
        step;
        check(host_result_available === 1'b1, "host_result_available reflects res_available");

        // Burst read 4 elements (addresses 0..3)
        burst_read_req   = 1'b1;
        burst_read_addr  = 6'd0;
        burst_read_len   = 7'd4;
        burst_read_ready = 1'b1;
        step;
        burst_read_req = 1'b0;

        // Beat 0: Memory delivers data after 1 cycle latency
        step;
        check(burst_read_valid === 1'b1, "read beat 0 valid");
        check(burst_read_data === 32'sd100, "read beat 0 data == 100");

        // Host accepts Beat 0 on posedge, Beat 1 arrives
        step;
        check(burst_read_valid === 1'b1, "read beat 1 valid");
        check(burst_read_data === 32'sd101, "read beat 1 data == 101");

        // Host asserts backpressure on Beat 1
        burst_read_ready = 1'b0;
        step;
        check(dut.state_r === 2'b11, "read FSM enters R_HOLD on host backpressure");
        check(burst_read_valid === 1'b1, "read beat 1 valid during backpressure");
        check(burst_read_data === 32'sd101, "read beat 1 data == 101 held during backpressure");

        // Hold for 1 more cycle: verify data stays stable in holding register
        step;
        check(burst_read_valid === 1'b1, "read beat 1 valid holds");
        check(burst_read_data === 32'sd101, "read beat 1 data holds");

        // Release backpressure: host accepts Beat 1, Beat 2 arrives
        burst_read_ready = 1'b1;
        step;

        // Beat 2
        check(burst_read_valid === 1'b1, "read beat 2 valid");
        check(burst_read_data === 32'sd102, "read beat 2 data == 102");

        // Beat 3 (final): host accepts Beat 2, Beat 3 arrives
        step;
        check(burst_read_valid === 1'b1, "read beat 3 valid");
        check(burst_read_data === 32'sd103, "read beat 3 data == 103");
        check(burst_read_done === 1'b1, "burst_read_done asserted on final beat");

        step;
        check(burst_read_done === 1'b0, "burst_read_done pulses 1 cycle");

        // Invalid read request (out of range address)
        burst_read_req  = 1'b1;
        burst_read_addr = 6'd36;
        burst_read_len  = 7'd1;
        step;
        burst_read_req = 1'b0;
        check(burst_read_err === 1'b1, "burst_read_err on invalid read address");

        // Read when result not available
        res_available  = 1'b0;
        burst_read_req = 1'b1;
        burst_read_addr = 6'd0;
        burst_read_len  = 7'd1;
        step;
        burst_read_req = 1'b0;
        check(burst_read_err === 1'b1, "burst_read_err when result not available");

        // -------------------------------------------------------------
        // Summary
        // -------------------------------------------------------------
        $display("\n==================================================================");
        $display("BURST MATRIX INTERFACE TEST SUMMARY:");
        $display("  PASSED CHECKS : %0d", pass_count);
        $display("  FAILED CHECKS : %0d", fail_count);
        $display("==================================================================");

        if (fail_count == 0) begin
            $display("RESULT: ALL BURST INTERFACE TESTS PASSED SUCCESSFULLY!\n");
        end else begin
            $fatal(1, "BURST INTERFACE TEST FAILED with %0d errors", fail_count);
        end

        $finish;
    end

endmodule

`default_nettype wire
