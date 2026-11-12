// tb_processing_element.v
// Comprehensive self-checking testbench for processing_element
//
// Verification scope:
// 1. Asynchronous active-low reset assertion (clears accumulator, a_out, b_out)
// 2. Eastward propagation of operand A (1-cycle registered latency)
// 3. Southward propagation of operand B (1-cycle registered latency)
// 4. Simultaneous propagation and MAC accumulation over consecutive cycles
// 5. Accumulator clear via array_clear (synchronous clear)
// 6. Priority of array_clear over compute_en (no accumulation on clear cycle)
// 7. Hold behavior when compute_en is low (acc_out, a_out, b_out stable)
// 8. Controller timing contract verification (LOAD -> COMPUTE -> DONE cycle sequence)
// 9. Multi-PE systolic cascade verification (verifying neighbor-to-neighbor propagation)

`timescale 1ns / 1ps
`default_nettype none

module tb_processing_element;

    localparam integer DATA_WIDTH = 8;
    localparam integer ACC_WIDTH  = 32;
    localparam integer CLK_PERIOD = 10;

    reg                             clk;
    reg                             rst_n;
    reg                             compute_en;
    reg                             array_clear;
    reg  signed [DATA_WIDTH-1:0]    a_in;
    reg  signed [DATA_WIDTH-1:0]    b_in;
    wire signed [DATA_WIDTH-1:0]    a_out;
    wire signed [DATA_WIDTH-1:0]    b_out;
    wire signed [ACC_WIDTH-1:0]     acc_out;

    integer errors;
    integer test_count;

    // Instantiate Single Processing Element Under Test (UUT)
    processing_element #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH (ACC_WIDTH)
    ) uut (
        .clk        (clk),
        .rst_n      (rst_n),
        .compute_en (compute_en),
        .array_clear(array_clear),
        .a_in       (a_in),
        .b_in       (b_in),
        .a_out      (a_out),
        .b_out      (b_out),
        .acc_out    (acc_out)
    );

    // Multi-PE Cascade Verification: 3 PEs connected Eastward
    reg  signed [DATA_WIDTH-1:0]    chain_a_in;
    reg  signed [DATA_WIDTH-1:0]    chain_b_in0;
    reg  signed [DATA_WIDTH-1:0]    chain_b_in1;
    reg  signed [DATA_WIDTH-1:0]    chain_b_in2;
    wire signed [DATA_WIDTH-1:0]    chain_a_out0;
    wire signed [DATA_WIDTH-1:0]    chain_a_out1;
    wire signed [DATA_WIDTH-1:0]    chain_a_out2;
    wire signed [DATA_WIDTH-1:0]    chain_b_out0;
    wire signed [DATA_WIDTH-1:0]    chain_b_out1;
    wire signed [DATA_WIDTH-1:0]    chain_b_out2;
    wire signed [ACC_WIDTH-1:0]     chain_acc0;
    wire signed [ACC_WIDTH-1:0]     chain_acc1;
    wire signed [ACC_WIDTH-1:0]     chain_acc2;

    processing_element #(DATA_WIDTH, ACC_WIDTH) pe_chain_0 (
        .clk        (clk),
        .rst_n      (rst_n),
        .compute_en (compute_en),
        .array_clear(array_clear),
        .a_in       (chain_a_in),
        .b_in       (chain_b_in0),
        .a_out      (chain_a_out0),
        .b_out      (chain_b_out0),
        .acc_out    (chain_acc0)
    );

    processing_element #(DATA_WIDTH, ACC_WIDTH) pe_chain_1 (
        .clk        (clk),
        .rst_n      (rst_n),
        .compute_en (compute_en),
        .array_clear(array_clear),
        .a_in       (chain_a_out0),
        .b_in       (chain_b_in1),
        .a_out      (chain_a_out1),
        .b_out      (chain_b_out1),
        .acc_out    (chain_acc1)
    );

    processing_element #(DATA_WIDTH, ACC_WIDTH) pe_chain_2 (
        .clk        (clk),
        .rst_n      (rst_n),
        .compute_en (compute_en),
        .array_clear(array_clear),
        .a_in       (chain_a_out1),
        .b_in       (chain_b_in2),
        .a_out      (chain_a_out2),
        .b_out      (chain_b_out2),
        .acc_out    (chain_acc2)
    );

    // Multi-PE Vertical Cascade Verification: 3 PEs connected Southward (PE0 -> PE1 -> PE2)
    reg  signed [DATA_WIDTH-1:0]    vert_b_in;
    reg  signed [DATA_WIDTH-1:0]    vert_a_in0;
    reg  signed [DATA_WIDTH-1:0]    vert_a_in1;
    reg  signed [DATA_WIDTH-1:0]    vert_a_in2;
    wire signed [DATA_WIDTH-1:0]    vert_a_out0;
    wire signed [DATA_WIDTH-1:0]    vert_a_out1;
    wire signed [DATA_WIDTH-1:0]    vert_a_out2;
    wire signed [DATA_WIDTH-1:0]    vert_b_out0;
    wire signed [DATA_WIDTH-1:0]    vert_b_out1;
    wire signed [DATA_WIDTH-1:0]    vert_b_out2;
    wire signed [ACC_WIDTH-1:0]     vert_acc0;
    wire signed [ACC_WIDTH-1:0]     vert_acc1;
    wire signed [ACC_WIDTH-1:0]     vert_acc2;

    processing_element #(DATA_WIDTH, ACC_WIDTH) pe_vert_0 (
        .clk        (clk),
        .rst_n      (rst_n),
        .compute_en (compute_en),
        .array_clear(array_clear),
        .a_in       (vert_a_in0),
        .b_in       (vert_b_in),
        .a_out      (vert_a_out0),
        .b_out      (vert_b_out0),
        .acc_out    (vert_acc0)
    );

    processing_element #(DATA_WIDTH, ACC_WIDTH) pe_vert_1 (
        .clk        (clk),
        .rst_n      (rst_n),
        .compute_en (compute_en),
        .array_clear(array_clear),
        .a_in       (vert_a_in1),
        .b_in       (vert_b_out0),
        .a_out      (vert_a_out1),
        .b_out      (vert_b_out1),
        .acc_out    (vert_acc1)
    );

    processing_element #(DATA_WIDTH, ACC_WIDTH) pe_vert_2 (
        .clk        (clk),
        .rst_n      (rst_n),
        .compute_en (compute_en),
        .array_clear(array_clear),
        .a_in       (vert_a_in2),
        .b_in       (vert_b_out1),
        .a_out      (vert_a_out2),
        .b_out      (vert_b_out2),
        .acc_out    (vert_acc2)
    );

    // Clock generation: 100 MHz
    initial clk = 1'b0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    // Check helper task
    task automatic check_pe;
        input signed [DATA_WIDTH-1:0] exp_a_out;
        input signed [DATA_WIDTH-1:0] exp_b_out;
        input signed [ACC_WIDTH-1:0]  exp_acc;
        input [1023:0] test_name;
        begin
            test_count = test_count + 1;
            if (acc_out !== exp_acc || a_out !== exp_a_out || b_out !== exp_b_out) begin
                $display("ERROR [Test %0d: %0s]:", test_count, test_name);
                if (acc_out !== exp_acc)
                    $display("       acc_out mismatch: Expected %0d (0x%08h), got %0d (0x%08h)",
                             exp_acc, exp_acc, acc_out, acc_out);
                if (a_out !== exp_a_out)
                    $display("       a_out mismatch: Expected %0d (0x%02h), got %0d (0x%02h)",
                             exp_a_out, exp_a_out, a_out, a_out);
                if (b_out !== exp_b_out)
                    $display("       b_out mismatch: Expected %0d (0x%02h), got %0d (0x%02h)",
                             exp_b_out, exp_b_out, b_out, b_out);
                errors = errors + 1;
            end else begin
                $display("PASS  [Test %0d: %0s]: a_out=%0d, b_out=%0d, acc_out=%0d",
                         test_count, test_name, a_out, b_out, acc_out);
            end
        end
    endtask

    // Clock advance helper
    task automatic step;
        begin
            @(posedge clk);
            #1; // Sample shortly after clock edge
        end
    endtask

    initial begin
        $dumpfile("build/tb_processing_element.vcd");
        $dumpvars(0, tb_processing_element);

        errors      = 0;
        test_count  = 0;
        clk         = 1'b0;
        rst_n       = 1'b1;
        compute_en  = 1'b0;
        array_clear = 1'b0;
        a_in        = 0;
        b_in        = 0;
        chain_a_in  = 0;
        chain_b_in0 = 0;
        chain_b_in1 = 0;
        chain_b_in2 = 0;
        vert_b_in   = 0;
        vert_a_in0  = 0;
        vert_a_in1  = 0;
        vert_a_in2  = 0;

        $display("================================================================");
        $display("Starting Processing Element Testbench (tb_processing_element)");
        $display("================================================================");

        // -------------------------------------------------------------
        // Test 1: Asynchronous Reset Assertion & Deassertion
        // -------------------------------------------------------------
        #2;
        rst_n = 1'b0;
        #1;
        check_pe(8'sd0, 8'sd0, 32'sd0, "Async reset immediate assert: all outputs 0");

        step;
        check_pe(8'sd0, 8'sd0, 32'sd0, "Reset held through clock edge");

        rst_n = 1'b1;
        step;
        check_pe(8'sd0, 8'sd0, 32'sd0, "Post-reset idle state");

        // -------------------------------------------------------------
        // Test 2: Eastward (A) and Southward (B) Registered Propagation
        // -------------------------------------------------------------
        compute_en = 1'b1;
        a_in       = 8'sd25;
        b_in       = 8'sd35;
        step;
        // On clock edge:
        // a_in registered to a_out, b_in registered to b_out,
        // acc_out accumulates 0 + (25 * 35) = 875
        check_pe(8'sd25, 8'sd35, 32'sd875, "Cycle 1: a_out=25, b_out=35, acc=875");

        // Second cycle:
        a_in = -8'sd10;
        b_in = 8'sd20;
        step;
        // a_out gets -10, b_out gets 20, acc gets 875 + (-10 * 20) = 675
        check_pe(-8'sd10, 8'sd20, 32'sd675, "Cycle 2: a_out=-10, b_out=20, acc=675");

        // Third cycle:
        a_in = 8'sd15;
        b_in = -8'sd4;
        step;
        // acc gets 675 + (15 * -4) = 675 - 60 = 615
        check_pe(8'sd15, -8'sd4, 32'sd615, "Cycle 3: a_out=15, b_out=-4, acc=615");

        // -------------------------------------------------------------
        // Test 3: Hold Behavior when compute_en is Disabled (compute_en = 0)
        // -------------------------------------------------------------
        compute_en = 1'b0;
        a_in       = 8'sd120; // Change inputs, should NOT be sampled
        b_in       = -8'sd99;
        step;
        check_pe(8'sd15, -8'sd4, 32'sd615, "Hold cycle 1: compute_en=0, outputs hold stable");

        step;
        check_pe(8'sd15, -8'sd4, 32'sd615, "Hold cycle 2: compute_en=0, outputs still hold");

        // -------------------------------------------------------------
        // Test 4: Synchronous Clear via array_clear
        // -------------------------------------------------------------
        // During LOAD phase last beat, array_clear is asserted while compute_en is 0
        array_clear = 1'b1;
        compute_en  = 1'b0;
        step;
        // acc_out must be cleared to 0; propagation registers hold previous values
        check_pe(8'sd15, -8'sd4, 32'sd0, "array_clear: acc_out clears to 0, a_out/b_out hold");

        array_clear = 1'b0;
        step;
        check_pe(8'sd15, -8'sd4, 32'sd0, "Post-clear: acc_out remains 0");

        // -------------------------------------------------------------
        // Test 5: Priority of array_clear over compute_en
        // -------------------------------------------------------------
        compute_en  = 1'b1;
        array_clear = 1'b1;
        a_in        = 8'sd50;
        b_in        = 8'sd50;
        step;
        // acc_out must remain 0 (no accumulation on clear edge)
        check_pe(8'sd50, 8'sd50, 32'sd0, "Clear priority: array_clear takes priority over compute_en");

        array_clear = 1'b0;
        compute_en  = 1'b0;
        step;

        // -------------------------------------------------------------
        // Test 6: Sequence Emulating Controller Schedule (3-term Dot Product)
        // -------------------------------------------------------------
        // Clear accumulator first
        array_clear = 1'b1;
        step;
        array_clear = 1'b0;

        // Vector A = [3, -5, 7], Vector B = [4, 6, -2]
        // Expected dot product = (3*4) + (-5*6) + (7*-2) = 12 - 30 - 14 = -32
        compute_en = 1'b1;

        // k = 0
        a_in = 8'sd3;
        b_in = 8'sd4;
        step;
        check_pe(8'sd3, 8'sd4, 32'sd12, "Dot Product k=0: acc = 12");

        // k = 1
        a_in = -8'sd5;
        b_in = 8'sd6;
        step;
        check_pe(-8'sd5, 8'sd6, -32'sd18, "Dot Product k=1: acc = 12 - 30 = -18");

        // k = 2
        a_in = 8'sd7;
        b_in = -8'sd2;
        step;
        check_pe(8'sd7, -8'sd2, -32'sd32, "Dot Product k=2: acc = -18 - 14 = -32");

        // Computation finishes, controller enters DONE: compute_en drops to 0
        compute_en = 1'b0;
        a_in       = 8'sd0;
        b_in       = 8'sd0;
        step;
        check_pe(8'sd7, -8'sd2, -32'sd32, "DONE phase: acc_out stable at -32 for readout");

        // -------------------------------------------------------------
        // Test 7: Multi-PE Cascade Chain Verification (Eastward Propagation)
        // -------------------------------------------------------------
        $display("----------------------------------------------------------------");
        $display("Verifying 3-PE Eastward Cascade: PE0 -> PE1 -> PE2");
        $display("----------------------------------------------------------------");
        // Clear chain
        array_clear = 1'b1;
        step;
        array_clear = 1'b0;

        compute_en  = 1'b1;
        chain_b_in0 = 8'sd1;
        chain_b_in1 = 8'sd1;
        chain_b_in2 = 8'sd1;

        // Inject a distinct value into chain_a_in at cycle 0
        chain_a_in  = 8'sd42;
        step;
        // At end of cycle 0:
        // PE0 has processed chain_a_in (42 * 1 = 42).
        // chain_a_out0 becomes 42.
        test_count = test_count + 1;
        if (chain_a_out0 === 8'sd42 && chain_acc0 === 32'sd42) begin
            $display("PASS  [Test %0d: Cascade cycle 0]: PE0 registered A=42 to chain_a_out0, acc0=42", test_count);
        end else begin
            $display("ERROR [Test %0d: Cascade cycle 0]: PE0 a_out0=%0d, acc0=%0d", test_count, chain_a_out0, chain_acc0);
            errors = errors + 1;
        end

        // Cycle 1: PE1 receives chain_a_out0 (42) at its input
        chain_a_in = 8'sd99;
        step;
        // At end of cycle 1:
        // PE1 processes A=42 (42 * 1 = 42).
        // chain_a_out1 becomes 42.
        // PE0 processes A=99 (acc0 = 42 + 99 = 141), chain_a_out0 becomes 99.
        test_count = test_count + 1;
        if (chain_a_out1 === 8'sd42 && chain_acc1 === 32'sd42) begin
            $display("PASS  [Test %0d: Cascade cycle 1]: PE1 registered A=42 to chain_a_out1, acc1=42", test_count);
        end else begin
            $display("ERROR [Test %0d: Cascade cycle 1]: PE1 a_out1=%0d, acc1=%0d", test_count, chain_a_out1, chain_acc1);
            errors = errors + 1;
        end

        // Cycle 2: PE2 receives chain_a_out1 (42) at its input
        chain_a_in = 8'sd0;
        step;
        // At end of cycle 2:
        // PE2 processes A=42 (42 * 1 = 42).
        // chain_a_out2 becomes 42.
        test_count = test_count + 1;
        if (chain_a_out2 === 8'sd42 && chain_acc2 === 32'sd42) begin
            $display("PASS  [Test %0d: Cascade cycle 2]: PE2 registered A=42 to chain_a_out2, acc2=42", test_count);
        end else begin
            $display("ERROR [Test %0d: Cascade cycle 2]: PE2 a_out2=%0d, acc2=%0d", test_count, chain_a_out2, chain_acc2);
            errors = errors + 1;
        end

        // -------------------------------------------------------------
        // Test 8: Multi-PE Vertical Cascade Verification (Southward Propagation)
        // -------------------------------------------------------------
        $display("----------------------------------------------------------------");
        $display("Verifying 3-PE Southward Cascade: PE0 -> PE1 -> PE2");
        $display("----------------------------------------------------------------");

        // Clear accumulators in the vertical chain
        array_clear = 1'b1;
        compute_en  = 1'b0;
        step;
        array_clear = 1'b0;

        test_count = test_count + 1;
        if (vert_b_out0 === 8'sd0 && vert_b_out1 === 8'sd0 && vert_b_out2 === 8'sd0 &&
            vert_acc0 === 32'sd0 && vert_acc1 === 32'sd0 && vert_acc2 === 32'sd0) begin
            $display("PASS  [Test %0d: Southward cascade post-clear state: all b_out and acc are 0]", test_count);
        end else begin
            $display("ERROR [Test %0d: Southward cascade post-clear state error]", test_count);
            errors = errors + 1;
        end

        // Enable compute with distinguishable A inputs for each PE
        compute_en  = 1'b1;
        vert_a_in0  = 8'sd2;
        vert_a_in1  = 8'sd3;
        vert_a_in2  = -8'sd4;

        // Cycle 0: Inject distinct signed value B = +45 into North input
        vert_b_in = 8'sd45;
        step;
        test_count = test_count + 1;
        if (vert_b_out0 === 8'sd45 && vert_b_out1 === 8'sd0 && vert_b_out2 === 8'sd0 &&
            vert_acc0 === 32'sd90 && vert_acc1 === 32'sd0 && vert_acc2 === 32'sd0) begin
            $display("PASS  [Test %0d: Southward cycle 0: PE0 received B=45, acc0=90; PE1/PE2 idle]", test_count);
        end else begin
            $display("ERROR [Test %0d: Southward cycle 0: b_out=(%0d,%0d,%0d), acc=(%0d,%0d,%0d)]",
                     test_count, vert_b_out0, vert_b_out1, vert_b_out2, vert_acc0, vert_acc1, vert_acc2);
            errors = errors + 1;
        end

        // Cycle 1: Inject second distinct signed value B = -75 into North input
        vert_b_in = -8'sd75;
        step;
        test_count = test_count + 1;
        if (vert_b_out0 === -8'sd75 && vert_b_out1 === 8'sd45 && vert_b_out2 === 8'sd0 &&
            vert_acc0 === -32'sd60 && vert_acc1 === 32'sd135 && vert_acc2 === 32'sd0) begin
            $display("PASS  [Test %0d: Southward cycle 1: PE0 gets B=-75, PE1 gets B=45, PE2 idle]", test_count);
        end else begin
            $display("ERROR [Test %0d: Southward cycle 1: b_out=(%0d,%0d,%0d), acc=(%0d,%0d,%0d)]",
                     test_count, vert_b_out0, vert_b_out1, vert_b_out2, vert_acc0, vert_acc1, vert_acc2);
            errors = errors + 1;
        end

        // Cycle 2: Inject third distinct signed value B = +105 into North input
        vert_b_in = 8'sd105;
        step;
        test_count = test_count + 1;
        if (vert_b_out0 === 8'sd105 && vert_b_out1 === -8'sd75 && vert_b_out2 === 8'sd45 &&
            vert_acc0 === 32'sd150 && vert_acc1 === -32'sd90 && vert_acc2 === -32'sd180) begin
            $display("PASS  [Test %0d: Southward cycle 2: PE0 gets B=105, PE1 gets B=-75, PE2 gets B=45]", test_count);
        end else begin
            $display("ERROR [Test %0d: Southward cycle 2: b_out=(%0d,%0d,%0d), acc=(%0d,%0d,%0d)]",
                     test_count, vert_b_out0, vert_b_out1, vert_b_out2, vert_acc0, vert_acc1, vert_acc2);
            errors = errors + 1;
        end

        // Cycle 3: Inject fourth value B = -120 to verify PE2 reaches B = -75
        vert_b_in = -8'sd120;
        step;
        test_count = test_count + 1;
        if (vert_b_out0 === -8'sd120 && vert_b_out1 === 8'sd105 && vert_b_out2 === -8'sd75 &&
            vert_acc0 === -32'sd90 && vert_acc1 === 32'sd225 && vert_acc2 === 32'sd120) begin
            $display("PASS  [Test %0d: Southward cycle 3: PE2 reached B=-75, acc=(%0d,%0d,%0d)]",
                     test_count, vert_acc0, vert_acc1, vert_acc2);
        end else begin
            $display("ERROR [Test %0d: Southward cycle 3: b_out=(%0d,%0d,%0d), acc=(%0d,%0d,%0d)]",
                     test_count, vert_b_out0, vert_b_out1, vert_b_out2, vert_acc0, vert_acc1, vert_acc2);
            errors = errors + 1;
        end

        // Verify hold behavior when compute_en = 0
        compute_en = 1'b0;
        vert_b_in  = 8'sd127;
        vert_a_in0 = 8'sd127;
        step;
        test_count = test_count + 1;
        if (vert_b_out0 === -8'sd120 && vert_b_out1 === 8'sd105 && vert_b_out2 === -8'sd75 &&
            vert_acc0 === -32'sd90 && vert_acc1 === 32'sd225 && vert_acc2 === 32'sd120) begin
            $display("PASS  [Test %0d: Southward cascade hold: compute_en=0, all b_out and acc hold]", test_count);
        end else begin
            $display("ERROR [Test %0d: Southward cascade hold failed]", test_count);
            errors = errors + 1;
        end

        step;
        test_count = test_count + 1;
        if (vert_b_out0 === -8'sd120 && vert_b_out1 === 8'sd105 && vert_b_out2 === -8'sd75 &&
            vert_acc0 === -32'sd90 && vert_acc1 === 32'sd225 && vert_acc2 === 32'sd120) begin
            $display("PASS  [Test %0d: Southward cascade hold cycle 2 verified]", test_count);
        end else begin
            $display("ERROR [Test %0d: Southward cascade hold cycle 2 failed]", test_count);
            errors = errors + 1;
        end

        // Verify reset behavior
        rst_n = 1'b0;
        #1;
        test_count = test_count + 1;
        if (vert_b_out0 === 8'sd0 && vert_b_out1 === 8'sd0 && vert_b_out2 === 8'sd0 &&
            vert_acc0 === 32'sd0 && vert_acc1 === 32'sd0 && vert_acc2 === 32'sd0) begin
            $display("PASS  [Test %0d: Southward cascade async reset clears all b_out and acc to 0]", test_count);
        end else begin
            $display("ERROR [Test %0d: Southward cascade async reset failed]", test_count);
            errors = errors + 1;
        end

        step;
        rst_n = 1'b1;
        step;

        // -------------------------------------------------------------
        // Summary
        // -------------------------------------------------------------
        $display("================================================================");
        if (errors == 0) begin
            $display("RESULT: ALL %0d PROCESSING ELEMENT TESTS PASSED!", test_count);
        end else begin
            $display("RESULT: PROCESSING ELEMENT TEST FAILED with %0d errors out of %0d tests!",
                     errors, test_count);
            $fatal(1);
        end
        $display("================================================================");
        $finish;
    end

    // Watchdog timer (50 us)
    initial begin
        #50000;
        $display("ERROR: Watchdog timeout in tb_processing_element!");
        $fatal(1);
    end

endmodule

`default_nettype wire
