`timescale 1ns/1ps

// Per-tile sequencer between window_gen, compute_engine and weight_feeder.
//
// The first activation beat is deliberately used as command metadata before
// it is accepted.  ST_WAIT_TILE observes a valid tile-start beat with w_ready
// low, latches active_cols, and only then enters ST_LAUNCH.  The two tile
// commands may be accepted on different cycles.  ST_FEED is not entered until
// the compute engine has consumed its one CLEAR cycle and the feeder command
// has also been accepted.  Consequently the stalled k=0 beat is still on the
// window interface when the pass-through activation gate opens.
module layer_ctrl #(
    parameter int ROWS     = 8,
    parameter int COLS     = 8,
    parameter int K_MAX    = 1024,
    parameter int TILE_MAX = 16,
    parameter int ROW_W    = $clog2(ROWS+1),
    parameter int COL_W    = $clog2(COLS+1),
    parameter int K_W      = $clog2(K_MAX+1),
    parameter int TILE_W   = $clog2(TILE_MAX)
) (
    input  logic                  clk,
    input  logic                  rst_n,

    input  logic                  frame_start,
    input  logic [ROW_W-1:0]      cfg_active_rows,
    input  logic [K_W-1:0]        cfg_k_len,
    input  logic [TILE_W-1:0]     cfg_tile_idx,
    output logic                  busy,
    output logic                  layer_done,

    input  logic                  w_valid,
    output logic                  w_ready,
    input  logic [63:0]           w_data,
    input  logic [3:0]            w_active_cols,
    input  logic [31:0]           w_k,
    input  logic                  w_tile_start,
    input  logic                  w_tile_last,
    input  logic                  w_done,

    output logic                  eng_start,
    input  logic                  eng_start_ready,
    output logic [ROW_W-1:0]      eng_active_rows,
    output logic [COL_W-1:0]      eng_active_cols,
    output logic [K_W-1:0]        eng_k_len,
    output logic                  eng_activation_valid,
    input  logic                  eng_activation_ready,
    output logic [63:0]           eng_activation_data,
    input  logic                  eng_done,
    input  logic                  eng_config_error,

    output logic                  wf_start,
    input  logic                  wf_ready,
    output logic [TILE_W-1:0]     wf_tile_idx,
    output logic [K_W-1:0]        wf_k_len,
    input  logic                  wf_done,
    input  logic                  wf_cfg_error,

    output logic [31:0]           tile_count,
    output logic [7:0]            error_flags
);
    typedef enum logic [2:0] {
        ST_IDLE,
        ST_WAIT_TILE,
        ST_LAUNCH,
        ST_FEED,
        ST_WAIT_DONE
    } state_t;

    state_t state;

    logic [ROW_W-1:0]  cfg_rows_reg;
    logic [K_W-1:0]    cfg_k_reg;
    logic [TILE_W-1:0] cfg_tile_reg;
    logic [COL_W-1:0]  tile_cols_reg;
    logic [K_W-1:0]    beat_count;

    logic eng_cmd_sent;
    logic wf_cmd_sent;
    logic eng_clear_wait;
    logic engine_feed_ready;
    logic w_done_seen;

    logic feed_enable;
    logic window_accept;
    logic activation_accept;
    logic tile_last_bad;
    logic active_cols_changed;
    logic unexpected_accept_attempt;
    logic w_done_early;

    assign busy = (state != ST_IDLE);

    assign eng_active_rows = cfg_rows_reg;
    assign eng_active_cols = tile_cols_reg;
    assign eng_k_len       = cfg_k_reg;
    assign wf_tile_idx     = cfg_tile_reg;
    assign wf_k_len        = cfg_k_reg;

    // A command pulse exists only in the cycle in which its receiver says it
    // will accept it.  The sent bits allow either receiver to stall without
    // duplicating the command at the other receiver.
    assign eng_start = (state == ST_LAUNCH) && !eng_cmd_sent && eng_start_ready;
    assign wf_start  = (state == ST_LAUNCH) && !wf_cmd_sent && wf_ready;

    assign feed_enable          = (state == ST_FEED);
    assign eng_activation_data  = w_data;
    assign eng_activation_valid = feed_enable && w_valid;
    assign w_ready              = feed_enable && eng_activation_ready;

    assign window_accept    = w_valid && w_ready;
    assign activation_accept = eng_activation_valid && eng_activation_ready;

    assign tile_last_bad = window_accept && w_tile_last &&
                           (beat_count != (cfg_k_reg - 1'b1));
    assign active_cols_changed = feed_enable && w_valid &&
                                 (COL_W'(w_active_cols) != tile_cols_reg);

    // With a conforming compute_engine this condition is structurally
    // impossible: activation_ready includes activation_valid.  Keeping this
    // explicit turns an integration fault or substituted engine that claims
    // an out-of-window transfer into the specified sticky status instead of
    // silently trusting it.
    assign unexpected_accept_attempt = !feed_enable && w_valid &&
                                       eng_activation_ready;

    // window_gen normally raises done after its final K beat has transferred,
    // while the engine is flushing/draining.  That is legal in ST_WAIT_DONE.
    // Raising it before the K-beat feed has completed is the early-done error.
    assign w_done_early = w_done &&
                          ((state == ST_LAUNCH) || (state == ST_FEED));

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state             <= ST_IDLE;
            cfg_rows_reg      <= '0;
            cfg_k_reg         <= '0;
            cfg_tile_reg      <= '0;
            tile_cols_reg     <= '0;
            beat_count        <= '0;
            eng_cmd_sent      <= 1'b0;
            wf_cmd_sent       <= 1'b0;
            eng_clear_wait    <= 1'b0;
            engine_feed_ready <= 1'b0;
            w_done_seen       <= 1'b0;
            tile_count        <= '0;
            layer_done        <= 1'b0;
            error_flags       <= '0;
        end else begin
            layer_done <= 1'b0;

            // A frame command clears prior status.  A command presented while
            // busy is rejected and becomes the new frame-start error status.
            if (frame_start) begin
                error_flags <= busy ? 8'h20 : 8'h00;
            end else begin
                if (eng_config_error)
                    error_flags[0] <= 1'b1;
                if (wf_cfg_error)
                    error_flags[1] <= 1'b1;
                if (unexpected_accept_attempt)
                    error_flags[2] <= 1'b1;
                if (tile_last_bad)
                    error_flags[3] <= 1'b1;
                if (active_cols_changed)
                    error_flags[4] <= 1'b1;
                if (w_done_early)
                    error_flags[6] <= 1'b1;
                error_flags[7] <= 1'b0;
            end

            if (busy && w_done)
                w_done_seen <= 1'b1;

            // A receiver-side configuration rejection makes progress on this
            // frame impossible.  Drop busy immediately rather than holding a
            // first beat forever; software can inspect the sticky flag and
            // issue a new frame command after resetting/restarting its source.
            if (busy && (eng_config_error || wf_cfg_error)) begin
                state             <= ST_IDLE;
                eng_cmd_sent      <= 1'b0;
                wf_cmd_sent       <= 1'b0;
                eng_clear_wait    <= 1'b0;
                engine_feed_ready <= 1'b0;
                w_done_seen       <= 1'b0;
            end else begin
                case (state)
                    ST_IDLE: begin
                        if (frame_start) begin
                            cfg_rows_reg      <= cfg_active_rows;
                            cfg_k_reg         <= cfg_k_len;
                            cfg_tile_reg      <= cfg_tile_idx;
                            tile_cols_reg     <= '0;
                            beat_count        <= '0;
                            eng_cmd_sent      <= 1'b0;
                            wf_cmd_sent       <= 1'b0;
                            eng_clear_wait    <= 1'b0;
                            engine_feed_ready <= 1'b0;
                            w_done_seen       <= 1'b0;
                            tile_count        <= '0;
                            state             <= ST_WAIT_TILE;
                        end
                    end

                    ST_WAIT_TILE: begin
                        // Metadata is sampled from the still-unaccepted k=0
                        // beat.  w_ready remains low throughout this state.
                        if (w_valid && w_tile_start) begin
                            tile_cols_reg     <= COL_W'(w_active_cols);
                            beat_count        <= '0;
                            eng_cmd_sent      <= 1'b0;
                            wf_cmd_sent       <= 1'b0;
                            eng_clear_wait    <= 1'b0;
                            engine_feed_ready <= 1'b0;
                            state             <= ST_LAUNCH;
                        end else if (w_done) begin
                            layer_done  <= 1'b1;
                            w_done_seen <= 1'b0;
                            state       <= ST_IDLE;
                        end
                    end

                    ST_LAUNCH: begin
                        if (eng_start) begin
                            eng_cmd_sent   <= 1'b1;
                            eng_clear_wait <= 1'b1;
                            tile_count     <= tile_count + 1'b1;
                        end
                        if (wf_start)
                            wf_cmd_sent <= 1'b1;

                        // eng_clear_wait is observed one full cycle after the
                        // accepted start: at this edge CLEAR completes and the
                        // engine enters FEED.  The transition opens the gate
                        // immediately after that same edge.
                        if (eng_clear_wait) begin
                            eng_clear_wait    <= 1'b0;
                            engine_feed_ready <= 1'b1;
                        end
                        if ((engine_feed_ready || eng_clear_wait) &&
                            (wf_cmd_sent || wf_start)) begin
                            state <= ST_FEED;
                        end
                    end

                    ST_FEED: begin
                        if (window_accept) begin
                            beat_count <= beat_count + 1'b1;
                            if (beat_count == (cfg_k_reg - 1'b1))
                                state <= ST_WAIT_DONE;
                        end
                    end

                    ST_WAIT_DONE: begin
                        if (eng_done) begin
                            eng_cmd_sent      <= 1'b0;
                            wf_cmd_sent       <= 1'b0;
                            engine_feed_ready <= 1'b0;
                            if (w_done_seen || w_done) begin
                                layer_done  <= 1'b1;
                                w_done_seen <= 1'b0;
                                state       <= ST_IDLE;
                            end else begin
                                state <= ST_WAIT_TILE;
                            end
                        end
                    end

                    default: state <= ST_IDLE;
                endcase
            end
        end
    end

    // Stage 2 hook: a second output-channel tile would require replaying the
    // same activation windows.  window_gen has no rewind/replay interface, so
    // Stage 1 intentionally launches exactly cfg_tile_idx for every tile.

    property p_eng_start_only_ready;
        @(posedge clk) disable iff (!rst_n)
            eng_start |-> eng_start_ready;
    endproperty
    a_eng_start_only_ready: assert property (p_eng_start_only_ready)
        else $error("layer_ctrl asserted eng_start while eng_start_ready was low");

    property p_no_accept_outside_feed;
        @(posedge clk) disable iff (!rst_n)
            activation_accept |-> feed_enable;
    endproperty
    a_no_accept_outside_feed: assert property (p_no_accept_outside_feed)
        else $error("Activation accepted outside the enabled FEED window");

    property p_beats_per_tile;
        @(posedge clk) disable iff (!rst_n)
            (eng_done && (state == ST_WAIT_DONE)) |-> (beat_count == cfg_k_reg);
    endproperty
    a_beats_per_tile: assert property (p_beats_per_tile)
        else $error("Engine completed a tile with the wrong activation beat count");

    property p_eng_error_flag;
        @(posedge clk) disable iff (!rst_n)
            (eng_config_error && !frame_start) |=> (error_flags[0] || frame_start);
    endproperty
    a_eng_error_flag: assert property (p_eng_error_flag);

    property p_wf_error_flag;
        @(posedge clk) disable iff (!rst_n)
            (wf_cfg_error && !frame_start) |=> (error_flags[1] || frame_start);
    endproperty
    a_wf_error_flag: assert property (p_wf_error_flag);

    property p_accept_window_flag;
        @(posedge clk) disable iff (!rst_n)
            (unexpected_accept_attempt && !frame_start) |=>
                (error_flags[2] || frame_start);
    endproperty
    a_accept_window_flag: assert property (p_accept_window_flag);

    property p_tile_last_flag;
        @(posedge clk) disable iff (!rst_n)
            (tile_last_bad && !frame_start) |=> (error_flags[3] || frame_start);
    endproperty
    a_tile_last_flag: assert property (p_tile_last_flag);

    property p_active_cols_flag;
        @(posedge clk) disable iff (!rst_n)
            (active_cols_changed && !frame_start) |=>
                (error_flags[4] || frame_start);
    endproperty
    a_active_cols_flag: assert property (p_active_cols_flag);

    property p_busy_start_flag;
        @(posedge clk) disable iff (!rst_n)
            (frame_start && busy) |=> error_flags[5];
    endproperty
    a_busy_start_flag: assert property (p_busy_start_flag);

    property p_w_done_flag;
        @(posedge clk) disable iff (!rst_n)
            (w_done_early && !frame_start) |=> (error_flags[6] || frame_start);
    endproperty
    a_w_done_flag: assert property (p_w_done_flag);

    property p_reserved_zero;
        @(posedge clk) disable iff (!rst_n)
            !error_flags[7];
    endproperty
    a_reserved_zero: assert property (p_reserved_zero);

    initial begin
        if (ROWS < 1)
            $error("ROWS must be at least 1");
        if ((COLS < 1) || (COLS > 15))
            $error("COLS must fit the fixed 4-bit window metadata field");
        if (K_MAX < 1)
            $error("K_MAX must be at least 1");
        if (TILE_MAX < 2)
            $error("TILE_MAX must be at least 2 for a non-zero TILE_W");
    end

    // w_k and wf_done are intentionally not control inputs here.  The
    // accepted-beat counter is the authoritative K boundary, while feeder
    // completion naturally precedes engine drain completion under the paired
    // handshake.  Keeping the ports observed by integration lint documents
    // that choice without inventing a replay or rewind protocol.
    logic unused_contract_inputs;
    assign unused_contract_inputs = ^w_k ^ wf_done;
endmodule
