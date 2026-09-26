`timescale 1ns/1ps

// K-streaming output-stationary compute engine.
//
// A-left is the weight edge (one stream per output-channel row); B-top is the
// activation edge (one stream per output-position column).  A source beat is
// accepted only as a pair: this makes a missing source a clean, lossless stall.
// The ready signals depend only on the local state and the two source valids;
// they never depend on out_ready or any downstream ready, so there is no
// combinational downstream-ready -> upstream-ready path.
//
// The PE accumulators are deliberately retained through DRAIN.  Consequently
// tiles are sequential: the next CLEAR cannot happen until the last drain beat
// has been accepted.  This costs one accumulator-set drain interval per tile,
// but avoids a second 64*ACC_WIDTH accumulator bank.
module compute_engine #(
    parameter int ROWS       = 8,
    parameter int COLS       = 8,
    parameter int K_MAX      = 1024,
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH  = 32,
    parameter int ROW_W      = $clog2(ROWS+1),
    parameter int COL_W      = $clog2(COLS+1),
    parameter int K_W        = $clog2(K_MAX+1),
    parameter int FLUSH_W    = $clog2(ROWS+COLS+1)
) (
    input  logic                                clk,
    input  logic                                rst_n,

    input  logic                                start,
    output logic                                start_ready,
    input  logic [ROW_W-1:0]                    active_rows,
    input  logic [COL_W-1:0]                    active_cols,
    input  logic [K_W-1:0]                      k_len,

    input  logic                                weight_valid,
    output logic                                weight_ready,
    input  logic [ROWS*DATA_WIDTH-1:0]          weight_data,
    input  logic                                activation_valid,
    output logic                                activation_ready,
    input  logic [COLS*DATA_WIDTH-1:0]          activation_data,

    output logic                                busy,
    output logic                                done,
    output logic                                config_error,

    output logic                                out_valid,
    input  logic                                out_ready,
    output logic [ROWS*ACC_WIDTH-1:0]           out_acc_flat,
    output logic [ROWS-1:0]                     out_lane_valid,
    output logic [COL_W-1:0]                    out_col,
    output logic                                out_k_last,
    output logic                                out_last,

    output logic                                drain_stall,
    output logic [31:0]                         cycle_count,
    output logic [ROWS*COLS-1:0]                mac_fire_flat
);
    typedef enum logic [2:0] {IDLE, CLEAR, FEED, FLUSH, DRAIN} state_t;
    state_t state;

    logic [ROW_W-1:0] rows_reg;
    logic [COL_W-1:0] cols_reg;
    logic [K_W-1:0]   k_reg;
    logic [K_W-1:0]   k_count;
    logic [FLUSH_W-1:0] flush_count;
    logic [COL_W-1:0] drain_col;

    // Triangular delay banks.  Entry [r][d] is the d-cycle history for row r;
    // only d=r-1 is observed at the array boundary (and likewise for columns).
    // The extra unused entries keep the parameterized declaration legal for the
    // 1-row/1-column case as well.
    logic signed [DATA_WIDTH-1:0] weight_skew [0:ROWS-1][0:ROWS-1];
    logic signed [DATA_WIDTH-1:0] act_skew    [0:COLS-1][0:COLS-1];
    logic                         weight_skew_v [0:ROWS-1][0:ROWS-1];
    logic                         act_skew_v    [0:COLS-1][0:COLS-1];

    logic [ROWS*DATA_WIDTH-1:0] a_left_flat;
    logic [COLS*DATA_WIDTH-1:0] b_top_flat;
    logic [ROWS-1:0]            a_left_valid;
    logic [COLS-1:0]            b_top_valid;
    logic [ROWS*COLS*ACC_WIDTH-1:0] array_c_flat;

    logic array_step;
    logic array_clear;
    logic array_flush;
    logic pair_ready;
    integer flush_target;
    integer comb_ri;
    integer comb_ci;
    integer out_ri;
    integer seq_ri;
    integer seq_ci;
    integer seq_di;

    assign start_ready = (state == IDLE);
    assign busy        = (state != IDLE);

    // Both edge handshakes are deliberately coupled.  A source that is ready
    // cannot be consumed alone, so no beat can be duplicated when its partner
    // starves.  No downstream signal appears in this equation.
    assign pair_ready       = (state == FEED) && weight_valid && activation_valid;
    assign weight_ready     = pair_ready;
    assign activation_ready = pair_ready;

    assign array_clear = (state == CLEAR);
    assign array_flush = (state == CLEAR);
    assign array_step  = (state == CLEAR) || (state == FLUSH) || pair_ready;

    assign out_valid      = (state == DRAIN);
    assign out_col        = drain_col;
    assign out_lane_valid = (state == DRAIN) ? ((1 << rows_reg) - 1'b1) : '0;
    assign out_k_last     = (state == DRAIN);
    assign out_last       = (state == DRAIN) && (drain_col == cols_reg - 1'b1);
    assign drain_stall    = (state == DRAIN) && !out_ready;

    // The skew is applied at the array boundary.  Row/column zero sees the
    // current paired source beat; rows/columns above zero see their shift-bank
    // entry.  During a source stall array_step is low and all these registers
    // remain frozen.
    always_comb begin
        a_left_flat  = '0;
        b_top_flat   = '0;
        a_left_valid = '0;
        b_top_valid  = '0;

        for (comb_ri = 0; comb_ri < ROWS; comb_ri = comb_ri + 1) begin
            if (comb_ri == 0) begin
                a_left_flat[comb_ri*DATA_WIDTH +: DATA_WIDTH] = weight_data[comb_ri*DATA_WIDTH +: DATA_WIDTH];
                a_left_valid[comb_ri] = pair_ready && (comb_ri < int'(rows_reg));
            end else begin
                a_left_flat[comb_ri*DATA_WIDTH +: DATA_WIDTH] = weight_skew[comb_ri][comb_ri-1];
                a_left_valid[comb_ri] = weight_skew_v[comb_ri][comb_ri-1];
            end
        end

        for (comb_ci = 0; comb_ci < COLS; comb_ci = comb_ci + 1) begin
            if (comb_ci == 0) begin
                b_top_flat[comb_ci*DATA_WIDTH +: DATA_WIDTH] = activation_data[comb_ci*DATA_WIDTH +: DATA_WIDTH];
                b_top_valid[comb_ci] = pair_ready && (comb_ci < int'(cols_reg));
            end else begin
                b_top_flat[comb_ci*DATA_WIDTH +: DATA_WIDTH] = act_skew[comb_ci][comb_ci-1];
                b_top_valid[comb_ci] = act_skew_v[comb_ci][comb_ci-1];
            end
        end
    end

    systolic_array_os #(
        .ROWS       (ROWS),
        .COLS       (COLS),
        .DATA_WIDTH (DATA_WIDTH),
        .ACC_WIDTH  (ACC_WIDTH)
    ) u_array (
        .clk           (clk),
        .rst_n         (rst_n),
        .step          (array_step),
        .clear_acc     (array_clear),
        .pipe_flush    (array_flush),
        .a_left_flat   (a_left_flat),
        .a_left_valid  (a_left_valid),
        .b_top_flat    (b_top_flat),
        .b_top_valid   (b_top_valid),
        .c_acc_flat    (array_c_flat),
        .mac_fire_flat (mac_fire_flat)
    );

    always_comb begin
        flush_target = int'(rows_reg) + int'(cols_reg) - 2;
    end

    // The array is row-major (row*COLS+column); the external contract is a
    // column beat with one fixed output-channel lane per row.
    always_comb begin
        out_acc_flat = '0;
        for (out_ri = 0; out_ri < ROWS; out_ri = out_ri + 1)
            out_acc_flat[out_ri*ACC_WIDTH +: ACC_WIDTH] =
                array_c_flat[(out_ri*COLS + drain_col)*ACC_WIDTH +: ACC_WIDTH];
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state        <= IDLE;
            rows_reg     <= '0;
            cols_reg     <= '0;
            k_reg        <= '0;
            k_count      <= '0;
            flush_count  <= '0;
            drain_col    <= '0;
            done         <= 1'b0;
            config_error <= 1'b0;
            cycle_count  <= '0;
            for (seq_ri = 0; seq_ri < ROWS; seq_ri = seq_ri + 1) begin
                for (seq_di = 0; seq_di < ROWS; seq_di = seq_di + 1) begin
                    weight_skew[seq_ri][seq_di]   <= '0;
                    weight_skew_v[seq_ri][seq_di] <= 1'b0;
                end
            end
            for (seq_ci = 0; seq_ci < COLS; seq_ci = seq_ci + 1) begin
                for (seq_di = 0; seq_di < COLS; seq_di = seq_di + 1) begin
                    act_skew[seq_ci][seq_di]   <= '0;
                    act_skew_v[seq_ci][seq_di] <= 1'b0;
                end
            end
        end else begin
            done         <= 1'b0;
            config_error <= 1'b0;
            if (state != IDLE)
                cycle_count <= cycle_count + 1'b1;

            // A paired source beat advances both triangular banks.  In FLUSH,
            // zero/invalid beats are shifted to drain the already accepted K.
            if (array_step && (state != CLEAR)) begin
                for (seq_ri = 0; seq_ri < ROWS; seq_ri = seq_ri + 1) begin
                    weight_skew[seq_ri][0]   <= (state == FEED) ? weight_data[seq_ri*DATA_WIDTH +: DATA_WIDTH] : '0;
                    weight_skew_v[seq_ri][0] <= (state == FEED) && pair_ready && (seq_ri < int'(rows_reg));
                    for (seq_di = 1; seq_di < ROWS; seq_di = seq_di + 1) begin
                        weight_skew[seq_ri][seq_di]   <= weight_skew[seq_ri][seq_di-1];
                        weight_skew_v[seq_ri][seq_di] <= weight_skew_v[seq_ri][seq_di-1];
                    end
                end
                for (seq_ci = 0; seq_ci < COLS; seq_ci = seq_ci + 1) begin
                    act_skew[seq_ci][0]   <= (state == FEED) ? activation_data[seq_ci*DATA_WIDTH +: DATA_WIDTH] : '0;
                    act_skew_v[seq_ci][0] <= (state == FEED) && pair_ready && (seq_ci < int'(cols_reg));
                    for (seq_di = 1; seq_di < COLS; seq_di = seq_di + 1) begin
                        act_skew[seq_ci][seq_di]   <= act_skew[seq_ci][seq_di-1];
                        act_skew_v[seq_ci][seq_di] <= act_skew_v[seq_ci][seq_di-1];
                    end
                end
            end

            case (state)
                IDLE: begin
                    if (start) begin
                        if ((active_rows == 0) || (int'(active_rows) > ROWS) ||
                            (active_cols == 0) || (int'(active_cols) > COLS) ||
                            (k_len == 0) || (int'(k_len) > K_MAX)) begin
                            config_error <= 1'b1;
                        end else begin
                            rows_reg    <= active_rows;
                            cols_reg    <= active_cols;
                            k_reg       <= k_len;
                            k_count     <= '0;
                            flush_count <= '0;
                            drain_col   <= '0;
                            state       <= CLEAR;
                        end
                    end
                end

                CLEAR: begin
                    // clear_acc/pipe_flush are asserted for this whole cycle;
                    // the array clears on this edge and feed begins next cycle.
                    state <= FEED;
                end

                FEED: begin
                    if (pair_ready) begin
                        if (k_count == k_reg - 1'b1) begin
                            if ((int'(rows_reg) + int'(cols_reg)) <= 2) begin
                                state <= DRAIN;
                            end else begin
                                flush_count <= '0;
                                state       <= FLUSH;
                            end
                        end else begin
                            k_count <= k_count + 1'b1;
                        end
                    end
                end

                FLUSH: begin
                    if ((int'(flush_count) + 1) >= flush_target) begin
                        state <= DRAIN;
                    end else begin
                        flush_count <= flush_count + 1'b1;
                    end
                end

                DRAIN: begin
                    if (out_ready) begin
                        if (drain_col == cols_reg - 1'b1) begin
                            done  <= 1'b1;
                            state <= IDLE;
                        end else begin
                            drain_col <= drain_col + 1'b1;
                        end
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end
endmodule
