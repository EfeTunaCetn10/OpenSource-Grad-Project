`timescale 1ns/1ps

// Parametric valid-convolution window generator.
//
// The output order is output-row, eight-column tile, then
//   k = ci*(K_H*K_W) + kh*K_W + kw.
// Each output beat contains eight positions at the same k, exactly matching
// compute_engine's B-top activation edge.  The final tile of a row reports
// only its real columns in m_active_cols and zeroes all inactive lanes.
//
// A gather issues eight line-buffer reads (one pixel per cycle) and captures
// each registered result on the following cycle, then presents one 64-bit
// activation beat.  The extra response cycle is contained entirely here.
//
// PAD is retained as a parameter and zero padding is generated for coordinates
// outside the input frame.  The Stage-1 contract is PAD=0; a production
// non-zero-padding design would additionally need an explicit border policy
// in the DMA/frame contract and verification vectors.
//
// C_LOGICAL vs C_PHYS_STRIDE -- ADR-018 Decision 2, "Bedeli" item 1.  The
// reduction length K_LEN is computed from C_LOGICAL ONLY.  Computing it from
// the physical stride would give conv2 K = 200 instead of 150: the output
// shape would stay correct, the values would go quietly wrong and no flag
// would be raised.  That is the failure class this split exists to make
// impossible.  The physical stride is used only by line_buffer's addressing.
//
// Frame lifecycle.  ST_DONE used to be terminal, so a second frame needed the
// global reset; conv2's two output-channel tiles cannot work that way.  The
// `restart` input returns the generator to ST_INPUT so a FRESH input stream
// can be accepted.  It is explicitly NOT a replay: line_buffer holds a ring of
// K_H rows, not the whole frame, so there is nothing in it to replay from.  A
// second pass over the same data means re-streaming it from the intermediate
// activation buffer.
module window_gen #(
    parameter int K_H           = 5,
    parameter int K_W           = 5,
    parameter int C_LOGICAL     = 3,
    parameter int C_PHYS_STRIDE = C_LOGICAL,
    parameter int IN_W          = 32,
    parameter int IN_H          = 32,
    parameter int STRIDE        = 1,
    parameter int PAD           = 0,
    parameter int DATA_WIDTH    = 8
) (
    input  logic        clk,
    input  logic        rst_n,

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
    localparam int OUT_W = ((IN_W + 2*PAD - K_W) / STRIDE) + 1;
    localparam int OUT_H = ((IN_H + 2*PAD - K_H) / STRIDE) + 1;
    // Logical, never physical.  See the C_LOGICAL note in the header.
    localparam int K_LEN = C_LOGICAL * K_H * K_W;

    localparam int ROW_W       = (IN_H < 1) ? 1 : $clog2(IN_H+1);
    localparam int COL_W       = (IN_W < 1) ? 1 : $clog2(IN_W+1);
    localparam int OUT_Y_W     = (OUT_H <= 1) ? 1 : $clog2(OUT_H);
    // remaining_cols and OUT_W_VALUE must represent OUT_W itself, including
    // power-of-two widths (v3 Conv1 has OUT_W=32).
    localparam int TILE_X_W    = (OUT_W <= 1) ? 1 : $clog2(OUT_W+1);
    localparam int K_COUNT_W   = (K_LEN <= 1) ? 1 : $clog2(K_LEN);
    localparam int CI_W        = (C_LOGICAL <= 1) ? 1 : $clog2(C_LOGICAL);
    localparam int KH_W        = (K_H <= 1) ? 1 : $clog2(K_H);
    localparam int KW_W        = (K_W <= 1) ? 1 : $clog2(K_W);
    localparam int CH_W        = (C_LOGICAL < 1) ? 1 : $clog2(C_LOGICAL+1);
    localparam int ROW_COORD_W = $clog2(IN_H + 2*PAD + K_H + STRIDE + 2) + 1;
    localparam int COL_COORD_W = $clog2(IN_W + 2*PAD + K_W + 8*STRIDE + 2) + 1;

    localparam logic [OUT_Y_W-1:0]   LAST_OUT_Y  = OUT_H - 1;
    localparam logic [TILE_X_W-1:0]  OUT_W_VALUE = OUT_W;
    localparam logic [K_COUNT_W-1:0] LAST_K       = K_LEN - 1;
    localparam logic [CI_W-1:0]      LAST_CI      = C_LOGICAL - 1;
    localparam logic [KH_W-1:0]      LAST_KH      = K_H - 1;
    localparam logic [KW_W-1:0]      LAST_KW      = K_W - 1;
    localparam logic signed [ROW_COORD_W-1:0] NEG_ONE = -1;
    localparam logic signed [ROW_COORD_W-1:0] ROW_STRIDE = STRIDE;
    localparam logic signed [ROW_COORD_W-1:0] KH_OFFSET = K_H - 1;
    localparam logic signed [COL_COORD_W-1:0] COL_STRIDE = STRIDE;
    localparam logic signed [COL_COORD_W-1:0] TILE_SOURCE_STEP = 8*STRIDE;

    // Same guard as line_buffer, repeated here so a wrong parameterisation
    // fails at the boundary it was written at and not one level down.  The
    // generate half is the synthesis-time check: an illegal parameterisation
    // instantiates a module that does not exist, which Vivado synthesis and
    // XSim elaboration both report as a hard error.  A legal one elaborates
    // nothing at all, so this costs no logic.
    generate
        if (C_PHYS_STRIDE < C_LOGICAL) begin : g_bad_stride
            illegal_parameters_C_PHYS_STRIDE_below_C_LOGICAL u_guard ();
        end
    endgenerate
`ifndef SYNTHESIS
    initial begin
        if (C_PHYS_STRIDE < C_LOGICAL)
            $fatal(1, "window_gen: C_PHYS_STRIDE=%0d is below C_LOGICAL=%0d",
                   C_PHYS_STRIDE, C_LOGICAL);
    end
