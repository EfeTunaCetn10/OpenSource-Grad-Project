`timescale 1ns/1ps

// ADR-003 INT32 accumulator -> INT8 activation requantizer.
//   y = clamp(lo, 127, (acc * m0 + (1 << (n-1))) >>> n), lo = relu_en ? 0 : -128
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
    localparam int PROD_WIDTH = ACC_WIDTH + M0_WIDTH;  // 50 under the ADR-003 default sizing

    localparam logic signed [PROD_WIDTH-1:0] LO_RELU    = '0;
    localparam logic signed [PROD_WIDTH-1:0] LO_NO_RELU = -128;
    localparam logic signed [PROD_WIDTH-1:0] HI         = 127;

    logic signed [PROD_WIDTH-1:0] product;
    logic signed [PROD_WIDTH-1:0] half_ulp;
    logic signed [PROD_WIDTH-1:0] y_raw;
    logic signed [PROD_WIDTH-1:0] lo;
    logic signed [PROD_WIDTH-1:0] y_clamped;
    logic signed [OUT_WIDTH-1:0]  y_comb;

    initial begin
        if (M0_WIDTH < 2)
            $error("M0_WIDTH must leave room for the always-zero sign guard bit");
        if (PROD_WIDTH <= OUT_WIDTH)
            $error("PROD_WIDTH must exceed OUT_WIDTH");
    end

    always_comb begin
        // ADR-003 Tuzak #1: every operand here must stay signed, or the
        // whole expression -- and the >>> below -- silently turns unsigned
        // and corrupts every negative acc.
        product  = acc * m0;
        half_ulp = (n == '0) ? '0 : (PROD_WIDTH'(1) << (n - 1));

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
