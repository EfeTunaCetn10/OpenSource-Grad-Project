`timescale 1ns/1ps

// Fixed-name 64-PE configuration used as the Vivado synthesis top.
module systolic_array_8x8 (
    input  logic             clk,
    input  logic             rst_n,
    input  logic             start,
    output logic             start_ready,
    input  logic [3:0]       active_rows,
    input  logic [3:0]       active_cols,
    input  logic [3:0]       k_len,
    input  logic [511:0]     a_matrix_flat,
    input  logic [511:0]     b_matrix_flat,
    output logic             busy,
    output logic             done,
    output logic             c_valid,
    output logic             config_error,
    output logic [2047:0]    c_matrix_flat,
    output logic [63:0]      mac_fire_flat
);
    systolic_tile_engine #(
        .ROWS(8), .COLS(8), .K_MAX(8), .DATA_WIDTH(8), .ACC_WIDTH(32)
    ) u_engine (.*);

endmodule
