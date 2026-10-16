`timescale 1ns/1ps
// Compatibility wrapper: Conv2 now uses the shared parameterized repacker.
module v3_conv2_repack (
    input logic clk, rst_n, restart,
    input logic s_valid, output logic s_ready,
    input logic [63:0] s_data, input logic s_last,
    output logic m_valid, input logic m_ready,
    output logic [63:0] m_data, output logic m_last,
    output logic done, output logic error
);
    tile_major_repack #(.CHANNELS(16),.HEIGHT(16),.WIDTH(16)) u_generic(.*);
endmodule
