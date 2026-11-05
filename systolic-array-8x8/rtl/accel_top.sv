`timescale 1ns/1ps

// AXI4-Lite control plane around the single runtime-geometry layer datapath
// (faz4 contract, section 2).  Every layer of the network runs through this
// one path, selected per pass by the committed DP_CFG:
//
//   src_sel=0: s_* stream  --------\
//   src_sel=1: act_buffer HWC read -+-> conv1_top -> lane mask
//        -> pool2x2 (pool_en=1) or bypass
//        -> dst_sel=0: act_buffer write (tile plane = tile_idx)
//        -> dst_sel=1: m_* stream (m_last = last beat of the pass)
//
// One START runs one PASS: one output-channel tile of one layer, i.e. one
// tile plane in raster order (pooled raster with pool_en).  The cfg_* image
// is the ACTIVE register image, which only an accepted COMMIT changes and
// COMMIT is refused while busy, so it is frozen for the whole pass.
//
// START cycle order (S = cycle of axi_lite_regs' start pulse):
//   S   : the committed geometry check is sampled; pass_busy and go are set,
//         the destination counters and lane mask are loaded.
//   S+1 : go = conv1_top restart (window_gen leaves ST_DONE or rewinds its
//         idle state; the line-buffer clear holds its s_ready low in this
//         cycle) + layer_ctrl frame_start + act_buffer rd_start (src_sel=1)
//         + wr_start (dst_sel=0).  layer_ctrl reaches ST_WAIT_TILE at S+2,
//         when window_gen already reports !done.
//   S+2 : earliest accepted source beat.  Sources are gated by pass_busy, so
//         no beat can enter window_gen outside a pass (in particular not in
//         its idle-after-reset state, which would make the restart illegal).
// Pass complete: the destination has taken the last beat (act_buffer wr_done,
// or the m_* handshake with m_last) and conv1_top is idle again.  Only then
// does busy fall and STATUS.DONE / FRAME_COUNT advance.
//
// SOFT_RESET: conv1_top and pool2x2 are reset through the registered dp_rst_n
// (they have no soft-reset port), act_buffer through its soft_reset port
// (memory, bank select and stored geometry kept), and the pass state here is
// cleared.  The register file keeps its active image, so START works again
// immediately; a new COMMIT works as usual.
module accel_top #(
    parameter int ROWS = 8,
    parameter int IN_H_MAX = 48,
    parameter int IN_W_MAX = 48,
    parameter int C_MAX = 511,
    parameter int ROW_BYTES_MAX = 512,
    parameter int K_H_MAX = 5,
    parameter int K_W_MAX = 5,
    parameter int PAD_MAX = 2,
    parameter int K_MAX = 1024,
    parameter int TILE_MAX = 16,
    parameter int W_DEPTH = 8192,
    parameter int ACT_DEPTH = 4608,   // act_buffer words per bank
    parameter int ADDR_W = 12
) (
    input logic clk, rst_n,
    input logic [ADDR_W-1:0] s_axi_awaddr,
    input logic s_axi_awvalid,
    output logic s_axi_awready,
    input logic [31:0] s_axi_wdata,
    input logic [3:0] s_axi_wstrb,
    input logic s_axi_wvalid,
    output logic s_axi_wready,
    output logic [1:0] s_axi_bresp,
    output logic s_axi_bvalid,
    input logic s_axi_bready,
    input logic [ADDR_W-1:0] s_axi_araddr,
    input logic s_axi_arvalid,
    output logic s_axi_arready,
    output logic [31:0] s_axi_rdata,
    output logic [1:0] s_axi_rresp,
    output logic s_axi_rvalid,
    input logic s_axi_rready,
    input logic s_valid,
    output logic s_ready,
    input logic [63:0] s_data,
    input logic s_last,
    input logic w_wr_en,
    input logic [$clog2(ROWS)-1:0] w_wr_bank,
    input logic [$clog2(W_DEPTH)-1:0] w_wr_addr,
    input logic [7:0] w_wr_data,
    output logic m_valid,
    input logic m_ready,
    output logic [ROWS*8-1:0] m_y_flat,
    output logic [ROWS-1:0] m_lane_valid,
    output logic [$clog2(ROWS+1)-1:0] m_col,
    output logic m_last,
    output logic [ROWS-1:0] m_sat_flat,
    output logic [ROWS-1:0] m_ovf_flat,
    // CONTROL.SOFT_RESET pulse, already fanned out to the datapath here.
    output logic soft_reset
);
    localparam int ROW_W = $clog2(ROWS+1);
    localparam int K_W = $clog2(K_MAX+1);
    localparam int TILE_W = $clog2(TILE_MAX);
    localparam int CT_W = $clog2(TILE_MAX+1);
    localparam int IN_H_W = $clog2(IN_H_MAX+1);
    localparam int IN_W_W = $clog2(IN_W_MAX+1);
    localparam int GEOM_CALC_W = 19;

    logic start, counter_clear, cfg_commit, busy, layer_swap;
    logic [31:0] cycle_count, cycle_count_raw, cycle_count_base;
    logic [31:0] stall_in, stall_out, frame_count;
    logic [7:0] error_flags, hw_error_set;
    logic lockstep_error, drain_stall;
    logic [8:0] cfg_c_in, cfg_c_phys;
    logic [2:0] cfg_kh, cfg_kw;
    logic [1:0] cfg_stride, cfg_pad;
    logic [5:0] cfg_out_h, cfg_out_w;
    logic [7:0] cfg_tile_idx, cfg_tile_count;
    logic [3:0] cfg_last_rows;
    logic cfg_param_src, cfg_bypass;
    logic cfg_src_sel, cfg_pool_en, cfg_dst_sel;
    logic [15:0] cfg_k_len;
    logic [15:0] cfg_w_base_reg;
    logic [$clog2(W_DEPTH)-1:0] cfg_w_base;
    logic signed [31:0] cfg_bias_q [0:7];
    logic signed [17:0] cfg_m0 [0:7];
    logic [5:0] cfg_shift_n [0:7];
    logic cfg_relu [0:7];
    logic geometry_ok;
    logic [ROW_W-1:0] cfg_active_rows;
    logic [IN_H_W-1:0] cfg_in_h;
    logic [IN_W_W-1:0] cfg_in_w;
    logic geometry_valid_reg;
    logic geometry_check_pending;
    logic basic_geometry_valid_reg;
    logic signed [GEOM_CALC_W-1:0] in_h_calc, in_w_calc;
    logic [GEOM_CALC_W-1:0] row_bytes_calc, weight_end_calc;
    logic [GEOM_CALC_W-1:0] row_bytes_reg, weight_end_reg;
    logic [7:0] flags_seen;
    logic lockstep_seen;

    // Pass sequencing.
    logic start_ok, go, pass_busy, dst_done_seen, pass_done, dst_last_fire;
    logic dp_rst_n;
    logic conv_busy;
    logic restart_error, restart_seen;

    // Source mux -> conv1_top.
    logic src_valid, src_ready, src_last;
    logic [63:0] src_data;

    // conv1_top -> lane mask -> pool / bypass -> destination.
    logic conv_m_valid, conv_m_ready;
    logic [ROWS*8-1:0] conv_m_y, conv_y_masked;
    logic [ROWS-1:0] conv_m_lane_valid, conv_m_sat, conv_m_ovf;
    logic [ROW_W-1:0] conv_m_col;
    logic [ROWS-1:0] lane_mask;
    logic pool_s_ready, pool_m_valid, pool_cfg_error;
    logic [ROWS*8-1:0] pool_m_data;
    logic post_valid, post_ready, post_fire;
    logic [ROWS*8-1:0] post_data;
    logic [IN_H_W-1:0] dst_h, dst_h_m1, dst_row;
    logic [IN_W_W-1:0] dst_w, dst_w_m1, dst_col;

    // act_buffer.
    logic ab_wr_valid, ab_wr_ready, ab_wr_done;
    logic ab_rd_valid, ab_rd_ready, ab_rd_last, ab_rd_busy;
    logic [ROWS*8-1:0] ab_rd_data;
    logic ab_seq_error, ab_ovf_error, ab_seq_seen, ab_ovf_seen;

    // Runtime-derived values are sampled only after a successful COMMIT.  No
    // multiply or subtract is present in a per-beat address path.
    always_comb begin
        in_h_calc = $signed({1'b0, cfg_out_h}) +
                    $signed({1'b0, cfg_kh}) - 1 -
                    (2 * $signed({1'b0, cfg_pad}));
        in_w_calc = $signed({1'b0, cfg_out_w}) +
                    $signed({1'b0, cfg_kw}) - 1 -
                    (2 * $signed({1'b0, cfg_pad}));
        row_bytes_calc = GEOM_CALC_W'($unsigned(in_w_calc)) *
                         GEOM_CALC_W'($unsigned(cfg_c_phys));
        weight_end_calc = $unsigned(cfg_w_base_reg) +
                          (GEOM_CALC_W'({1'b0, cfg_tile_idx} + 1'b1) *
                           GEOM_CALC_W'($unsigned(cfg_k_len)));
    end

    always_comb begin
        if ((cfg_tile_count != 0) &&
            (cfg_tile_idx < (cfg_tile_count - 1'b1)))
            cfg_active_rows = ROW_W'(ROWS);
        else if (cfg_last_rows == 0)
            cfg_active_rows = ROW_W'(ROWS);
        else
            cfg_active_rows = ROW_W'(cfg_last_rows);
    end

    // Destination plane: the pooled raster with pool_en, else the conv raster.
    always_comb begin
        dst_h = cfg_pool_en ? IN_H_W'(cfg_out_h >> 1) : IN_H_W'(cfg_out_h);
        dst_w = cfg_pool_en ? IN_W_W'(cfg_out_w >> 1) : IN_W_W'(cfg_out_w);
    end

    // cfg_* is the active image, written only by an accepted COMMIT, so the
    // old "changed after commit" comparison is gone: the validator result
    // alone decides.
    assign geometry_ok = geometry_valid_reg;
    // axi_lite_regs only pulses start while !busy.
    assign start_ok = start && geometry_ok;
    assign busy = pass_busy;
    assign cycle_count = cycle_count_raw - cycle_count_base;
    assign cfg_w_base = cfg_w_base_reg[$clog2(W_DEPTH)-1:0];

    // Source mux.  rd_data/rd_last are meaningless while !rd_valid, so both
    // are qualified; the unselected source sees ready low.
    assign src_valid = pass_busy && (cfg_src_sel ? ab_rd_valid : s_valid);
    assign src_data = cfg_src_sel ? (ab_rd_valid ? ab_rd_data : 64'h0) : s_data;
    assign src_last = cfg_src_sel ? (ab_rd_valid && ab_rd_last) : s_last;
    assign s_ready = pass_busy && !cfg_src_sel && src_ready;
    assign ab_rd_ready = pass_busy && cfg_src_sel && src_ready;

    // Inactive output rows are forced to zero.  lane_mask is the low
    // active_rows lanes, the same mask compute_engine/requant put on
    // m_lane_valid, registered at START from the frozen active image.
    always_comb begin
        for (int r = 0; r < ROWS; r++)
            conv_y_masked[r*8 +: 8] = lane_mask[r] ? conv_m_y[r*8 +: 8] : 8'h00;
    end

    assign conv_m_ready = cfg_pool_en ? pool_s_ready : post_ready;
    assign post_valid = cfg_pool_en ? pool_m_valid : conv_m_valid;
    assign post_data = cfg_pool_en ? pool_m_data : conv_y_masked;
    assign post_ready = pass_busy && (cfg_dst_sel ? m_ready : ab_wr_ready);
    assign post_fire = post_valid && post_ready;
    assign ab_wr_valid = pass_busy && !cfg_dst_sel && post_valid;

    // conv1_top's own m_last marks each 8-column group, so the frame end of
    // the m_* stream comes from the destination raster counters.
    assign m_valid = pass_busy && cfg_dst_sel && post_valid;
    assign m_y_flat = post_data;
    assign m_lane_valid = lane_mask;
    assign m_last = (dst_row == dst_h_m1) && (dst_col == dst_w_m1);
    assign m_col = cfg_pool_en ? '0 : conv_m_col;
    assign m_sat_flat = cfg_pool_en ? '0 : conv_m_sat;
    assign m_ovf_flat = cfg_pool_en ? '0 : conv_m_ovf;

    assign dst_last_fire = cfg_dst_sel ? (m_valid && m_ready && m_last) : ab_wr_done;
    assign pass_done = pass_busy && dst_done_seen && !conv_busy;

    // ADR-015 ERROR map:
    // [0] ERR_CFG_M0: register validator only.
    // [1] ERR_CFG_SHIFT: unused optional canary.
    // [2] ERR_ACC_OVF: requant overflow or lockstep failure.
    // [3] ERR_CFG_WR_BUSY: register validator only.
    // [4] ERR_TLAST_EARLY: layer_ctrl bad tile-last / early window-done.
    // [5] ERR_TLAST_LATE: layer_ctrl changed active columns; act_buffer read
    //     stream still not drained when the pass completed (source longer
    //     than the frame the geometry describes).
    // [6] ERR_TIMEOUT: layer_ctrl command/config/accept errors; act_buffer
    //     seq_error (start/swap while busy, read with no layer, bad write
    //     geometry); window_gen restart refused.
    // [7] ERR_PARAM_INCOMPLETE: register validator or rejected geometry;
    //     act_buffer ovf_error (layer footprint > ACT_DEPTH); pool2x2
    //     cfg_error at START of a pool_en pass.
    // Sticky sources are edge-detected, so a W1C clears them until they fire
    // again.  A datapath error never ends the pass by itself: busy stays up
    // until SOFT_RESET, and the PS sees STATUS.ERROR instead of DONE.
    // drain_stall is expected flow control, not an ERROR event.
    assign hw_error_set[0] = 1'b0;
    assign hw_error_set[1] = 1'b0;
    assign hw_error_set[2] = (|(conv_m_ovf & conv_m_lane_valid) &&
                              conv_m_valid && conv_m_ready) ||
                              (lockstep_error && !lockstep_seen);
    assign hw_error_set[3] = 1'b0;
    assign hw_error_set[4] = |((error_flags & ~flags_seen) & 8'h48);
    assign hw_error_set[5] = |((error_flags & ~flags_seen) & 8'h10) ||
                             (pass_done && cfg_src_sel && ab_rd_busy);
    assign hw_error_set[6] = |((error_flags & ~flags_seen) & 8'h27) ||
                             (ab_seq_error && !ab_seq_seen) ||
                             (restart_error && !restart_seen);
    // conv1_top error_flags[7]: window geometry or cfg_k_len mismatch.
    assign hw_error_set[7] = (start && !geometry_ok) ||
                             |((error_flags & ~flags_seen) & 8'h80) ||
                             (ab_ovf_error && !ab_ovf_seen) ||
                             (go && cfg_pool_en && pool_cfg_error);

    // Datapath reset: registered so SOFT_RESET reaches conv1_top and pool2x2
    // as an ordinary synchronous reset one cycle after the pulse.
    always_ff @(posedge clk)
        dp_rst_n <= rst_n && !soft_reset;

    always_ff @(posedge clk) begin
        if (!rst_n || soft_reset) begin
            go <= 1'b0;
            pass_busy <= 1'b0;
            dst_done_seen <= 1'b0;
        end else begin
            go <= start_ok;
            if (start_ok)
                pass_busy <= 1'b1;
            else if (pass_done)
                pass_busy <= 1'b0;
            if (start_ok || pass_done)
                dst_done_seen <= 1'b0;
            else if (pass_busy && dst_last_fire)
                dst_done_seen <= 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            lane_mask <= '0;
            dst_h_m1 <= '0;
            dst_w_m1 <= '0;
            dst_row <= '0;
            dst_col <= '0;
        end else if (start_ok) begin
            for (int r = 0; r < ROWS; r++)
                lane_mask[r] <= (r < cfg_active_rows);
            dst_h_m1 <= dst_h - 1'b1;
            dst_w_m1 <= dst_w - 1'b1;
            dst_row <= '0;
            dst_col <= '0;
        end else if (post_fire) begin
            if (dst_col == dst_w_m1) begin
                dst_col <= '0;
                dst_row <= dst_row + 1'b1;
            end else begin
                dst_col <= dst_col + 1'b1;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            stall_in <= '0;
            stall_out <= '0;
            frame_count <= '0;
            cycle_count_base <= '0;
            flags_seen <= '0;
            lockstep_seen <= 1'b0;
            restart_seen <= 1'b0;
            ab_seq_seen <= 1'b0;
            ab_ovf_seen <= 1'b0;
            cfg_in_h <= '0;
            cfg_in_w <= '0;
            geometry_valid_reg <= 1'b0;
            geometry_check_pending <= 1'b0;
            basic_geometry_valid_reg <= 1'b0;
            row_bytes_reg <= '0;
            weight_end_reg <= '0;
        end else begin
            flags_seen <= error_flags;
            lockstep_seen <= lockstep_error;
            restart_seen <= restart_error;
            ab_seq_seen <= ab_seq_error;
            ab_ovf_seen <= ab_ovf_error;
            geometry_check_pending <= 1'b0;
            if (cfg_commit) begin
                cfg_in_h <= IN_H_W'(in_h_calc);
                cfg_in_w <= IN_W_W'(in_w_calc);
                row_bytes_reg <= row_bytes_calc;
                weight_end_reg <= weight_end_calc;
                geometry_check_pending <= 1'b1;
                geometry_valid_reg <= 1'b0;
                // Parity with window_gen's cfg_error: out_h/out_w of 0 and
                // pad >= kh/kw are rejected here, not inside the pass.
                basic_geometry_valid_reg <=
                    (cfg_c_in != 0) && (cfg_c_in <= C_MAX) &&
                    (cfg_c_phys >= cfg_c_in) && (cfg_c_phys <= C_MAX) &&
                    (cfg_kh != 0) && (cfg_kh <= K_H_MAX) &&
                    (cfg_kw != 0) && (cfg_kw <= K_W_MAX) &&
                    (cfg_stride == 1) && (cfg_pad <= PAD_MAX) &&
                    (cfg_pad < cfg_kh) && (cfg_pad < cfg_kw) &&
                    (cfg_out_h != 0) && (cfg_out_w != 0) &&
                    (in_h_calc > 0) && (in_h_calc <= IN_H_MAX) &&
                    (in_w_calc > 0) && (in_w_calc <= IN_W_MAX) &&
                    (cfg_k_len != 0) && (cfg_k_len <= K_MAX) &&
                    (cfg_tile_count != 0) &&
                    (cfg_tile_count <= TILE_MAX) &&
                    (cfg_tile_idx < cfg_tile_count) &&
                    (cfg_last_rows <= ROWS) && !cfg_param_src;
            end else if (geometry_check_pending) begin
                geometry_valid_reg <= basic_geometry_valid_reg &&
                                      (row_bytes_reg <= ROW_BYTES_MAX) &&
                                      (weight_end_reg <= W_DEPTH);
            end
            // The engine cycle counter restarts from 0 under the datapath
            // reset that follows every SOFT_RESET/counter_clear pulse.
            if (!dp_rst_n)
                cycle_count_base <= '0;
            else if (counter_clear)
                cycle_count_base <= cycle_count_raw;
            if (counter_clear) begin
                stall_in <= '0;
                stall_out <= '0;
                frame_count <= '0;
            end else begin
                if (s_valid && !s_ready) stall_in <= stall_in + 1'b1;
                if (m_valid && !m_ready) stall_out <= stall_out + 1'b1;
                if (pass_done) frame_count <= frame_count + 1'b1;
            end
        end
    end

    axi_lite_regs #(.ADDR_W(ADDR_W)) u_regs (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready), .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),
        .busy(busy), .done(pass_done), .cycle_count(cycle_count),
        .stall_in(stall_in), .stall_out(stall_out), .frame_count(frame_count),
        .table_valid(1'b0), // Stage 1 has no BRAM parameter table.
        .hw_error_set(hw_error_set), .start(start), .soft_reset(soft_reset),
        .counter_clear(counter_clear), .cfg_commit(cfg_commit),
        .layer_swap(layer_swap),
        .cfg_bias_q(cfg_bias_q), .cfg_m0(cfg_m0),
        .cfg_shift_n(cfg_shift_n), .cfg_relu(cfg_relu), .cfg_bypass(cfg_bypass),
        .cfg_c_in(cfg_c_in), .cfg_c_phys(cfg_c_phys),
        .cfg_kh(cfg_kh), .cfg_kw(cfg_kw),
        .cfg_stride(cfg_stride), .cfg_pad(cfg_pad), .cfg_out_h(cfg_out_h),
        .cfg_out_w(cfg_out_w), .cfg_tile_idx(cfg_tile_idx),
        .cfg_tile_count(cfg_tile_count), .cfg_last_rows(cfg_last_rows),
        .cfg_param_src(cfg_param_src), .cfg_k_len(cfg_k_len),
        .cfg_w_base(cfg_w_base_reg),
        .cfg_src_sel(cfg_src_sel), .cfg_pool_en(cfg_pool_en),
        .cfg_dst_sel(cfg_dst_sel)
    );

    conv1_top #(
        .ROWS(ROWS), .IN_H_MAX(IN_H_MAX), .IN_W_MAX(IN_W_MAX), .C_MAX(C_MAX),
        .ROW_BYTES_MAX(ROW_BYTES_MAX), .K_H_MAX(K_H_MAX), .K_W_MAX(K_W_MAX),
        .PAD_MAX(PAD_MAX), .K_MAX(K_MAX), .TILE_MAX(TILE_MAX), .W_DEPTH(W_DEPTH)
    ) u_conv1 (
        .clk(clk), .rst_n(dp_rst_n), .s_valid(src_valid), .s_ready(src_ready),
        .s_data(src_data), .s_last(src_last),
        .restart(go), .restart_error(restart_error),
        .w_wr_en(w_wr_en), .w_wr_bank(w_wr_bank), .w_wr_addr(w_wr_addr),
        .w_wr_data(w_wr_data), .frame_start(go),
        .cfg_active_rows(cfg_active_rows), .cfg_k_len(cfg_k_len[K_W-1:0]),
        .cfg_tile_idx(cfg_tile_idx[TILE_W-1:0]),
        .cfg_in_h(cfg_in_h), .cfg_in_w(cfg_in_w), .cfg_c_in(cfg_c_in),
        .cfg_c_phys(cfg_c_phys), .cfg_kh(cfg_kh), .cfg_kw(cfg_kw),
        .cfg_pad(cfg_pad), .cfg_w_base(cfg_w_base),
        .cfg_bias_q(cfg_bias_q), .cfg_m0(cfg_m0),
        .cfg_shift_n(cfg_shift_n), .cfg_relu(cfg_relu), .cfg_bypass(cfg_bypass),
        .m_valid(conv_m_valid), .m_ready(conv_m_ready), .m_y_flat(conv_m_y),
        .m_lane_valid(conv_m_lane_valid), .m_col(conv_m_col), .m_last(),
        .m_sat_flat(conv_m_sat), .m_ovf_flat(conv_m_ovf),
        .busy(conv_busy), .layer_done(), .window_done(), .tile_count(),
        .error_flags(error_flags), .lockstep_error(lockstep_error),
        .drain_stall(drain_stall), .engine_cycle_count(cycle_count_raw)
    );

    // One tile plane per pass, so the pool sees a single tile.
    pool2x2 #(
        .IN_H_MAX(IN_H_MAX), .IN_W_MAX(IN_W_MAX), .C_TILE_MAX(1), .TILE(ROWS)
    ) u_pool (
        .clk(clk), .rst_n(dp_rst_n),
        .cfg_in_h(IN_H_W'(cfg_out_h)), .cfg_in_w(IN_W_W'(cfg_out_w)),
        .cfg_c_tiles(1'b1),
        .s_valid(cfg_pool_en && conv_m_valid), .s_ready(pool_s_ready),
        .s_data(conv_y_masked), .s_last(1'b0),
        .m_valid(pool_m_valid), .m_ready(post_ready), .m_data(pool_m_data),
        .m_last(), .cfg_error(pool_cfg_error)
    );

    act_buffer #(
        .LANES(ROWS), .OUT_H_MAX(IN_H_MAX), .OUT_W_MAX(IN_W_MAX),
        .C_TILE_MAX(TILE_MAX), .DEPTH(ACT_DEPTH)
    ) u_act (
        .clk(clk), .rst_n(rst_n), .soft_reset(soft_reset),
        .wr_start(go && !cfg_dst_sel),
        .cfg_wr_h(dst_h), .cfg_wr_w(dst_w),
        .cfg_wr_tile(CT_W'(cfg_tile_idx)), .cfg_wr_tiles(CT_W'(cfg_tile_count)),
        .wr_valid(ab_wr_valid), .wr_ready(ab_wr_ready), .wr_data(post_data),
        .wr_done(ab_wr_done),
        .layer_swap(layer_swap),
        .rd_start(go && cfg_src_sel),
        .rd_valid(ab_rd_valid), .rd_ready(ab_rd_ready), .rd_data(ab_rd_data),
        .rd_last(ab_rd_last), .rd_busy(ab_rd_busy), .wr_busy(),
        .buf_sel(), .frame_count(),
        .seq_error(ab_seq_error), .ovf_error(ab_ovf_error)
    );
endmodule