`endif

    typedef enum logic [2:0] {ST_INPUT, ST_READ, ST_OUTPUT, ST_DONE} state_t;
    state_t state;

    // Set as soon as this frame has consumed anything or left ST_INPUT, so a
    // restart in the gap between two output rows -- which is also ST_INPUT --
    // is correctly recognised as mid-frame and refused.
    logic frame_started;
    logic restart_idle;
    logic restart_ok;
    logic restart_bad;

    logic allow_input;
    logic resume_write;
    logic lb_clear;
    logic lb_write_busy;
    logic [ROW_W-1:0] rows_written;
    logic lb_frame_done;
    logic lb_rd_en;
    logic [ROW_W-1:0] lb_rd_row;
    logic [COL_W-1:0] lb_rd_col;
    logic [CH_W-1:0] lb_rd_ch;
    logic lb_rd_valid;
    logic [DATA_WIDTH-1:0] lb_rd_byte;

    line_buffer #(
        .K_H           (K_H),
        .C_LOGICAL     (C_LOGICAL),
        .C_PHYS_STRIDE (C_PHYS_STRIDE),
        .IN_W          (IN_W),
        .IN_H          (IN_H),
        .DATA_WIDTH    (DATA_WIDTH)
    ) u_line_buffer (
        .clk          (clk),
        .rst_n        (rst_n),
        .clear        (lb_clear),
        .allow_input  (allow_input),
        .resume_write (resume_write),
        .s_valid      (s_valid),
        .s_ready      (s_ready),
        .s_data       (s_data),
        .s_last       (s_last),
        .write_busy   (lb_write_busy),
        .rows_written (rows_written),
        .frame_done   (lb_frame_done),
        .rd_en        (lb_rd_en),
        .rd_row       (lb_rd_row),
        .rd_col       (lb_rd_col),
        .rd_ch        (lb_rd_ch),
        .rd_valid     (lb_rd_valid),
        .rd_byte      (lb_rd_byte)
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
    logic signed [ROW_COORD_W-1:0] rows_written_coord;
    logic signed [ROW_COORD_W-1:0] kh_coord;
    logic signed [COL_COORD_W-1:0] kw_coord;
    logic signed [COL_COORD_W-1:0] lane_coord;
    logic signed [ROW_COORD_W-1:0] source_row;
    logic signed [COL_COORD_W-1:0] source_col;
    logic signed [ROW_COORD_W-1:0] bottom_row;
    logic rows_ready;

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

        remaining_cols = OUT_W_VALUE - tile_x;
        if (remaining_cols > 8)
            active_count = 4'd8;
        else
            active_count = remaining_cols;

        rows_written_coord = '0;
        rows_written_coord[ROW_W-1:0] = rows_written;
        kh_coord = '0;
        kh_coord[KH_W-1:0] = kh_count;
        kw_coord = '0;
        kw_coord[KW_W-1:0] = kw_count;
        lane_coord = '0;
        lane_coord[3:0] = gather_issue_lane;

        bottom_row = out_base_row + KH_OFFSET;
        source_row = out_base_row + kh_coord;
        source_col = tile_base_col + kw_coord + (lane_coord * COL_STRIDE);

        // Virtual bottom padding never arrives on the input stream. Wait
        // only for the last real row; ST_READ already emits zero outside
        // the image. Preserve the row-pause guard against ring overwrite.
        rows_ready = !lb_write_busy && (bottom_row >= NEG_ONE) &&
                     ((bottom_row < IN_H) ? (rows_written_coord > bottom_row)
                                         : (rows_written_coord == IN_H));
        allow_input = (state == ST_INPUT);
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
        m_tile_last = (state == ST_OUTPUT) && (k_count == LAST_K);
        done = (state == ST_DONE);

        lb_rd_en = 1'b0;
        lb_rd_row = '0;
        lb_rd_col = '0;
        lb_rd_ch = '0;
        if ((state == ST_READ) && (gather_issue_lane < 8) &&
            (gather_issue_lane < active_count) &&
            (source_row >= 0) && (source_row < IN_H) &&
            (source_col >= 0) && (source_col < IN_W)) begin
            lb_rd_en = 1'b1;
            lb_rd_row = source_row[ROW_W-1:0];
            lb_rd_col = source_col[COL_W-1:0];
            lb_rd_ch = ci_count;
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
            out_base_row            <= -PAD;
            tile_base_col           <= -PAD;
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
            out_base_row            <= -PAD;
            tile_base_col           <= -PAD;
        end else begin
            case (state)
                ST_INPUT: begin
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
                        gather_reg             <= '0;
                        tile_base_col          <= -PAD;
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
                        if (k_count == LAST_K) begin
                            if (remaining_cols <= 8) begin
                                if (out_y == LAST_OUT_Y) begin
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
                                    gather_reg              <= '0;
                                    out_base_row            <= out_base_row + ROW_STRIDE;
                                    tile_base_col           <= -PAD;
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
                                gather_reg              <= '0;
                                tile_base_col           <= tile_base_col + TILE_SOURCE_STEP;
                                state                   <= ST_READ;
                            end
                        end else begin
                            k_count <= k_count + 1'b1;
                            if (kw_count == LAST_KW) begin
                                kw_count <= '0;
                                if (kh_count == LAST_KH) begin
                                    kh_count <= '0;
                                    ci_count <= ci_count + 1'b1;
                                end else begin
                                    kh_count <= kh_count + 1'b1;
                                end
                            end else begin
                                kw_count <= kw_count + 1'b1;
                            end
                            gather_issue_lane      <= '0;
                            gather_capture_pending <= 1'b0;
                            gather_capture_from_lb <= 1'b0;
                            gather_reg             <= '0;
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

    property p_kernel_counters_in_range;
        @(posedge clk) disable iff (!rst_n)
        (ci_count <= LAST_CI) && (kh_count <= LAST_KH) &&
        (kw_count <= LAST_KW) && (k_count <= LAST_K);
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
