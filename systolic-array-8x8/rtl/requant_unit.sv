`timescale 1ns/1ps

// INT32 accumulator -> INT8 requantizer with a bias-aware, three-stage path.
//
// S0 registers the wrapped bias addition and the complete configuration
// bundle. S1 registers the signed product. S2 registers the rounded,
// shifted, and clamped result. The output side has two older-result skid
// registers in front of S2. They allow the arithmetic pipe to continue while
// the output is stalled; when all three result slots are occupied, one global
// clock-enable freezes S0, S1, S2, and both skid registers together.
//
// in_ready is written only in the clocked block. It is consequently a
// registered capacity indication: out_ready can affect it only after a clock
// edge, and there is no combinational out_ready -> in_ready path.
module requant_unit #(
    parameter int ACC_W  = 32,
    parameter int M0_W   = 18,
    parameter int PROD_W = 64,
    parameter int LAT    = 3
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

    logic s0_valid;
    logic signed [ACC_W-1:0] s0_a;
    logic signed [M0_W-1:0]  s0_m0;
    logic [5:0]              s0_shift_n;
    logic                    s0_relu;
    logic                    s0_bypass;
    logic                    s0_last;
    logic                    s0_ovf;

    logic s1_valid;
    logic signed [PROD_W-1:0] s1_product;
    logic [5:0]               s1_shift_n;
    logic                     s1_relu;
    logic                     s1_bypass;
    logic signed [ACC_W-1:0]  s1_a;
    logic                     s1_last;
    logic                     s1_ovf;

    logic s2_valid;
    logic signed [7:0]        s2_y;
    logic signed [PROD_W-1:0] s2_y_raw;
    logic                     s2_last;
    logic                     s2_sat;
    logic                     s2_ovf;

    logic skid0_valid, skid1_valid;
    logic signed [7:0]        skid0_y, skid1_y;
    logic signed [PROD_W-1:0] skid0_y_raw, skid1_y_raw;
    logic                     skid0_last, skid1_last;
    logic                     skid0_sat, skid1_sat;
    logic                     skid0_ovf, skid1_ovf;

    logic signed [ACC_W:0] s0_sum_ext;
    logic signed [ACC_W-1:0] s0_a_comb;
    logic s0_ovf_comb;

    logic signed [MUL_W-1:0] s1_a_mul;
    logic signed [MUL_W-1:0] s1_m0_mul;
    logic signed [MUL_W-1:0] s1_product_mul;
    logic signed [PROD_W-1:0] s1_product_comb;

    logic signed [PROD_W-1:0] half_ulp_comb;
    logic signed [PROD_W-1:0] shifted_comb;
    logic signed [PROD_W-1:0] bypass_raw_comb;
    logic signed [PROD_W-1:0] raw_comb;
    logic signed [PROD_W-1:0] lo_comb;
    logic signed [PROD_W-1:0] clamped_comb;
    logic signed [7:0] y_comb;
    logic sat_comb;

    logic accept;
    logic pipe_ce;


    // The next result queue is represented as skid0, skid1, and S2 in
    // output order. S2 is kept as the direct, no-stall output so the normal
    // latency remains the three arithmetic stages.
    logic next_s2_valid, next_skid0_valid, next_skid1_valid;
    logic signed [7:0] next_s2_y, next_skid0_y, next_skid1_y;
    logic signed [PROD_W-1:0] next_s2_y_raw, next_skid0_y_raw, next_skid1_y_raw;
    logic next_s2_last, next_skid0_last, next_skid1_last;
    logic next_s2_sat, next_skid0_sat, next_skid1_sat;
    logic next_s2_ovf, next_skid0_ovf, next_skid1_ovf;

    always_comb begin
        s0_sum_ext = $signed({in_acc[ACC_W-1], in_acc}) +
                     $signed({cfg_bias_q[ACC_W-1], cfg_bias_q});
        s0_a_comb = s0_sum_ext[ACC_W-1:0];
        s0_ovf_comb = (in_acc[ACC_W-1] == cfg_bias_q[ACC_W-1]) &&
                      (s0_a_comb[ACC_W-1] != in_acc[ACC_W-1]);

        // Widen both factors before multiplying. This makes the signed
        // multiply width explicit instead of relying on expression sizing.
        s1_a_mul = s0_a;
        s1_m0_mul = s0_m0;
        s1_product_mul = s1_a_mul * s1_m0_mul;
        s1_product_comb = s1_product_mul;

        half_ulp_comb = '0;
        if (s1_shift_n != 0) begin
            half_ulp_comb[0] = 1'b1;
            half_ulp_comb = half_ulp_comb <<< (s1_shift_n - 1'b1);
        end

        bypass_raw_comb = s1_a;
        shifted_comb = (s1_product + half_ulp_comb) >>> s1_shift_n;
        raw_comb = s1_bypass ? bypass_raw_comb : shifted_comb;
        lo_comb = s1_relu ? '0 : -128;

        if (raw_comb > $signed(127)) begin
            clamped_comb = $signed(127);
            sat_comb = 1'b1;
        end else if (raw_comb < lo_comb) begin
            clamped_comb = lo_comb;
            sat_comb = 1'b1;
        end else begin
            clamped_comb = raw_comb;
            sat_comb = 1'b0;
        end
        // Bypass exposes the wrapped INT32 value for debug; it is not a
        // quantization operation, so it must never contribute to sat_seen.
        if (s1_bypass)
            sat_comb = 1'b0;
        y_comb = clamped_comb[7:0];
    end

    always_comb begin
        out_valid = s2_valid;
        out_y = s2_y;
        out_y_raw = s2_y_raw;
        out_last = s2_last;
        out_sat = s2_sat;
        out_ovf = s2_ovf;
    end

    assign accept = in_valid && in_ready;
    assign pipe_ce = !(skid0_valid && skid1_valid && s2_valid && !out_ready);

    // Queue update. The compact logical order is S2, skid0, skid1. S2 is the
    // direct output; the two skid registers are appended only when S2 is
    // blocked. Compacting on every pop makes the ordering explicit.
    always_comb begin
        next_skid0_valid = skid0_valid;
        next_skid1_valid = skid1_valid;
        next_s2_valid = s2_valid;
        next_skid0_y = skid0_y;
        next_skid1_y = skid1_y;
        next_s2_y = s2_y;
        next_skid0_y_raw = skid0_y_raw;
        next_skid1_y_raw = skid1_y_raw;
        next_s2_y_raw = s2_y_raw;
        next_skid0_last = skid0_last;
        next_skid1_last = skid1_last;
        next_s2_last = s2_last;
        next_skid0_sat = skid0_sat;
        next_skid1_sat = skid1_sat;
        next_s2_sat = s2_sat;
        next_skid0_ovf = skid0_ovf;
        next_skid1_ovf = skid1_ovf;
        next_s2_ovf = s2_ovf;

        if (pipe_ce) begin
            if (out_valid && out_ready) begin
                // Pop S2, then append old skid0, old skid1, and the new
                // result from S1 into the compact three-entry queue.
                next_s2_valid = 1'b0;
                next_skid0_valid = 1'b0;
                next_skid1_valid = 1'b0;
                if (skid0_valid) begin
                    next_s2_valid = 1'b1;
                    next_s2_y = skid0_y;
                    next_s2_y_raw = skid0_y_raw;
                    next_s2_last = skid0_last;
                    next_s2_sat = skid0_sat;
                    next_s2_ovf = skid0_ovf;
                    if (skid1_valid) begin
                        next_skid0_valid = 1'b1;
                        next_skid0_y = skid1_y;
                        next_skid0_y_raw = skid1_y_raw;
                        next_skid0_last = skid1_last;
                        next_skid0_sat = skid1_sat;
                        next_skid0_ovf = skid1_ovf;
                        if (s1_valid) begin
                            next_skid1_valid = 1'b1;
                            next_skid1_y = y_comb;
                            next_skid1_y_raw = raw_comb;
                            next_skid1_last = s1_last;
                            next_skid1_sat = sat_comb;
                            next_skid1_ovf = s1_ovf;
                        end
                    end else if (s1_valid) begin
                        next_skid0_valid = 1'b1;
                        next_skid0_y = y_comb;
                        next_skid0_y_raw = raw_comb;
                        next_skid0_last = s1_last;
                        next_skid0_sat = sat_comb;
                        next_skid0_ovf = s1_ovf;
                    end
                end else if (skid1_valid) begin
                    next_s2_valid = 1'b1;
                    next_s2_y = skid1_y;
                    next_s2_y_raw = skid1_y_raw;
                    next_s2_last = skid1_last;
                    next_s2_sat = skid1_sat;
                    next_s2_ovf = skid1_ovf;
                    if (s1_valid) begin
                        next_skid0_valid = 1'b1;
                        next_skid0_y = y_comb;
                        next_skid0_y_raw = raw_comb;
                        next_skid0_last = s1_last;
                        next_skid0_sat = sat_comb;
                        next_skid0_ovf = s1_ovf;
                    end
                end else if (s1_valid) begin
                    next_s2_valid = 1'b1;
                    next_s2_y = y_comb;
                    next_s2_y_raw = raw_comb;
                    next_s2_last = s1_last;
                    next_s2_sat = sat_comb;
                    next_s2_ovf = s1_ovf;
                end
            end else if (s1_valid) begin
                // No pop: append to the first free result slot.
                if (!s2_valid) begin
                    next_s2_valid = 1'b1;
                    next_s2_y = y_comb;
                    next_s2_y_raw = raw_comb;
                    next_s2_last = s1_last;
                    next_s2_sat = sat_comb;
                    next_s2_ovf = s1_ovf;
                end else if (!skid0_valid) begin
                    next_skid0_valid = 1'b1;
                    next_skid0_y = y_comb;
                    next_skid0_y_raw = raw_comb;
                    next_skid0_last = s1_last;
                    next_skid0_sat = sat_comb;
                    next_skid0_ovf = s1_ovf;
                end else if (!skid1_valid) begin
                    next_skid1_valid = 1'b1;
                    next_skid1_y = y_comb;
                    next_skid1_y_raw = raw_comb;
                    next_skid1_last = s1_last;
                    next_skid1_sat = sat_comb;
                    next_skid1_ovf = s1_ovf;
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
            s1_shift_n <= '0;
            s1_relu <= 1'b0;
            s1_bypass <= 1'b0;
            s1_a <= '0;
            s1_last <= 1'b0;
            s1_ovf <= 1'b0;
            s2_y <= '0;
            s2_y_raw <= '0;
            s2_last <= 1'b0;
            s2_sat <= 1'b0;
            s2_ovf <= 1'b0;
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
                        !(next_s2_valid && next_skid0_valid && next_skid1_valid);

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
                    s1_shift_n <= s0_shift_n;
                    s1_relu <= s0_relu;
                    s1_bypass <= s0_bypass;
                    s1_a <= s0_a;
                    s1_last <= s0_last;
                    s1_ovf <= s0_ovf;
                end

                s2_valid <= next_s2_valid;
                s2_y <= next_s2_y;
                s2_y_raw <= next_s2_y_raw;
                s2_last <= next_s2_last;
                s2_sat <= next_s2_sat;
                s2_ovf <= next_s2_ovf;
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
        if (LAT != 3)
            $warning("This implementation has S0/S1/S2 latency; LAT is expected to be 3");
    end
endmodule
