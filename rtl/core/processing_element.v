`timescale 1ns / 1ps
`default_nettype none

module processing_element #(
    parameter integer DATA_WIDTH = 8,
    parameter integer ACC_WIDTH  = 32
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         compute_en,
    input  wire                         array_clear,
    input  wire signed [DATA_WIDTH-1:0] a_in,
    input  wire signed [DATA_WIDTH-1:0] b_in,
    output reg  signed [DATA_WIDTH-1:0] a_out,
    output reg  signed [DATA_WIDTH-1:0] b_out,
    output wire signed [ACC_WIDTH-1:0]  acc_out
);

    // Register operands A (Eastward) and B (Southward)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_out <= {DATA_WIDTH{1'b0}};
            b_out <= {DATA_WIDTH{1'b0}};
        end else if (compute_en) begin
            a_out <= a_in;
            b_out <= b_in;
        end
    end

    // Multiply-Accumulate unit
    mac_unit #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH (ACC_WIDTH)
    ) u_mac (
        .clk   (clk),
        .rst_n (rst_n),
        .clr   (array_clear),
        .en    (compute_en),
        .a     (a_in),
        .b     (b_in),
        .acc   (acc_out)
    );

endmodule

`default_nettype wire
