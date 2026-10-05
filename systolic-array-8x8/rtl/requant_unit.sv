`timescale 1ns/1ps

// INT32 accumulator -> INT8 requantizer with a bias-aware, five-stage path.
//
// One arithmetic operation per stage:
//
//   S0  a = wrap32(in_acc + cfg_bias_q), overflow detect, config sampled
//   S1  p = a * cfg_m0                                   (DSP48E1)
//   S2  s = p + half_ulp(n)                              (64-bit add)
//   S3  raw = cfg_bypass ? a : (s >>> n)                 (64-bit shift)
//   S4  clamp(lo, 127) -> out_y, out_sat                 (result register)
//
// Why five and not three: the original S2 did the rounding add, the variable
// shift and both clamp comparisons in a single cycle.  Out-of-context
// synthesis for xc7z020clg400-1 at 100 MHz measured that path at 12.502 ns
// (WNS -2.509 ns, 34 logic levels, 24 CARRY4, from s1_shift_n to s2_sat).
// Logic alone was 6.423 ns of it, so the stage was structurally over-long
// rather than badly placed.  ADR-014 anticipated this outcome: it listed
// `LAT = 3` as awaiting measurement and stated that the contract is a fixed,
// knowable latency rather than the number itself.  This is that measurement
// resolved.  Splitting only shift from clamp -- the LAT = 4 the ADR sketched
// -- would have left the decode, the 64-bit adder and the 64-bit variable
// shifter together in one stage, so the split goes one step further and gives
// each operator its own cycle.
//
// The arithmetic expressions themselves are unchanged, which is deliberate:
// the numeric path is the one part of this module proven bit-exact against
// requant_ref.py over the 60k vector set, so the re-pipelining inserts
// registers and moves nothing across an operator.  The single exception is
// half_ulp, now written as an indexed bit assignment rather than
// `1 << (n-1)`.  It is the same value for every n in [1, 63] -- a one-hot
// constant -- but the indexed form synthesises as a 6-to-64 decoder, one LUT
// level, instead of a data shifter.  That is what makes it affordable to keep
// in front of the adder rather than spending a sixth stage on it.
//
// The output side keeps two older-result skid registers in front of S4.  They
// allow the arithmetic pipe to continue while the output is stalled; when all
// three result slots are occupied, one global clock-enable freezes S0..S3, S4
// and both skid registers together.  A unit therefore holds at most seven
// beats in flight -- four arithmetic stages plus three result slots -- which
// is the bound a surrounding metadata queue has to cover.
//
// in_ready is written only in the clocked block. It is consequently a
// registered capacity indication: out_ready can affect it only after a clock
// edge, and there is no combinational out_ready -> in_ready path.
module requant_unit #(
    parameter int ACC_W  = 32,
    parameter int M0_W   = 18,
    parameter int PROD_W = 64,
    parameter int LAT    = 5
) (
    input  logic                    clk,
    input  logic                    rst_n,

    input  logic signed [ACC_W-1:0] cfg_bias_q,
    input  logic signed [M0_W-1:0]  cfg_m0,
    input  logic        [5:0]       cfg_shift_n,
    input  logic                    cfg_relu,
    input  logic                    cfg_bypass,

    input  logic                    in_valid,
    output logic                    in_ready,
    input  logic signed [ACC_W-1:0] in_acc,
    input  logic                    in_k_last,
    input  logic                    in_last,

    output logic                    out_valid,
    input  logic                    out_ready,
    output logic signed [7:0]       out_y,
    output logic signed [PROD_W-1:0] out_y_raw,
    output logic                    out_last,
    output logic                    out_sat,
    output logic                    out_ovf
);
    localparam int MUL_W = ACC_W + M0_W;

    // S0: bias addition and the sampled configuration bundle.
    logic s0_valid;
    logic signed [ACC_W-1:0] s0_a;
    logic signed [M0_W-1:0]  s0_m0;
    logic [5:0]              s0_shift_n;
    logic                    s0_relu;
    logic                    s0_bypass;
    logic                    s0_last;
    logic                    s0_ovf;

    // S1: the signed product.  `a` travels alongside it because cfg_bypass
    // reads it through in S3.
    logic s1_valid;
    logic signed [PROD_W-1:0] s1_product;
    logic signed [ACC_W-1:0]  s1_a;
    logic [5:0]               s1_shift_n;
    logic                     s1_relu;
    logic                     s1_bypass;
    logic                     s1_last;
    logic                     s1_ovf;

    // S2: product plus the half-ULP rounding offset, before the shift.
    logic s2_valid;
    logic signed [PROD_W-1:0] s2_sum;
    logic signed [ACC_W-1:0]  s2_a;
    logic [5:0]               s2_shift_n;
    logic                     s2_relu;
    logic                     s2_bypass;
    logic                     s2_last;
    logic                     s2_ovf;

    // S3: the shifted (or bypassed) pre-clamp value.  This is what the
    // out_y_raw port exposes.
    logic s3_valid;
    logic signed [PROD_W-1:0] s3_raw;
    logic                     s3_relu;
    logic                     s3_bypass;
    logic                     s3_last;
    logic                     s3_ovf;

    // S4 plus the two skid slots form the result queue, in output order.
    logic s4_valid;
    logic signed [7:0]        s4_y;
    logic signed [PROD_W-1:0] s4_y_raw;
    logic                     s4_last;
    logic                     s4_sat;
    logic                     s4_ovf;

    logic skid0_valid, skid1_valid;
    logic signed [7:0]        skid0_y, skid1_y;
    logic signed [PROD_W-1:0] skid0_y_raw, skid1_y_raw;
    logic                     skid0_last, skid1_last;
    logic                     skid0_sat, skid1_sat;
    logic                     skid0_ovf, skid1_ovf;

    logic signed [ACC_W:0]   s0_sum_ext;
    logic signed [ACC_W-1:0] s0_a_comb;
    logic                    s0_ovf_comb;

    logic signed [MUL_W-1:0]  s1_a_mul;
    logic signed [MUL_W-1:0]  s1_m0_mul;
    logic signed [MUL_W-1:0]  s1_product_mul;
    logic signed [PROD_W-1:0] s1_product_comb;

    logic signed [PROD_W-1:0] half_ulp_comb;
    logic signed [PROD_W-1:0] s2_sum_comb;

    logic signed [PROD_W-1:0] bypass_raw_comb;
    logic signed [PROD_W-1:0] shifted_comb;
    logic signed [PROD_W-1:0] s3_raw_comb;

    logic signed [PROD_W-1:0] lo_comb;
    logic signed [PROD_W-1:0] clamped_comb;
    logic signed [7:0]        y_comb;
    logic                     sat_comb;

    logic accept;
    logic pipe_ce;

    // The next result queue is represented as skid0, skid1, and S4 in
    // output order. S4 is kept as the direct, no-stall output so the normal
    // latency remains the four arithmetic stages plus this register.
    logic next_s4_valid, next_skid0_valid, next_skid1_valid;
    logic signed [7:0] next_s4_y, next_skid0_y, next_skid1_y;
    logic signed [PROD_W-1:0] next_s4_y_raw, next_skid0_y_raw, next_skid1_y_raw;
    logic next_s4_last, next_skid0_last, next_skid1_last;
    logic next_s4_sat, next_skid0_sat, next_skid1_sat;
    logic next_s4_ovf, next_skid0_ovf, next_skid1_ovf;

    // --- into S0: the bias addition -------------------------------------
    always_comb begin
        s0_sum_ext = $signed({in_acc[ACC_W-1], in_acc}) +
                     $signed({cfg_bias_q[ACC_W-1], cfg_bias_q});
        s0_a_comb = s0_sum_ext[ACC_W-1:0];
        s0_ovf_comb = (in_acc[ACC_W-1] == cfg_bias_q[ACC_W-1]) &&
                      (s0_a_comb[ACC_W-1] != in_acc[ACC_W-1]);
    end

    // --- into S1: the multiply ------------------------------------------
    always_comb begin
        // Widen both factors before multiplying. This makes the signed
        // multiply width explicit instead of relying on expression sizing.
        s1_a_mul = s0_a;
        s1_m0_mul = s0_m0;
        s1_product_mul = s1_a_mul * s1_m0_mul;
        s1_product_comb = s1_product_mul;
    end

    // --- into S2: half-ULP decode and the rounding add ------------------
    always_comb begin
        // half_ulp is 0 for n = 0 and 2**(n-1) otherwise: a one-hot
        // constant, so an indexed bit assignment states it directly. n is
        // six bits and the initial block below requires PROD_W to hold the
        // n = 63 case, so the index is always in range.
        half_ulp_comb = '0;
        if (s1_shift_n != 0)
            half_ulp_comb[s1_shift_n - 1'b1] = 1'b1;

        s2_sum_comb = s1_product + half_ulp_comb;
    end

    // --- into S3: the shift and the bypass read-through -----------------
    always_comb begin
        bypass_raw_comb = s2_a;
        shifted_comb = s2_sum >>> s2_shift_n;
        s3_raw_comb = s2_bypass ? bypass_raw_comb : shifted_comb;
    end

    // --- into S4: saturation --------------------------------------------
    always_comb begin
        lo_comb = s3_relu ? '0 : -128;

        if (s3_raw > $signed(127)) begin
            clamped_comb = $signed(127);
            sat_comb = 1'b1;
        end else if (s3_raw < lo_comb) begin
            clamped_comb = lo_comb;
            sat_comb = 1'b1;
        end else begin
            clamped_comb = s3_raw;
            sat_comb = 1'b0;
        end
        // Bypass exposes the wrapped INT32 value for debug; it is not a
        // quantization operation, so it must never contribute to sat_seen.
        if (s3_bypass)
            sat_comb = 1'b0;
        y_comb = clamped_comb[7:0];
    end

    always_comb begin
        out_valid = s4_valid;
        out_y = s4_y;
        out_y_raw = s4_y_raw;
        out_last = s4_last;
        out_sat = s4_sat;
        out_ovf = s4_ovf;
    end

    assign accept = in_valid && in_ready;
    assign pipe_ce = !(skid0_valid && skid1_valid && s4_valid && !out_ready);

    // Queue update. The compact logical order is S4, skid0, skid1. S4 is the
    // direct output; the two skid registers are appended only when S4 is
    // blocked. Compacting on every pop makes the ordering explicit.
    always_comb begin
        next_skid0_valid = skid0_valid;
        next_skid1_valid = skid1_valid;
        next_s4_valid = s4_valid;
        next_skid0_y = skid0_y;
        next_skid1_y = skid1_y;
        next_s4_y = s4_y;
        next_skid0_y_raw = skid0_y_raw;
        next_skid1_y_raw = skid1_y_raw;
        next_s4_y_raw = s4_y_raw;
        next_skid0_last = skid0_last;
        next_skid1_last = skid1_last;
        next_s4_last = s4_last;
        next_skid0_sat = skid0_sat;
        next_skid1_sat = skid1_sat;
        next_s4_sat = s4_sat;
        next_skid0_ovf = skid0_ovf;
        next_skid1_ovf = skid1_ovf;
        next_s4_ovf = s4_ovf;

        if (pipe_ce) begin
            if (out_valid && out_ready) begin
                // Pop S4, then append old skid0, old skid1, and the new
                // result from S3 into the compact three-entry queue.
                next_s4_valid = 1'b0;
                next_skid0_valid = 1'b0;
                next_skid1_valid = 1'b0;
                if (skid0_valid) begin
                    next_s4_valid = 1'b1;
                    next_s4_y = skid0_y;
                    next_s4_y_raw = skid0_y_raw;
                    next_s4_last = skid0_last;
                    next_s4_sat = skid0_sat;
                    next_s4_ovf = skid0_ovf;
                    if (skid1_valid) begin
                        next_skid0_valid = 1'b1;
                        next_skid0_y = skid1_y;
                        next_skid0_y_raw = skid1_y_raw;
                        next_skid0_last = skid1_last;
                        next_skid0_sat = skid1_sat;
                        next_skid0_ovf = skid1_ovf;
                        if (s3_valid) begin
                            next_skid1_valid = 1'b1;
                            next_skid1_y = y_comb;
                            next_skid1_y_raw = s3_raw;
                            next_skid1_last = s3_last;
                            next_skid1_sat = sat_comb;
                            next_skid1_ovf = s3_ovf;
                        end
                    end else if (s3_valid) begin
                        next_skid0_valid = 1'b1;
                        next_skid0_y = y_comb;
                        next_skid0_y_raw = s3_raw;
                        next_skid0_last = s3_last;
                        next_skid0_sat = sat_comb;
                        next_skid0_ovf = s3_ovf;
                    end
                end else if (skid1_valid) begin
                    next_s4_valid = 1'b1;
                    next_s4_y = skid1_y;
                    next_s4_y_raw = skid1_y_raw;
                    next_s4_last = skid1_last;
                    next_s4_sat = skid1_sat;
                    next_s4_ovf = skid1_ovf;
                    if (s3_valid) begin
                        next_skid0_valid = 1'b1;
                        next_skid0_y = y_comb;
                        next_skid0_y_raw = s3_raw;
                        next_skid0_last = s3_last;
                        next_skid0_sat = sat_comb;
                        next_skid0_ovf = s3_ovf;
                    end
                end else if (s3_valid) begin
                    next_s4_valid = 1'b1;
                    next_s4_y = y_comb;
                    next_s4_y_raw = s3_raw;
                    next_s4_last = s3_last;
                    next_s4_sat = sat_comb;
                    next_s4_ovf = s3_ovf;
                end
            end else if (s3_valid) begin
                // No pop: append to the first free result slot.
                if (!s4_valid) begin
                    next_s4_valid = 1'b1;
                    next_s4_y = y_comb;
                    next_s4_y_raw = s3_raw;
                    next_s4_last = s3_last;
                    next_s4_sat = sat_comb;
                    next_s4_ovf = s3_ovf;
                end else if (!skid0_valid) begin
                    next_skid0_valid = 1'b1;
                    next_skid0_y = y_comb;
                    next_skid0_y_raw = s3_raw;
                    next_skid0_last = s3_last;
                    next_skid0_sat = sat_comb;
                    next_skid0_ovf = s3_ovf;
                end else if (!skid1_valid) begin
                    next_skid1_valid = 1'b1;
                    next_skid1_y = y_comb;
                    next_skid1_y_raw = s3_raw;
                    next_skid1_last = s3_last;
                    next_skid1_sat = sat_comb;
                    next_skid1_ovf = s3_ovf;
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            in_ready <= 1'b1;
            s0_valid <= 1'b0;
            s1_valid <= 1'b0;
            s2_valid <= 1'b0;
            s3_valid <= 1'b0;
            s4_valid <= 1'b0;
            skid0_valid <= 1'b0;
            skid1_valid <= 1'b0;
            s0_a <= '0;
            s0_m0 <= '0;
            s0_shift_n <= '0;
            s0_relu <= 1'b0;
            s0_bypass <= 1'b0;
            s0_last <= 1'b0;
            s0_ovf <= 1'b0;
            s1_product <= '0;
            s1_a <= '0;
            s1_shift_n <= '0;
            s1_relu <= 1'b0;
            s1_bypass <= 1'b0;
            s1_last <= 1'b0;
            s1_ovf <= 1'b0;
            s2_sum <= '0;
            s2_a <= '0;
            s2_shift_n <= '0;
            s2_relu <= 1'b0;
            s2_bypass <= 1'b0;
            s2_last <= 1'b0;
            s2_ovf <= 1'b0;
            s3_raw <= '0;
            s3_relu <= 1'b0;
            s3_bypass <= 1'b0;
            s3_last <= 1'b0;
            s3_ovf <= 1'b0;
            s4_y <= '0;
            s4_y_raw <= '0;
            s4_last <= 1'b0;
            s4_sat <= 1'b0;
            s4_ovf <= 1'b0;
            skid0_y <= '0;
            skid1_y <= '0;
            skid0_y_raw <= '0;
            skid1_y_raw <= '0;
            skid0_last <= 1'b0;
            skid1_last <= 1'b0;
            skid0_sat <= 1'b0;
            skid1_sat <= 1'b0;
            skid0_ovf <= 1'b0;
            skid1_ovf <= 1'b0;
        end else begin
            // A registered ready must also be safe if out_ready goes low in
            // the next cycle. Do not advertise an input handshake while the
            // result queue is already full or the global pipe-enable is
            // frozen; otherwise a sample could be accepted into a stage that
            // is intentionally not advancing.
            in_ready <= pipe_ce &&
                        !(next_s4_valid && next_skid0_valid && next_skid1_valid);

            if (pipe_ce) begin
                s0_valid <= accept && in_k_last;
                if (accept && in_k_last) begin
                    s0_a <= s0_a_comb;
                    s0_m0 <= cfg_m0;
                    s0_shift_n <= cfg_shift_n;
                    s0_relu <= cfg_relu;
                    s0_bypass <= cfg_bypass;
                    s0_last <= in_last;
                    s0_ovf <= s0_ovf_comb;
                end

                s1_valid <= s0_valid;
                if (s0_valid) begin
                    s1_product <= s1_product_comb;
                    s1_a <= s0_a;
                    s1_shift_n <= s0_shift_n;
                    s1_relu <= s0_relu;
                    s1_bypass <= s0_bypass;
                    s1_last <= s0_last;
                    s1_ovf <= s0_ovf;
                end

                s2_valid <= s1_valid;
                if (s1_valid) begin
                    s2_sum <= s2_sum_comb;
                    s2_a <= s1_a;
                    s2_shift_n <= s1_shift_n;
                    s2_relu <= s1_relu;
                    s2_bypass <= s1_bypass;
                    s2_last <= s1_last;
                    s2_ovf <= s1_ovf;
                end

                s3_valid <= s2_valid;
                if (s2_valid) begin
                    s3_raw <= s3_raw_comb;
                    s3_relu <= s2_relu;
                    s3_bypass <= s2_bypass;
                    s3_last <= s2_last;
                    s3_ovf <= s2_ovf;
                end

                s4_valid <= next_s4_valid;
                s4_y <= next_s4_y;
                s4_y_raw <= next_s4_y_raw;
                s4_last <= next_s4_last;
                s4_sat <= next_s4_sat;
                s4_ovf <= next_s4_ovf;
                skid0_valid <= next_skid0_valid;
                skid1_valid <= next_skid1_valid;
                skid0_y <= next_skid0_y;
                skid1_y <= next_skid1_y;
                skid0_y_raw <= next_skid0_y_raw;
                skid1_y_raw <= next_skid1_y_raw;
                skid0_last <= next_skid0_last;
                skid1_last <= next_skid1_last;
                skid0_sat <= next_skid0_sat;
                skid1_sat <= next_skid1_sat;
                skid0_ovf <= next_skid0_ovf;
                skid1_ovf <= next_skid1_ovf;
            end
        end
    end

    property p_last_requires_k_last;
        @(posedge clk) disable iff (!rst_n)
            (in_valid && in_last) |-> in_k_last;
    endproperty

    // A frame boundary is by definition a completed reduction, so this
    // combination cannot arise from a correct upstream engine. The message
    // names it as an illegal input rather than a datapath bug, because that
    // is where the fix belongs.
    //
    // The assertion is labelled so a testbench that deliberately drives the
    // violation can bracket it with $assertoff/$asserton on this label. It
    // deliberately keeps no expected-failure counter and no testbench-visible
    // flag: ADR-014 rejected hierarchical testbench access into this module
    // for exactly this reason -- such hooks break silently when the module is
    // reorganised, and a DUT carrying verification state is a DUT that can
    // behave differently under test than in the field.
    a_last_requires_k_last: assert property (p_last_requires_k_last)
        else $error("Illegal upstream input: in_valid && in_last requires in_k_last");

    initial begin
        if (ACC_W < 2)
            $error("ACC_W must be at least 2");
        if (M0_W < 2)
            $error("M0_W must leave room for the signed guard bit");
        if (PROD_W < ACC_W + M0_W)
            $error("PROD_W must hold the signed product");
        // ADR-003 allows n in [0, 63], so the largest half-ULP sets bit 62
        // and the indexed assignment in the S2 block needs room for it.
        if (PROD_W < 63)
            $error("PROD_W must hold the half-ULP of the largest shift (n = 63)");
        if (LAT != 5)
            $warning("This implementation has S0..S4 latency; LAT is expected to be 5");
    end
endmodule
