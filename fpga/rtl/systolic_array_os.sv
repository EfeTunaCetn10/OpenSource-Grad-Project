`timescale 1ns/1ps

// Parameterized output-stationary PE mesh.
// The edge streams must already be time-skewed by row/column index.
module systolic_array_os #(
    parameter int ROWS       = 8,
    parameter int COLS       = 8,
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH  = 32
) (
    input  logic                              clk,
    input  logic                              rst_n,
    input  logic                              step,
    input  logic                              clear_acc,
    input  logic                              pipe_flush,
    input  logic [ROWS*DATA_WIDTH-1:0]        a_left_flat,
    input  logic [ROWS-1:0]                   a_left_valid,
    input  logic [COLS*DATA_WIDTH-1:0]        b_top_flat,
    input  logic [COLS-1:0]                   b_top_valid,
    output logic [ROWS*COLS*ACC_WIDTH-1:0]    c_acc_flat,
    output logic [ROWS*COLS-1:0]              mac_fire_flat
);
    logic signed [DATA_WIDTH-1:0] a_link [0:ROWS-1][0:COLS];
    logic signed [DATA_WIDTH-1:0] b_link [0:ROWS][0:COLS-1];
    logic                         av_link[0:ROWS-1][0:COLS];
    logic                         bv_link[0:ROWS][0:COLS-1];
    logic signed [ACC_WIDTH-1:0]  acc_link[0:ROWS-1][0:COLS-1];
    logic                         fire_link[0:ROWS-1][0:COLS-1];

    initial begin
        if (ROWS < 1 || COLS < 1)
            $error("ROWS and COLS must be positive");
    end

    genvar r;
    genvar c;
    generate
        for (r = 0; r < ROWS; r++) begin : g_a_edge
            assign a_link[r][0]  = $signed(a_left_flat[r*DATA_WIDTH +: DATA_WIDTH]);
            assign av_link[r][0] = a_left_valid[r];
        end

        for (c = 0; c < COLS; c++) begin : g_b_edge
            assign b_link[0][c]  = $signed(b_top_flat[c*DATA_WIDTH +: DATA_WIDTH]);
            assign bv_link[0][c] = b_top_valid[c];
        end

        for (r = 0; r < ROWS; r++) begin : g_row
            for (c = 0; c < COLS; c++) begin : g_col
                localparam int PE_INDEX = r*COLS + c;

                pe_os #(
                    .DATA_WIDTH(DATA_WIDTH),
                    .ACC_WIDTH (ACC_WIDTH)
                ) u_pe (
                    .clk        (clk),
                    .rst_n      (rst_n),
                    .step       (step),
                    .clear_acc  (clear_acc),
                    .pipe_flush (pipe_flush),
                    .a_in       (a_link[r][c]),
                    .b_in       (b_link[r][c]),
                    .a_valid_in (av_link[r][c]),
                    .b_valid_in (bv_link[r][c]),
                    .a_out      (a_link[r][c+1]),
                    .b_out      (b_link[r+1][c]),
                    .a_valid_out(av_link[r][c+1]),
                    .b_valid_out(bv_link[r+1][c]),
                    .acc_out    (acc_link[r][c]),
                    .mac_fire   (fire_link[r][c])
                );

                assign c_acc_flat[PE_INDEX*ACC_WIDTH +: ACC_WIDTH] = $unsigned(acc_link[r][c]);
                assign mac_fire_flat[PE_INDEX] = fire_link[r][c];
            end
        end
    endgenerate

endmodule
