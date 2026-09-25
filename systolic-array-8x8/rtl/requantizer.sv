`timescale 1ns/1ps

// ADR-003 INT32 accumulator -> INT8 activation requantizer.
//   y = clamp(lo, 127, (acc * m0 + half_ulp) >>> n), lo = relu_en ? 0 : -128
//   half_ulp = 0 for n=0, otherwise 2**(n-1); n is in [0, 63].
//
// Scope: this unit is the multiply/round/shift/clamp path only. Bias
// addition happens upstream, in the accumulator domain (see ADR-003 "Bias"
// row) -- e.g. by seeding the PE's acc_reg before the K-accumulation starts
// -- and is not this module's concern. T_NUM_REQ_001 exercises exactly the
// path implemented here, standalone, before the array exists.
module requantizer #(
    parameter int ACC_WIDTH = 32,
    parameter int M0_WIDTH  = 18,  // unsigned value in [2**16, 2**17); MSB always 0
    parameter int N_WIDTH   = 6,
    parameter int OUT_WIDTH = 8
) (
    input  logic                        clk,
    input  logic                        rst_n,
    input  logic                        valid_in,
    input  logic signed [ACC_WIDTH-1:0] acc,
    input  logic signed [M0_WIDTH-1:0]  m0,
    input  logic        [N_WIDTH-1:0]   n,
    input  logic                        relu_en,
    output logic                        valid_out,
    output logic signed [OUT_WIDTH-1:0] y
);
    // 32x18 multiplication needs at most 50 bits, but the rounding offset
    // for n=63 is 2**62. Keep the entire multiply/add/shift path signed 64-bit.
    localparam int CALC_WIDTH = 64;

    localparam logic signed [CALC_WIDTH-1:0] LO_RELU    = '0;
    localparam logic signed [CALC_WIDTH-1:0] LO_NO_RELU = -128;
    localparam logic signed [CALC_WIDTH-1:0] HI         = 127;

    logic signed [CALC_WIDTH-1:0] product;
    logic signed [CALC_WIDTH-1:0] half_ulp;
    logic signed [CALC_WIDTH-1:0] y_raw;
    logic signed [CALC_WIDTH-1:0] lo;
    logic signed [CALC_WIDTH-1:0] y_clamped;
    logic signed [OUT_WIDTH-1:0]  y_comb;

    initial begin
        if (M0_WIDTH < 2)
            $error("M0_WIDTH must leave room for the always-zero sign guard bit");
        if (ACC_WIDTH + M0_WIDTH > CALC_WIDTH - 1)
            $error("ACC_WIDTH + M0_WIDTH must leave a rounding guard bit in CALC_WIDTH");
        if (N_WIDTH > 6)
            $error("N_WIDTH cannot exceed 6 with a signed 64-bit rounding path");
        if (CALC_WIDTH <= OUT_WIDTH)
            $error("CALC_WIDTH must exceed OUT_WIDTH");
    end

    always_comb begin
        // ADR-003 Tuzak #1: every operand here must stay signed, or the
        // whole expression -- and the >>> below -- silently turns unsigned
        // and corrupts every negative acc.
        product  = acc * m0;
        half_ulp = (n == '0) ? '0 : (CALC_WIDTH'(1) << (n - 1));

        // >>> is required, not >> -- this is the other half of Tuzak #1.
        // Python's `>>` on a negative int is the same floor shift, which is
        // what lets requant_ref() match this line with no compensation.
        y_raw = (product + half_ulp) >>> n;

        lo = relu_en ? LO_RELU : LO_NO_RELU;

        if (y_raw > HI)
            y_clamped = HI;
        else if (y_raw < lo)
            y_clamped = lo;
        else
            y_clamped = y_raw;

        y_comb = OUT_WIDTH'(y_clamped);
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            y         <= '0;
            valid_out <= 1'b0;
        end else begin
            y         <= y_comb;
            valid_out <= valid_in;
        end
    end

endmodule
