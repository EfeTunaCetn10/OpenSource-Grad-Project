`timescale 1ns/1ps

// Fixed-name 64-PE streaming configuration used as the Vivado synthesis top.
module systolic_array_8x8 (
    input  logic             clk,
    input  logic             rst_n,
    input  logic             start,
    output logic             start_ready,
    input  logic [3:0]       active_rows,
    input  logic [3:0]       active_cols,
    input  logic [10:0]      k_len,
    input  logic             weight_valid,
    output logic             weight_ready,
    input  logic [63:0]      weight_data,
    input  logic             activation_valid,
    output logic             activation_ready,
    input  logic [63:0]      activation_data,
    output logic             busy,
    output logic             done,
    output logic             config_error,
    output logic             out_valid,
    input  logic             out_ready,
    output logic [255:0]     out_acc_flat,
    output logic [7:0]       out_lane_valid,
    output logic [3:0]       out_col,
    output logic             out_k_last,
    output logic             out_last,
    output logic             drain_stall,
    output logic [31:0]      cycle_count,
    output logic [63:0]      mac_fire_flat
);
    compute_engine #(
        .ROWS(8), .COLS(8), .K_MAX(1024), .DATA_WIDTH(8), .ACC_WIDTH(32)
    ) u_engine (.*);

endmodule
