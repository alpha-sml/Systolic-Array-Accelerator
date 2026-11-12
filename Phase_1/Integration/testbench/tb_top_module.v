`timescale 1ns / 1ps

module tb_top_module;

    localparam integer NUM_ELEMENTS = 9;
    localparam integer ADDR_WIDTH = 4;

    reg clk;
    reg rst_n;
    reg host_start;
    wire host_ready;
    wire host_busy;
    wire host_done;
    wire start_ack;
    wire start_err;
    reg host_write_en;
    reg host_write_is_b;
    reg [ADDR_WIDTH-1:0] host_write_addr;
    reg signed [7:0] host_write_data;
    wire host_write_ack;
    wire matrices_ready;
    reg host_read_en;
    reg [ADDR_WIDTH-1:0] host_read_addr;
    wire signed [31:0] host_read_data;
    wire host_read_valid;
    wire host_result_available;

    integer passed;
    integer failed;
    integer i;
    integer timeout;
    reg signed [7:0] matrix_a [0:NUM_ELEMENTS-1];
    reg signed [7:0] matrix_b [0:NUM_ELEMENTS-1];
    reg signed [31:0] expected [0:NUM_ELEMENTS-1];

    top_module dut (
        .clk                 (clk),
        .rst_n               (rst_n),
        .host_start          (host_start),
        .host_ready          (host_ready),
        .host_busy           (host_busy),
        .host_done           (host_done),
        .start_ack           (start_ack),
        .start_err           (start_err),
        .host_write_en       (host_write_en),
        .host_write_is_b     (host_write_is_b),
        .host_write_addr     (host_write_addr),
        .host_write_data     (host_write_data),
        .host_write_ack      (host_write_ack),
        .matrices_ready      (matrices_ready),
        .host_read_en        (host_read_en),
        .host_read_addr      (host_read_addr),
        .host_read_data      (host_read_data),
        .host_read_valid     (host_read_valid),
        .host_result_available(host_result_available)
    );

    always #5 clk = ~clk;

    task automatic check;
        input condition;
        input [255:0] message;
        begin
            if (condition) begin
                passed = passed + 1;
            end else begin
                failed = failed + 1;
                $display("FAIL: %0s at time %0t", message, $time);
            end
        end
    endtask

    task automatic write_element;
        input matrix_b_select;
        input integer address;
        input integer value;
        begin
            @(negedge clk);
            host_write_en = 1'b1;
            host_write_is_b = matrix_b_select;
            host_write_addr = address;
            host_write_data = value;
            #1;
            check(host_write_ack, "valid matrix write was not acknowledged");
            @(negedge clk);
            host_write_en = 1'b0;
        end
    endtask

    task automatic load_matrices;
        begin
            for (i = 0; i < NUM_ELEMENTS; i = i + 1)
                write_element(1'b0, i, matrix_a[i]);
            for (i = 0; i < NUM_ELEMENTS; i = i + 1)
                write_element(1'b1, i, matrix_b[i]);
            @(posedge clk);
            #1 check(matrices_ready, "matrices_ready did not assert after all writes");
        end
    endtask

    task automatic compute_expected;
        integer row;
        integer col;
        integer k;
        begin
            for (row = 0; row < 3; row = row + 1) begin
                for (col = 0; col < 3; col = col + 1) begin
                    expected[(row * 3) + col] = 0;
                    for (k = 0; k < 3; k = k + 1)
                        expected[(row * 3) + col] =
                            expected[(row * 3) + col] +
                            matrix_a[(row * 3) + k] * matrix_b[(k * 3) + col];
                end
            end
        end
    endtask

    task automatic start_and_wait;
        begin
            @(negedge clk);
            host_start = 1'b1;
            @(posedge clk);
            #1;
            check(start_ack, "complete operation was not acknowledged");
            check(!start_err, "complete operation reported start_err");
            @(negedge clk);
            host_start = 1'b0;
            @(posedge clk);
            #1 check(host_busy, "controller did not enter busy state");
            timeout = 0;
            while (!host_result_available && timeout < 40) begin
                @(posedge clk);
                #1 timeout = timeout + 1;
            end
            check(host_result_available, "result did not become available");
            check(!host_busy, "controller remained busy after result capture");
        end
    endtask

    task automatic read_result;
        input integer address;
        input integer expected_value;
        begin
            @(negedge clk);
            host_read_en = 1'b1;
            host_read_addr = address;
            @(posedge clk);
            #1;
            check(host_read_valid, "valid result read did not assert read_valid");
            check($signed(host_read_data) == expected_value, "result readback mismatch");
            @(negedge clk);
            host_read_en = 1'b0;
        end
    endtask

    task automatic read_all_results;
        begin
            for (i = 0; i < NUM_ELEMENTS; i = i + 1)
                read_result(i, expected[i]);
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        host_start = 1'b0;
        host_write_en = 1'b0;
        host_write_is_b = 1'b0;
        host_write_addr = 0;
        host_write_data = 0;
        host_read_en = 1'b0;
        host_read_addr = 0;
        passed = 0;
        failed = 0;

        #2;
        check(!host_busy && !host_done && !host_result_available,
              "reset status outputs are not inactive");
        check(!matrices_ready && !host_ready, "reset did not clear readiness");
        #8 rst_n = 1'b1;
        @(posedge clk);
        #1 check(dut.controller_idle, "controller did not return to idle after reset");

        matrix_a[0] = 1; matrix_a[1] = 2; matrix_a[2] = 3;
        matrix_a[3] = 4; matrix_a[4] = 5; matrix_a[5] = 6;
        matrix_a[6] = 7; matrix_a[7] = 8; matrix_a[8] = 9;
        matrix_b[0] = 9; matrix_b[1] = 8; matrix_b[2] = 7;
        matrix_b[3] = 6; matrix_b[4] = 5; matrix_b[5] = 4;
        matrix_b[6] = 3; matrix_b[7] = 2; matrix_b[8] = 1;
        compute_expected();

        write_element(1'b0, 0, matrix_a[0]);
        write_element(1'b1, 0, matrix_b[0]);
        @(negedge clk);
        host_start = 1'b1;
        @(posedge clk);
        #1 check(start_err && !host_busy, "incomplete matrix start was accepted");
        @(negedge clk);
        host_start = 1'b0;
        @(negedge clk);
        host_write_en = 1'b1;
        host_write_is_b = 1'b0;
        host_write_addr = 9;
        host_write_data = 55;
        #1;
        check(!host_write_ack, "invalid write address was acknowledged");
        load_matrices();
        start_and_wait();
        read_all_results();

        @(negedge clk);
        host_read_en = 1'b1;
        host_read_addr = 9;
        @(posedge clk);
        #1 check(!host_read_valid, "invalid read address asserted read_valid");
        @(negedge clk);
        host_read_en = 1'b0;

        matrix_a[0] = 2; matrix_a[1] = -1; matrix_a[2] = 3;
        matrix_a[3] = 0; matrix_a[4] = 4; matrix_a[5] = -2;
        matrix_a[6] = -3; matrix_a[7] = 5; matrix_a[8] = 1;
        matrix_b[0] = 1; matrix_b[1] = 2; matrix_b[2] = -1;
        matrix_b[3] = -2; matrix_b[4] = 0; matrix_b[5] = 3;
        matrix_b[6] = 4; matrix_b[7] = -1; matrix_b[8] = 2;
        compute_expected();
        load_matrices();
        @(negedge clk);
        host_start = 1'b1;
        @(posedge clk);
        #1 check(start_ack, "new operation was not acknowledged");
        @(posedge clk);
        #1;
        check(!host_result_available, "new operation did not clear old result");
        check(host_busy, "signed operation did not become busy");
        @(negedge clk);
        host_write_en = 1'b1;
        host_write_addr = 0;
        host_write_data = 99;
        #1 check(!host_write_ack, "busy write was acknowledged");
        @(negedge clk);
        host_write_en = 1'b0;
        timeout = 0;
        while (!host_result_available && timeout < 40) begin
            @(posedge clk);
            #1 timeout = timeout + 1;
        end
        check(host_result_available, "signed result did not become available");
        @(negedge clk);
        host_start = 1'b0;
        read_all_results();

        @(negedge clk);
        host_start = 1'b1;
        @(posedge clk);
        #1 check(start_ack, "held-high start was not accepted initially");
        @(posedge clk);
        #1 check(host_busy && !host_result_available,
                 "held-high start did not launch exactly one operation");
        timeout = 0;
        while (!host_result_available && timeout < 40) begin
            @(posedge clk);
            #1 timeout = timeout + 1;
        end
        check(host_result_available && !host_busy,
              "held-high start did not complete cleanly");
        @(posedge clk);
        #1 check(!host_busy, "held-high start retriggered after completion");
        @(negedge clk);
        host_start = 1'b0;

        matrix_a[0] = 1; matrix_a[1] = 0; matrix_a[2] = 0;
        matrix_a[3] = 0; matrix_a[4] = 1; matrix_a[5] = 0;
        matrix_a[6] = 0; matrix_a[7] = 0; matrix_a[8] = 1;
        matrix_b[0] = 2; matrix_b[1] = 3; matrix_b[2] = 4;
        matrix_b[3] = 5; matrix_b[4] = 6; matrix_b[5] = 7;
        matrix_b[6] = 8; matrix_b[7] = 9; matrix_b[8] = 10;
        compute_expected();
        load_matrices();
        @(negedge clk);
        host_start = 1'b1;
        @(posedge clk);
        #1 check(start_ack, "fresh rising start was not acknowledged");
        @(negedge clk);
        host_start = 1'b0;
        @(posedge clk);
        #1 check(host_busy, "reset-operation did not become busy");
        #2 rst_n = 1'b0;
        #1 check(!host_busy && !host_result_available && !matrices_ready,
                 "reset during operation did not clear status");
        #7 rst_n = 1'b1;
        @(posedge clk);
        #1 check(dut.controller_idle, "controller did not return idle after mid-operation reset");
        load_matrices();
        start_and_wait();
        read_all_results();

        $display("PASS: %0d checks passed, %0d checks failed", passed, failed);
        if (failed != 0)
            $fatal(1, "top-level integration test failed");
        $finish;
    end

endmodule
