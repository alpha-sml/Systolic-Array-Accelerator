`timescale 1ns / 1ps
`default_nettype none

module mac_unit #(
    parameter integer DATA_WIDTH = 8,
    parameter integer ACC_WIDTH  = 32
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         clr,
    input  wire                         en,
    input  wire signed [DATA_WIDTH-1:0] a,
    input  wire signed [DATA_WIDTH-1:0] b,
    output reg  signed [ACC_WIDTH-1:0]  acc
);

    wire signed [(2*DATA_WIDTH)-1:0] product = a * b;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            acc <= {ACC_WIDTH{1'b0}};
        else if (clr)
            acc <= {ACC_WIDTH{1'b0}};
        else if (en)
            acc <= acc + product;
    end

endmodule

`default_nettype wire
