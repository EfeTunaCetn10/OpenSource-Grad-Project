`timescale 1ns/1ps

// Runtime-geometry convolution window generator (stride 1).
//
// The output order is output-row, eight-column tile, then
//   k = ci*(kh*kw) + kh_i*kw + kw_i.
// Each output beat contains eight positions at the same k, exactly matching
// compute_engine's B-top activation edge.  The final tile of a row reports
// only its real columns in m_active_cols and zeroes all inactive lanes.
//
// A gather issues eight line-buffer reads (one pixel per cycle) and captures
// each registered result on the following cycle, then presents one 64-bit
// activation beat.  The extra response cycle is contained entirely here.
//
// Runtime geometry (faz3-param).  in_h, in_w, c_in, c_phys, kh, kw and pad
// are quasi-static cfg_* inputs bounded by the *_MAX envelope.  They are
// latched whenever the generator is idle (reset, ST_DONE, or ST_INPUT before
// the frame's first beat) and frozen for the rest of the frame.  Derived
// products (row bytes = in_w*c_phys, k_len = c_in*kh*kw) are formed once at
// that latch; the per-beat and per-byte path only adds, compares and wraps:
//
//   * the ring slot of the window's top row (base_slot) and of the current
//     kernel row (kh_slot) are wrap counters, not `row % K_H`;
//   * the physical byte offset of the current lane is an accumulator that
//     steps by c_phys per lane/kernel column, by one per channel and by
//     8*c_phys per tile, not `col * c_phys`.  It is kept modulo
//     2^BYTE_W: a negative or past-the-row value only ever belongs to a
//     padding lane, which is never read, and every in-frame value is below
//     ROW_BYTES_MAX, so the wrap is exact where it matters.
//
// Zero padding (pad <= PAD_MAX) is generated for every coordinate outside the
// frame -- top, left, right and bottom -- and is never received on the
// stream.  The bottom padding rows are virtual: a window whose bottom row is
// beyond the frame waits only for the last real row (Person A's fix, ported
// from integration/ml-rtl-2026-10-09).
//
// An out-of-envelope configuration raises cfg_error (a level, valid one cycle
// after the latch) and holds the generator idle with s_ready low instead of
// running a frame with nonsensical counters.  See the cfg_error block below
// for the exact conditions.
//
// C_LOGICAL vs C_PHYS_STRIDE -- ADR-018 Decision 2, "Bedeli" item 1.  The
// reduction length k_len is computed from cfg_c_in ONLY.  Computing it from
// the physical stride would give conv2 K = 200 instead of 150: the output
// shape would stay correct, the values would go quietly wrong and no flag
// would be raised.  That is the failure class this split exists to make
// impossible.  The physical stride is used only for byte addressing.
//
// Frame lifecycle.  ST_DONE used to be terminal, so a second frame needed the
// global reset; conv2's two output-channel tiles cannot work that way.  The
// `restart` input returns the generator to ST_INPUT so a FRESH input stream
// can be accepted.  It is explicitly NOT a replay: line_buffer holds a ring of
// K_H_MAX rows, not the whole frame, so there is nothing in it to replay from.
// A second pass over the same data means re-streaming it from the
// intermediate activation buffer.
module window_gen #(
    parameter int IN_H_MAX      = 48,
    parameter int IN_W_MAX      = 48,
    parameter int C_MAX         = 511,
    parameter int ROW_BYTES_MAX = 512,
    parameter int K_H_MAX       = 5,
    parameter int K_W_MAX       = 5,
    parameter int PAD_MAX       = 2,
    parameter int K_MAX         = 1024,
    parameter int DATA_WIDTH    = 8
) (
    input  logic        clk,
    input  logic        rst_n,

    // Quasi-static layer geometry; change only while idle.
    input  logic [$clog2(IN_H_MAX+1)-1:0] cfg_in_h,
    input  logic [$clog2(IN_W_MAX+1)-1:0] cfg_in_w,
    input  logic [8:0]                    cfg_c_in,     // logical channels
    input  logic [8:0]                    cfg_c_phys,   // physical channel stride
    input  logic [2:0]                    cfg_kh,
    input  logic [2:0]                    cfg_kw,
    input  logic [1:0]                    cfg_pad,
    output logic                          cfg_error,
    // The latched c_in*kh*kw, for the caller to cross-check its own k_len.
    output logic [$clog2(K_MAX+1)-1:0]    k_len,

    // Single-cycle frame restart.  Accepted only in ST_DONE, or while the
    // generator is still idle after reset; a restart that arrives mid-frame is
    // refused and raises restart_error.  Defaulted so an instantiation that
    // predates this port is driven with a known value instead of 'z.
    input  logic        restart = 1'b0,
    output logic        restart_error,

    input  logic        s_valid,
    output logic        s_ready,
    input  logic [63:0] s_data,
    input  logic        s_last,

    output logic        m_valid,
    input  logic        m_ready,
    output logic [63:0] m_data,
    output logic [3:0]  m_active_cols,
    output logic [31:0] m_k,
    output logic [31:0] m_tile_row,
    output logic [31:0] m_tile_x,
    output logic        m_tile_start,
    output logic        m_tile_last,
    output logic        done
);
    // pad < kh and pad < kw are enforced (cfg_error), so an output dimension
    // never exceeds the input dimension by more than PAD_MAX.
    localparam int OUT_H_MAX = IN_H_MAX + PAD_MAX;
    localparam int OUT_W_MAX = IN_W_MAX + PAD_MAX;

    // Every width that holds a VALUE (not just an index) is $clog2(MAX+1):
    // $clog2(N) cannot represent N itself, which is the RING_W / TILE_X_W bug
    // class.  TILE_X_W is Person A's fix (a): remaining_cols must hold out_w.
    localparam int ROW_W       = (IN_H_MAX < 1) ? 1 : $clog2(IN_H_MAX+1);
    localparam int COL_W       = (IN_W_MAX < 1) ? 1 : $clog2(IN_W_MAX+1);
    localparam int OUT_Y_W     = $clog2(OUT_H_MAX+1);
    localparam int TILE_X_W    = $clog2(OUT_W_MAX+1);
    localparam int K_COUNT_W   = $clog2(K_MAX+1);
    localparam int CI_W        = $clog2(C_MAX+1);
    localparam int KH_W        = $clog2(K_H_MAX+1);
    localparam int KW_W        = $clog2(K_W_MAX+1);
    localparam int RING_W      = (K_H_MAX <= 1) ? 1 : $clog2(K_H_MAX+1);
    localparam int BYTE_W      = $clog2(ROW_BYTES_MAX+1);
    localparam int ROW_COORD_W = $clog2(IN_H_MAX + 2*PAD_MAX + K_H_MAX + 3) + 1;
    localparam int COL_COORD_W = $clog2(IN_W_MAX + 2*PAD_MAX + K_W_MAX + 8 + 2) + 1;
    // Full-width products, so an out-of-envelope value is seen, not truncated.
    localparam int ROW_BYTES_FULL_W = COL_W + 9;
    localparam int K_LEN_FULL_W     = 9 + 3 + 3;

    localparam logic [RING_W-1:0] LAST_RING_SLOT = K_H_MAX - 1;
    localparam logic signed [ROW_COORD_W-1:0] NEG_ONE = -1;
    localparam logic signed [COL_COORD_W-1:0] TILE_SOURCE_STEP = 8;

    typedef enum logic [2:0] {ST_INPUT, ST_READ, ST_OUTPUT, ST_DONE} state_t;
    state_t state;

    // Set as soon as this frame has consumed anything or left ST_INPUT, so a
    // restart in the gap between two output rows -- which is also ST_INPUT --
    // is correctly recognised as mid-frame and refused.
    logic frame_started;
    logic restart_idle;
    logic restart_ok;
    logic restart_bad;

    // ------------------------------------------------------------------
    // Geometry latch.  Stage 1 samples the ports (and forms the two
    // products) while idle; stage 2 re-derives everything else from stage 1
    // every cycle.  Stage 1 is frozen for the whole frame, so stage 2 is too.
    // ------------------------------------------------------------------
    logic cfg_load;
    logic [ROW_W-1:0]            in_h_q;
    logic [COL_W-1:0]            in_w_q;
    logic [8:0]                  c_in_q;
    logic [8:0]                  c_phys_q;
    logic [2:0]                  kh_q;
    logic [2:0]                  kw_q;
    logic [1:0]                  pad_q;
    logic [ROW_BYTES_FULL_W-1:0] row_bytes_full_q;
    logic [K_LEN_FULL_W-1:0]     k_len_full_q;

    logic [KH_W-1:0]      last_kh_q;
    logic [KW_W-1:0]      last_kw_q;
    logic [CI_W-1:0]      last_ci_q;
    logic [K_COUNT_W-1:0] last_k_q;
    logic [OUT_Y_W-1:0]   last_out_y_q;
    logic [TILE_X_W-1:0]  out_w_q;
    logic [BYTE_W-1:0]    pad_byte_q;     // -(pad*c_phys) mod 2^BYTE_W
    logic [BYTE_W-1:0]    c_phys_step;
    logic [BYTE_W-1:0]    c_phys_tile_step;
    logic signed [ROW_COORD_W-1:0] in_h_coord;
    logic signed [COL_COORD_W-1:0] in_w_coord;
    logic signed [ROW_COORD_W-1:0] kh_offset;
    logic signed [ROW_COORD_W-1:0] pad_row_init;
    logic signed [COL_COORD_W-1:0] pad_col_init;
    logic [RING_W-1:0]             init_slot;

    assign cfg_load = !rst_n || (state == ST_DONE) || restart_idle;

    always_ff @(posedge clk) begin
        if (cfg_load) begin
            in_h_q           <= cfg_in_h;
            in_w_q           <= cfg_in_w;
            c_in_q           <= cfg_c_in;
            c_phys_q         <= cfg_c_phys;
            kh_q             <= cfg_kh;
            kw_q             <= cfg_kw;
            pad_q            <= cfg_pad;
            // The only runtime multiplies in the module, and they are on the
            // latch, not on the beat path.
            row_bytes_full_q <= cfg_in_w * cfg_c_phys;
            k_len_full_q     <= cfg_c_in * (cfg_kh * cfg_kw);
        end
    end

    always_ff @(posedge clk) begin
        last_kh_q    <= KH_W'(kh_q) - 1'b1;
        last_kw_q    <= KW_W'(kw_q) - 1'b1;
        last_ci_q    <= CI_W'(c_in_q) - 1'b1;
        last_k_q     <= K_COUNT_W'(k_len_full_q) - 1'b1;
        last_out_y_q <= OUT_Y_W'(in_h_q) + OUT_Y_W'({pad_q, 1'b0}) - OUT_Y_W'(kh_q);
        out_w_q      <= TILE_X_W'(in_w_q) + TILE_X_W'({pad_q, 1'b0}) - TILE_X_W'(kw_q) + 1'b1;
        case (pad_q)
            2'd0:    pad_byte_q <= '0;
            2'd1:    pad_byte_q <= -c_phys_step;
            default: pad_byte_q <= -(c_phys_step << 1);
        endcase

        // Envelope check.  Every condition the datapath relies on is listed;
        // anything else is a legal geometry.
        cfg_error <= (in_h_q == 0) || (in_h_q > IN_H_MAX) ||
                     (in_w_q == 0) || (in_w_q > IN_W_MAX) ||
                     (c_in_q == 0) || (c_in_q > C_MAX) || (c_phys_q > C_MAX) ||
                     (c_phys_q < c_in_q) ||
                     (kh_q == 0) || (kh_q > K_H_MAX) ||
                     (kw_q == 0) || (kw_q > K_W_MAX) ||
                     (pad_q > PAD_MAX) || (pad_q >= kh_q) || (pad_q >= kw_q) ||
                     ((in_h_q + 2*pad_q) < kh_q) || ((in_w_q + 2*pad_q) < kw_q) ||
                     (row_bytes_full_q > ROW_BYTES_MAX) ||
                     (k_len_full_q > K_MAX);
    end

    always_comb begin
        c_phys_step      = BYTE_W'(c_phys_q);
        c_phys_tile_step = c_phys_step << 3;
        k_len            = K_COUNT_W'(k_len_full_q);
        in_h_coord = '0;
        in_h_coord[ROW_W-1:0] = in_h_q;
        in_w_coord = '0;
        in_w_coord[COL_W-1:0] = in_w_q;
        kh_offset = '0;
        kh_offset[KH_W-1:0] = last_kh_q;
        // The frame origin follows the PORT, not stage 1: out_base_row and
        // base_slot are reloaded from it while idle, in the same cycles stage 1
        // samples, so the two can never disagree when the frame starts.
        pad_row_init = -$signed({1'b0, cfg_pad});
        pad_col_init = -$signed({1'b0, pad_q});
        init_slot    = (cfg_pad == 2'd0) ? '0 : RING_W'(K_H_MAX - cfg_pad);
    end

    // Incremental addressing state (see the header).  base_slot is the ring
    // slot of out_base_row, kh_slot the slot of out_base_row + kh_count.
    // tile_byte is the byte offset of (tile_base_col, ci 0), ci_byte adds the
    // channel, kw_byte the kernel column and lane_byte the gather lane.
    logic [RING_W-1:0]    base_slot;
    logic [RING_W-1:0]    kh_slot;
    logic [BYTE_W-1:0]    tile_byte;
    logic [BYTE_W-1:0]    ci_byte;
    logic [BYTE_W-1:0]    kw_byte;
    logic [BYTE_W-1:0]    lane_byte;

    logic allow_input;
    logic resume_write;
    logic lb_clear;
    logic lb_write_busy;
    logic [ROW_W-1:0] rows_written;
    logic lb_frame_done;
    logic lb_rd_en;
    logic [ROW_W-1:0] lb_rd_row;
    logic lb_rd_valid;
    logic [DATA_WIDTH-1:0] lb_rd_byte;

    line_buffer #(
        .K_H_MAX       (K_H_MAX),
        .IN_H_MAX      (IN_H_MAX),
        .ROW_BYTES_MAX (ROW_BYTES_MAX),
        .DATA_WIDTH    (DATA_WIDTH)
    ) u_line_buffer (
        .clk           (clk),
        .rst_n         (rst_n),
        .clear         (lb_clear),
        .cfg_in_h      (in_h_q),
        .cfg_row_bytes (BYTE_W'(row_bytes_full_q)),
        .allow_input   (allow_input),
        .resume_write  (resume_write),
        .s_valid       (s_valid),
        .s_ready       (s_ready),
        .s_data        (s_data),
        .s_last        (s_last),
        .write_busy    (lb_write_busy),
        .rows_written  (rows_written),
        .frame_done    (lb_frame_done),
        .rd_en         (lb_rd_en),
        .rd_row        (lb_rd_row),
        .rd_slot       (kh_slot),
        .rd_offset     (lane_byte),
        .rd_valid      (lb_rd_valid),
        .rd_byte       (lb_rd_byte)
    );

    logic [OUT_Y_W-1:0]   out_y;
    logic [TILE_X_W-1:0]  tile_x;
    logic [K_COUNT_W-1:0] k_count;
    logic [CI_W-1:0]      ci_count;
    logic [KH_W-1:0]      kh_count;
    logic [KW_W-1:0]      kw_count;

    logic [3:0]  gather_issue_lane;
    logic [2:0]  gather_capture_lane;
    logic        gather_capture_pending;
    logic        gather_capture_from_lb;
    logic [63:0] gather_reg;

    logic [3:0] active_count;
    logic [TILE_X_W-1:0] remaining_cols;
    logic signed [ROW_COORD_W-1:0] out_base_row;
    logic signed [COL_COORD_W-1:0] tile_base_col;
    logic signed [ROW_COORD_W-1:0] kh_coord;
    logic signed [COL_COORD_W-1:0] kw_coord;
    logic signed [COL_COORD_W-1:0] lane_coord;
    logic signed [ROW_COORD_W-1:0] source_row;
    logic signed [COL_COORD_W-1:0] source_col;
    logic rows_ready;

    // Registered row target (R3).  rows_ready used to add kh_offset to
    // out_base_row and run two signed compares in the same cycle, and that
    // cone sat in front of s_ready (accel_top's source gating).  The target
    // is now formed from out_base_row's NEXT value, so rows_target_q and
    // rows_ok_q always describe the current out_base_row, and the live
    // check is a single unsigned compare against rows_written.
    logic                          row_advance;
    logic signed [ROW_COORD_W-1:0] next_base_row;
    logic signed [ROW_COORD_W-1:0] next_bottom_row;
    logic [ROW_W-1:0]              rows_target_q;
    logic                          rows_ok_q;
    // Stage 2 of the geometry latch (kh_offset, in_h_coord) settles one
    // cycle after the frame's first beat; rows_ok_q is held low until then.
    logic                          frame_started_q;

    function automatic logic [RING_W-1:0] next_slot(input logic [RING_W-1:0] s);
        return (s == LAST_RING_SLOT) ? '0 : s + 1'b1;
    endfunction

    always_comb begin
        // A restart is a request, not a command.  Honouring it mid-frame would
        // leave a half-reset pipeline -- counters at zero, stale bytes still
        // in the ring, a partially consumed AXIS beat -- which is a worse
        // state than refusing it, so it is refused and recorded instead.
        restart_idle = (state == ST_INPUT) && !frame_started;
        restart_ok   = restart && ((state == ST_DONE) || restart_idle);
        restart_bad  = restart && !restart_ok;
        // Clearing the line buffer and rewinding this state machine have to be
        // the same event, otherwise the two sides disagree about which frame
        // they are on.
        lb_clear     = restart_ok;

        remaining_cols = out_w_q - tile_x;
        if (remaining_cols > 8)
            active_count = 4'd8;
        else
            active_count = remaining_cols;

        kh_coord = '0;
        kh_coord[KH_W-1:0] = kh_count;
        kw_coord = '0;
        kw_coord[KW_W-1:0] = kw_count;
        lane_coord = '0;
        lane_coord[3:0] = gather_issue_lane;

        source_row = out_base_row + kh_coord;
        source_col = tile_base_col + kw_coord + lane_coord;

        // Virtual bottom padding never arrives on the input stream (Person
        // A's fix (b)).  Wait only for the last real row; ST_READ already
        // emits zero outside the frame.  The write_busy guard against ring
        // overwrite is unchanged.  A bad configuration never becomes ready.
        rows_ready = !cfg_error && !lb_write_busy && rows_ok_q &&
                     (rows_written >= rows_target_q);

        // out_base_row's next value, mirroring every assignment to it below.
        row_advance = (state == ST_OUTPUT) && m_ready && (k_count == last_k_q) &&
                      (remaining_cols <= 8) && (out_y != last_out_y_q);
        if (restart_ok || ((state == ST_INPUT) && !frame_started))
            next_base_row = pad_row_init;
        else if (row_advance)
            next_base_row = out_base_row + 1'b1;
        else
            next_base_row = out_base_row;
        next_bottom_row = next_base_row + kh_offset;
        allow_input = (state == ST_INPUT) && !cfg_error;
        resume_write = 1'b0;
        if ((state == ST_INPUT) && rows_ready)
            allow_input = 1'b0;
        else if (state == ST_INPUT)
            resume_write = 1'b1;

        m_valid = (state == ST_OUTPUT);
        m_data = gather_reg;
        m_active_cols = active_count;
        m_k = k_count;
        m_tile_row = out_y;
        m_tile_x = tile_x;
        m_tile_start = (state == ST_OUTPUT) && (k_count == '0);
        m_tile_last = (state == ST_OUTPUT) && (k_count == last_k_q);
        done = (state == ST_DONE);

        lb_rd_en = 1'b0;
        lb_rd_row = '0;
        if ((state == ST_READ) && (gather_issue_lane < 8) &&
            (gather_issue_lane < active_count) &&
            (source_row >= 0) && (source_row < in_h_coord) &&
            (source_col >= 0) && (source_col < in_w_coord)) begin
            lb_rd_en = 1'b1;
            lb_rd_row = source_row[ROW_W-1:0];
        end
    end

    // Frame bookkeeping for the restart gate.  Separate from the datapath
    // always_ff below because restart_error must survive the restart itself:
    // it is cleared only by rst_n.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            restart_error <= 1'b0;
            frame_started <= 1'b0;
        end else begin
            if (restart_bad)
                restart_error <= 1'b1;

            if (restart_ok)
                frame_started <= 1'b0;
            else if ((s_valid && s_ready) || (state != ST_INPUT))
                frame_started <= 1'b1;
        end
    end

    // Rows needed by the window at next_base_row: up to its bottom row, or
    // the whole frame when the bottom row is virtual padding.  rows_written
    // never exceeds in_h, so ">=" against in_h is the old "==".
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            frame_started_q <= 1'b0;
            rows_ok_q       <= 1'b0;
            rows_target_q   <= '0;
        end else begin
            frame_started_q <= frame_started && !restart_ok;
            rows_ok_q       <= frame_started_q && !restart_ok &&
                               (next_bottom_row >= NEG_ONE);
            if (next_bottom_row < in_h_coord)
                rows_target_q <= ROW_W'(next_bottom_row + 1'b1);
            else
                rows_target_q <= in_h_q;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state                   <= ST_INPUT;
            out_y                   <= '0;
            tile_x                  <= '0;
            k_count                 <= '0;
            ci_count                <= '0;
            kh_count                <= '0;
            kw_count                <= '0;
            gather_issue_lane       <= '0;
            gather_capture_lane     <= '0;
            gather_capture_pending  <= 1'b0;
            gather_capture_from_lb  <= 1'b0;
            gather_reg              <= '0;
            out_base_row            <= pad_row_init;
            tile_base_col           <= '0;
            base_slot               <= init_slot;
            kh_slot                 <= '0;
            tile_byte               <= '0;
            ci_byte                 <= '0;
            kw_byte                 <= '0;
            lane_byte               <= '0;
        end else if (restart_ok) begin
            // Exactly the reset values.  Anything left behind here would be
            // state from the previous frame leaking into the next one, and the
            // leak would be silent: the output shape would still be right.
            state                   <= ST_INPUT;
            out_y                   <= '0;
            tile_x                  <= '0;
            k_count                 <= '0;
            ci_count                <= '0;
            kh_count                <= '0;
            kw_count                <= '0;
            gather_issue_lane       <= '0;
            gather_capture_lane     <= '0;
            gather_capture_pending  <= 1'b0;
            gather_capture_from_lb  <= 1'b0;
            gather_reg              <= '0;
            out_base_row            <= pad_row_init;
            tile_base_col           <= '0;
            base_slot               <= init_slot;
            kh_slot                 <= '0;
            tile_byte               <= '0;
            ci_byte                 <= '0;
            kw_byte                 <= '0;
            lane_byte               <= '0;
        end else begin
            case (state)
                ST_INPUT: begin
                    // While idle the frame origin tracks the configured pad,
                    // in the same cycles the geometry latch samples it.
                    if (!frame_started) begin
                        out_base_row <= pad_row_init;
                        base_slot    <= init_slot;
                    end

                    // A row can finish in the middle of an AXIS beat.  The
                    // line buffer keeps write_busy asserted until all bytes
                    // before the boundary have landed; row_pause then keeps
                    // the rest of that beat from overwriting the ring.
                    if (rows_ready) begin
                        tile_x                 <= '0;
                        k_count                <= '0;
                        ci_count               <= '0;
                        kh_count               <= '0;
                        kw_count               <= '0;
                        gather_issue_lane      <= '0;
                        gather_capture_pending <= 1'b0;
                        gather_capture_from_lb <= 1'b0;
                        tile_base_col          <= pad_col_init;
                        kh_slot                <= base_slot;
                        tile_byte              <= pad_byte_q;
                        ci_byte                <= pad_byte_q;
                        kw_byte                <= pad_byte_q;
                        lane_byte              <= pad_byte_q;
                        state                  <= ST_READ;
                    end
                end

                ST_READ: begin
                    // Capture the preceding cycle's synchronous RAM result.
                    // Metadata advances with every lane, including padding,
                    // so invalid and inactive positions are explicitly zero.
                    if (gather_capture_pending) begin
                        if (gather_capture_from_lb && lb_rd_valid)
                            gather_reg[gather_capture_lane*DATA_WIDTH +: DATA_WIDTH]
                                <= lb_rd_byte;
                        else
                            gather_reg[gather_capture_lane*DATA_WIDTH +: DATA_WIDTH]
                                <= '0;
                    end

                    if (gather_issue_lane < 8) begin
                        gather_capture_lane    <= gather_issue_lane[2:0];
                        gather_capture_pending <= 1'b1;
                        gather_capture_from_lb <= lb_rd_en;
                        gather_issue_lane      <= gather_issue_lane + 1'b1;
                        lane_byte              <= lane_byte + c_phys_step;
                    end else begin
                        gather_capture_pending <= 1'b0;
                        gather_capture_from_lb <= 1'b0;
                        if (gather_capture_pending) begin
                            gather_issue_lane <= '0;
                            state <= ST_OUTPUT;
                        end
                    end
                end

                ST_OUTPUT: begin
                    if (m_ready) begin
                        if (k_count == last_k_q) begin
                            if (remaining_cols <= 8) begin
                                if (out_y == last_out_y_q) begin
                                    state <= ST_DONE;
                                end else begin
                                    out_y                   <= out_y + 1'b1;
                                    tile_x                  <= '0;
                                    k_count                 <= '0;
                                    ci_count                <= '0;
                                    kh_count                <= '0;
                                    kw_count                <= '0;
                                    gather_issue_lane       <= '0;
                                    gather_capture_pending  <= 1'b0;
                                    gather_capture_from_lb  <= 1'b0;
                                    out_base_row            <= out_base_row + 1'b1;
                                    tile_base_col           <= pad_col_init;
                                    base_slot               <= next_slot(base_slot);
                                    kh_slot                 <= next_slot(base_slot);
                                    tile_byte               <= pad_byte_q;
                                    ci_byte                 <= pad_byte_q;
                                    kw_byte                 <= pad_byte_q;
                                    lane_byte               <= pad_byte_q;
                                    state                   <= ST_INPUT;
                                end
                            end else begin
                                tile_x                  <= tile_x + 8;
                                k_count                 <= '0;
                                ci_count                <= '0;
                                kh_count                <= '0;
                                kw_count                <= '0;
                                gather_issue_lane       <= '0;
                                gather_capture_pending  <= 1'b0;
                                gather_capture_from_lb  <= 1'b0;
                                tile_base_col           <= tile_base_col + TILE_SOURCE_STEP;
                                kh_slot                 <= base_slot;
                                tile_byte               <= tile_byte + c_phys_tile_step;
                                ci_byte                 <= tile_byte + c_phys_tile_step;
                                kw_byte                 <= tile_byte + c_phys_tile_step;
                                lane_byte               <= tile_byte + c_phys_tile_step;
                                state                   <= ST_READ;
                            end
                        end else begin
                            k_count <= k_count + 1'b1;
                            if (kw_count == last_kw_q) begin
                                kw_count <= '0;
                                if (kh_count == last_kh_q) begin
                                    // Next channel, back to the window's top row.
                                    kh_count  <= '0;
                                    ci_count  <= ci_count + 1'b1;
                                    kh_slot   <= base_slot;
                                    ci_byte   <= ci_byte + 1'b1;
                                    kw_byte   <= ci_byte + 1'b1;
                                    lane_byte <= ci_byte + 1'b1;
                                end else begin
                                    // Next kernel row, same columns.
                                    kh_count  <= kh_count + 1'b1;
                                    kh_slot   <= next_slot(kh_slot);
                                    kw_byte   <= ci_byte;
                                    lane_byte <= ci_byte;
                                end
                            end else begin
                                kw_count  <= kw_count + 1'b1;
                                kw_byte   <= kw_byte + c_phys_step;
                                lane_byte <= kw_byte + c_phys_step;
                            end
                            gather_issue_lane      <= '0;
                            gather_capture_pending <= 1'b0;
                            gather_capture_from_lb <= 1'b0;
                            state                  <= ST_READ;
                        end
                    end
                end

                ST_DONE: begin
                    // Terminal except for an accepted restart, which the
                    // priority branch above handles before this case runs.
                    state <= ST_DONE;
                end

                default: state <= ST_INPUT;
            endcase
        end
    end

    // Not checked in ST_DONE: the counters keep the finished frame's final
    // values there while the geometry latch already follows the ports, so a
    // legal idle reconfiguration to a smaller kernel/channel count would trip
    // it.  Every other state holds counters of the latched geometry (restart
    // and each new row zero them).
    property p_kernel_counters_in_range;
        @(posedge clk) disable iff (!rst_n)
        (state != ST_DONE) |->
        ((ci_count <= last_ci_q) && (kh_count <= last_kh_q) &&
         (kw_count <= last_kw_q) && (k_count <= last_k_q));
    endproperty
    a_kernel_counters_in_range: assert property (p_kernel_counters_in_range);

    property p_read_response_matches_request;
        @(posedge clk) disable iff (!rst_n)
        (state == ST_READ && gather_capture_pending && gather_capture_from_lb)
        |-> lb_rd_valid;
    endproperty
    a_read_response_matches_request: assert property (p_read_response_matches_request);

    // An accepted restart must land the generator exactly where reset would.
    property p_restart_rewinds_everything;
        @(posedge clk) disable iff (!rst_n)
        restart_ok |=> ((state == ST_INPUT) && (out_y == '0) && (tile_x == '0) &&
                        (k_count == '0) && (ci_count == '0) && (kh_count == '0) &&
                        (kw_count == '0) && (gather_reg == 64'b0) &&
                        !gather_capture_pending && !gather_capture_from_lb &&
                        (gather_issue_lane == '0) && !frame_started);
    endproperty
    a_restart_rewinds_everything: assert property (p_restart_rewinds_everything);

    // A refused restart has to be inert: the line buffer must not be cleared,
    // so the rows already ingested are still there on the next cycle.
    property p_refused_restart_is_inert;
        @(posedge clk) disable iff (!rst_n)
        restart_bad |-> !lb_clear;
    endproperty
    a_refused_restart_is_inert: assert property (p_refused_restart_is_inert);

    property p_refused_restart_keeps_rows;
        @(posedge clk) disable iff (!rst_n)
        restart_bad |=> (rows_written >= $past(rows_written));
    endproperty
    a_refused_restart_keeps_rows: assert property (p_refused_restart_keeps_rows);

    // restart_error is sticky by contract: a refused restart is a bug in the
    // layer sequencer, and a pulse only its own cycle can see is a pulse
    // nobody sees.  Cleared by rst_n only.
    property p_restart_error_sticky;
        @(posedge clk) disable iff (!rst_n)
        restart_error |=> restart_error;
    endproperty
    a_restart_error_sticky: assert property (p_restart_error_sticky);

    logic unused_lb_frame_done;
    always_comb unused_lb_frame_done = lb_frame_done;
endmodule
