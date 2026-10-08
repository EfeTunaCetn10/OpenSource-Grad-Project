`timescale 1ns/1ps

// Eight lockstep requantizers: one INT32 accumulator lane per output channel.
//
// compute_engine drains a column beat carrying ROWS INT32 accumulators behind
// a single out_ready.  requant_unit is the opposite shape: a scalar pipe with
// its own registered in_ready.  This block is the adapter.  It holds the eight
// units in strict lockstep so one shared handshake can speak for all of them,
// and it carries the beat metadata that requant_unit does not model -- the
// drain column and the active-lane mask -- alongside in a small FIFO.
//
// Lane r is output channel r.  That is why the configuration ports are
// unpacked arrays: axi_lite_regs exports cfg_*[0:7] in exactly this shape and
// connects with no packing shim.
//
// Why a metadata FIFO instead of mirroring the unit's stages: a unit is four
// arithmetic stages (S0..S3) plus a three-entry result queue, and the
// occupancy rules that govern them live inside the unit -- the stage count
// already changed once, when the unit was re-pipelined to close 100 MHz.
// Re-deriving those rules here would duplicate logic that is free to change.  The FIFO needs only two properties of the unit's
// *external* contract -- results leave in accept order, and each output
// handshake pops exactly one -- so it stays correct across changes to the
// internals.  The per-unit out_last is still observed and cross-checked
// against the FIFO copy: if that alignment assumption is ever broken, it
// surfaces as lockstep_error instead of silently shifting every output
// address by one beat.
module requant_array #(
    parameter int LANES  = 8,
    parameter int ACC_W  = 32,
    parameter int M0_W   = 18,
    parameter int PROD_W = 64,
    parameter int COL_W  = 4,
    // A unit holds at most seven beats in flight: four arithmetic stages
    // (S0..S3) plus the three result slots (S4, skid0, skid1).  Seven entries
    // therefore already make overflow unreachable.  Eight is the next power of
    // two and keeps the wrapping pointer arithmetic free.
    parameter int DEPTH  = 8
) (
    input  logic                    clk,
    input  logic                    rst_n,

    input  logic signed [ACC_W-1:0] cfg_bias_q  [0:LANES-1],
    input  logic signed [M0_W-1:0]  cfg_m0      [0:LANES-1],
    input  logic        [5:0]       cfg_shift_n [0:LANES-1],
    input  logic                    cfg_relu    [0:LANES-1],
    input  logic                    cfg_bypass,

    // Engine-side column beat.  in_lane_valid is compute_engine's
    // out_lane_valid: the low active_rows lanes carry a real accumulator.
    input  logic                    in_valid,
    output logic                    in_ready,
    input  logic [LANES*ACC_W-1:0]  in_acc_flat,
    input  logic [LANES-1:0]        in_lane_valid,
    input  logic [COL_W-1:0]        in_col,
    input  logic                    in_k_last,
    input  logic                    in_last,

    // Requantized beat.  Inactive lanes read zero in out_y_flat and are
    // masked out of the status vectors, so a consumer can use the whole word
    // without re-applying the mask.
    output logic                    out_valid,
    input  logic                    out_ready,
    output logic [LANES*8-1:0]      out_y_flat,
    output logic [LANES-1:0]        out_lane_valid,
    output logic [COL_W-1:0]        out_col,
    output logic                    out_last,
    output logic [LANES-1:0]        out_sat_flat,
    output logic [LANES-1:0]        out_ovf_flat,
    output logic                    lockstep_error
);
    localparam int PTR_W = $clog2(DEPTH);
    localparam int CNT_W = $clog2(DEPTH+1);

    logic [LANES-1:0]  u_in_valid, u_in_ready;
    logic [LANES-1:0]  u_out_valid, u_out_last, u_out_sat, u_out_ovf;
    logic signed [7:0] u_out_y [0:LANES-1];
    logic [LANES-1:0]  u_out_ready;

    logic [COL_W-1:0] meta_col  [0:DEPTH-1];
    logic [LANES-1:0] meta_mask [0:DEPTH-1];
    logic             meta_last [0:DEPTH-1];
    logic [PTR_W-1:0] wr_ptr, rd_ptr;
    logic [CNT_W-1:0] count;

    logic             meta_valid, meta_full;
    logic [LANES-1:0] cur_mask;
    logic             accept, push, pop;
    integer           lane_i;

    // The units advance only as a group, so a beat may be handed to lane r
    // exclusively when *every* lane can take it and the metadata FIFO has
    // room.  Gating the per-unit valid with this block's own in_ready is what
    // enforces that: without it, a lane whose in_ready happened to be high
    // would accept a beat the others refused and desynchronise the pipe.
    // This is safe despite valid depending on ready, because every term of
    // in_ready is registered -- requant_unit writes in_ready only in its
    // clocked block, and meta_full comes from the FIFO counter -- so there is
    // no combinational valid/ready loop at either boundary.
    //
    // Readiness is required from all LANES, not only the lanes this beat
    // feeds.  Masking the term would avoid a few stall cycles when an idle
    // lane happens to be backed up, but it would make in_ready depend on
    // in_lane_valid and give up the property above.  The conservative form
    // cannot deadlock: the oldest beat's masked lanes always hold its result
    // (a full queue is by definition a presented result), so the FIFO always
    // drains and any lane blocking the input eventually frees itself.
    assign in_ready = (&u_in_ready) && !meta_full;
    assign accept   = in_valid && in_ready;

    // A unit latches a sample into S0 only when in_k_last is set and silently
    // drops it otherwise.  The FIFO mirrors that condition so a partial-K
    // beat consumes no metadata slot and the two stay aligned.
    assign push = accept && in_k_last;

    assign meta_valid = (count != '0);
    assign meta_full  = (count == CNT_W'(DEPTH));
    assign cur_mask   = meta_mask[rd_ptr];

    // Present a beat once every lane the mask claims has its result ready.
    // Inactive lanes are never fed, so their out_valid stays low and must not
    // be part of this term.
    assign out_valid = meta_valid && ((u_out_valid & cur_mask) == cur_mask);
    assign pop       = out_valid && out_ready;

    // The pop is masked, not shared.  A lane outside the head beat's mask may
    // legitimately already hold the result of a *later*, wider beat: it was
    // fed on fewer beats, so its queue is shorter and a new sample races
    // through its empty stages while the low lanes are still working through
    // theirs.  An unmasked pop would discard that result, and the wider beat
    // could then never assemble -- out_valid would stay low with the FIFO
    // non-empty, which is a hang, not a wrong value.  Masking makes each lane
    // an in-order queue of exactly the beats it participates in.
    assign u_out_ready = pop ? cur_mask : {LANES{1'b0}};

    assign out_lane_valid = cur_mask;
    assign out_col        = meta_col[rd_ptr];
    assign out_last       = meta_last[rd_ptr];
    assign out_sat_flat   = u_out_sat & cur_mask;
    assign out_ovf_flat   = u_out_ovf & cur_mask;

    always_comb begin
        out_y_flat = '0;
        for (lane_i = 0; lane_i < LANES; lane_i = lane_i + 1) begin
            u_in_valid[lane_i] = accept && in_lane_valid[lane_i];
            if (cur_mask[lane_i])
                out_y_flat[lane_i*8 +: 8] = u_out_y[lane_i];
        end
    end

    genvar g;
    generate
        for (g = 0; g < LANES; g = g + 1) begin : g_lane
            // out_y_raw is left unconnected on purpose.  The 64-bit
            // pre-saturation value is a numeric-debug port, already scored
            // per lane by tb_requant_unit_num against the 60k vector set;
            // exporting LANES*64 bits here would widen the integration
            // datapath for evidence that is not produced at this level.
            requant_unit #(
                .ACC_W  (ACC_W),
                .M0_W   (M0_W),
                .PROD_W (PROD_W),
                .LAT    (5)
            ) u_req (
                .clk         (clk),
                .rst_n       (rst_n),
                .cfg_bias_q  (cfg_bias_q [g]),
                .cfg_m0      (cfg_m0     [g]),
                .cfg_shift_n (cfg_shift_n[g]),
                .cfg_relu    (cfg_relu   [g]),
                .cfg_bypass  (cfg_bypass),
                .in_valid    (u_in_valid[g]),
                .in_ready    (u_in_ready[g]),
                .in_acc      (in_acc_flat[g*ACC_W +: ACC_W]),
                .in_k_last   (in_k_last),
                .in_last     (in_last),
                .out_valid   (u_out_valid[g]),
                .out_ready   (u_out_ready[g]),
                .out_y       (u_out_y[g]),
                .out_y_raw   (),
                .out_last    (u_out_last[g]),
                .out_sat     (u_out_sat[g]),
                .out_ovf     (u_out_ovf[g])
            );
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wr_ptr         <= '0;
            rd_ptr         <= '0;
            count          <= '0;
            lockstep_error <= 1'b0;
        end else begin
            if (push) begin
                meta_col [wr_ptr] <= in_col;
                meta_mask[wr_ptr] <= in_lane_valid;
                meta_last[wr_ptr] <= in_last;
                wr_ptr            <= wr_ptr + 1'b1;
            end
            if (pop)
                rd_ptr <= rd_ptr + 1'b1;

            if (push && !pop)
                count <= count + 1'b1;
            else if (pop && !push)
                count <= count - 1'b1;

            // Sticky divergence flag: on the beat being popped, every masked
            // lane must agree with the FIFO about end-of-frame.  If it does
            // not, the metadata no longer describes the data, which is an
            // addressing fault downstream rather than a wrong pixel.
            //
            // Deliberately not checked: a result sitting in a lane outside
            // the head beat's mask.  That is legal and expected once tiles of
            // different active_rows follow each other -- the shorter queue
            // runs ahead.  An earlier version flagged it and was wrong.
            if (pop && ((u_out_last & cur_mask) !=
                        (meta_last[rd_ptr] ? cur_mask : {LANES{1'b0}})))
                lockstep_error <= 1'b1;
        end
    end

    // A completed reduction must claim at least one output channel; an
    // all-zero mask would pop a metadata entry that no lane backs, and
    // out_valid would go high on empty data.  compute_engine cannot produce
    // it (active_rows == 0 is rejected as a config error), so this names an
    // illegal upstream input rather than a fault in this block.
    property p_mask_nonzero;
        @(posedge clk) disable iff (!rst_n)
            (in_valid && in_k_last) |-> (in_lane_valid != '0);
    endproperty
    a_mask_nonzero: assert property (p_mask_nonzero)
        else $error("Illegal upstream input: in_k_last with an empty lane mask");

    // compute_engine builds the mask as (1 << active_rows) - 1, so it is
    // always contiguous from lane 0.  Stating it here is not decoration: the
    // nesting it implies is what makes lane 0 both the busiest lane and a
    // member of every mask, and therefore the last to present any beat.
    // Several properties of this block lean on that -- notably that a beat is
    // never assembled from a mask whose deepest lane is still in transit.  A
    // sparse mask would invalidate the reasoning rather than merely produce a
    // wrong pixel, which is why it is rejected instead of handled.
    //
    // (mask + 1) & mask == 0 holds exactly for the contiguous-from-zero
    // masks, and the LANES-bit wrap makes the all-ones case pass as well.
    property p_mask_contiguous;
        @(posedge clk) disable iff (!rst_n)
            (in_valid && in_k_last) |->
                (((in_lane_valid + 1'b1) & in_lane_valid) == '0);
    endproperty
    a_mask_contiguous: assert property (p_mask_contiguous)
        else $error("Illegal upstream input: lane mask is not contiguous from lane 0");

    // Mirrors requant_unit's own contract at the array boundary, so a bad
    // beat is reported here instead of eight times over.
    property p_last_requires_k_last;
        @(posedge clk) disable iff (!rst_n)
            (in_valid && in_last) |-> in_k_last;
    endproperty
    a_last_requires_k_last: assert property (p_last_requires_k_last)
        else $error("Illegal upstream input: in_valid && in_last requires in_k_last");

    property p_no_meta_overflow;
        @(posedge clk) disable iff (!rst_n)
            push |-> !meta_full;
    endproperty
    a_no_meta_overflow: assert property (p_no_meta_overflow)
        else $error("Metadata FIFO overflow: DEPTH is below the in-flight bound");

    // Labelled so a testbench that deliberately desynchronises the lanes can
    // bracket it with $assertoff/$asserton and score lockstep_error instead.
    property p_no_lockstep_error;
        @(posedge clk) disable iff (!rst_n)
            !lockstep_error;
    endproperty
    a_no_lockstep_error: assert property (p_no_lockstep_error)
        else $error("Lane lockstep lost: metadata no longer describes the beat");

    initial begin
        if (LANES < 1)
            $error("LANES must be at least 1");
        if (DEPTH < 7)
            $error("DEPTH must cover the seven beats a requant_unit holds in flight");
        if (2**PTR_W != DEPTH)
            $error("DEPTH must be a power of two for the wrapping pointers");
        if (COL_W < 1)
            $error("COL_W must be at least 1");
    end
endmodule
