// pe_interconnect
// Parameterized 2D systolic interconnect for an ARRAY_SIZE x ARRAY_SIZE
// output-stationary Processing Element (PE) grid.
//
// Responsibilities
//   - Route west boundary A inputs into column 0 and cascade registered
//     eastward A outputs from PE(i, j-1) to PE(i, j).
//   - Route north boundary B inputs into row 0 and cascade registered
//     southward B outputs from PE(i-1, j) to PE(i, j).
//   - Expose the final eastward A outputs (column ARRAY_SIZE-1) and final
//     southward B outputs (row ARRAY_SIZE-1).
//
// All PE-to-PE links connect registered PE outputs (pe_a_out, pe_b_out) to
// neighbor PE inputs (pe_a_in, pe_b_in); there are no combinational bypass
// paths or extra pipeline registers inside the interconnect.
//
// Packed-vector indexing convention (0-indexed row i, column j):
//   - a_west [(i * DATA_WIDTH) +: DATA_WIDTH]                  : row i west input
//   - a_east [(i * DATA_WIDTH) +: DATA_WIDTH]                  : row i east output
//   - b_north[(j * DATA_WIDTH) +: DATA_WIDTH]                  : col j north input
//   - b_south[(j * DATA_WIDTH) +: DATA_WIDTH]                  : col j south output
//   - pe_*   [((i * ARRAY_SIZE + j) * DATA_WIDTH) +: DATA_WIDTH] : PE(i, j) operand

`timescale 1ns / 1ps
`default_nettype none

module pe_interconnect #(
    parameter integer ARRAY_SIZE = 3,
    parameter integer DATA_WIDTH = 8
) (
    input  wire [(ARRAY_SIZE*DATA_WIDTH)-1:0]            a_west,
    input  wire [(ARRAY_SIZE*DATA_WIDTH)-1:0]            b_north,
    input  wire [(ARRAY_SIZE*ARRAY_SIZE*DATA_WIDTH)-1:0] pe_a_out,
    input  wire [(ARRAY_SIZE*ARRAY_SIZE*DATA_WIDTH)-1:0] pe_b_out,
    output wire [(ARRAY_SIZE*ARRAY_SIZE*DATA_WIDTH)-1:0] pe_a_in,
    output wire [(ARRAY_SIZE*ARRAY_SIZE*DATA_WIDTH)-1:0] pe_b_in,
    output wire [(ARRAY_SIZE*DATA_WIDTH)-1:0]            a_east,
    output wire [(ARRAY_SIZE*DATA_WIDTH)-1:0]            b_south
);

    genvar i;
    genvar j;

    generate
        for (i = 0; i < ARRAY_SIZE; i = i + 1) begin : gen_row
            // Final eastward A boundary output comes from the rightmost PE in row i.
            assign a_east[(i * DATA_WIDTH) +: DATA_WIDTH] =
                pe_a_out[(((i * ARRAY_SIZE) + (ARRAY_SIZE - 1)) * DATA_WIDTH) +: DATA_WIDTH];

            for (j = 0; j < ARRAY_SIZE; j = j + 1) begin : gen_col
                // Horizontal A link: west boundary for col 0, else registered PE(i, j-1) a_out.
                if (j == 0) begin : gen_west_in
                    assign pe_a_in[(((i * ARRAY_SIZE) + j) * DATA_WIDTH) +: DATA_WIDTH] =
                        a_west[(i * DATA_WIDTH) +: DATA_WIDTH];
                end else begin : gen_east_link
                    assign pe_a_in[(((i * ARRAY_SIZE) + j) * DATA_WIDTH) +: DATA_WIDTH] =
                        pe_a_out[(((i * ARRAY_SIZE) + (j - 1)) * DATA_WIDTH) +: DATA_WIDTH];
                end

                // Vertical B link: north boundary for row 0, else registered PE(i-1, j) b_out.
                if (i == 0) begin : gen_north_in
                    assign pe_b_in[(((i * ARRAY_SIZE) + j) * DATA_WIDTH) +: DATA_WIDTH] =
                        b_north[(j * DATA_WIDTH) +: DATA_WIDTH];
                end else begin : gen_south_link
                    assign pe_b_in[(((i * ARRAY_SIZE) + j) * DATA_WIDTH) +: DATA_WIDTH] =
                        pe_b_out[((((i - 1) * ARRAY_SIZE) + j) * DATA_WIDTH) +: DATA_WIDTH];
                end
            end
        end

        for (j = 0; j < ARRAY_SIZE; j = j + 1) begin : gen_south_out
            // Final southward B boundary output comes from the bottom PE in col j.
            assign b_south[(j * DATA_WIDTH) +: DATA_WIDTH] =
                pe_b_out[((((ARRAY_SIZE - 1) * ARRAY_SIZE) + j) * DATA_WIDTH) +: DATA_WIDTH];
        end
    endgenerate

endmodule

`default_nettype wire
