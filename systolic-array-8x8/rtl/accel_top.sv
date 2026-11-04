`timescale 1ns/1ps

// AXI4-Lite control plane around the runtime-geometry convolution datapath.
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
    // Phase 2: connect this to window_gen.restart.  No partial local reset.
    output logic soft_reset
);
    localparam int ROW_W = $clog2(ROWS+1);
    localparam int K_W = $clog2(K_MAX+1);
    localparam int TILE_W = $clog2(TILE_MAX);
    localparam int IN_H_W = $clog2(IN_H_MAX+1);
    localparam int IN_W_W = $clog2(IN_W_MAX+1);
    localparam int GEOM_CALC_W = 19;

    logic start, counter_clear, cfg_commit, busy, layer_done;
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
    logic [15:0] cfg_k_len;
    logic [15:0] cfg_w_base_reg;
    logic [$clog2(W_DEPTH)-1:0] cfg_w_base;
    logic signed [31:0] cfg_bias_q [0:7];
    logic signed [17:0] cfg_m0 [0:7];
    logic [5:0] cfg_shift_n [0:7];
    logic cfg_relu [0:7];
    logic geometry_ok, frame_start;
    logic [ROW_W-1:0] cfg_active_rows;
    logic [IN_H_W-1:0] cfg_in_h;
    logic [IN_W_W-1:0] cfg_in_w;
    logic geometry_valid_reg;
    logic geometry_check_pending;
    logic basic_geometry_valid_reg;
    logic signed [GEOM_CALC_W-1:0] in_h_calc, in_w_calc;
    logic [GEOM_CALC_W-1:0] row_bytes_calc, weight_end_calc;
    logic [GEOM_CALC_W-1:0] row_bytes_reg, weight_end_reg;
    logic [8:0] committed_c_in, committed_c_phys;
    logic [2:0] committed_kh, committed_kw;
    logic [1:0] committed_stride, committed_pad;
    logic [5:0] committed_out_h, committed_out_w;
    logic [7:0] committed_tile_idx, committed_tile_count;
    logic [3:0] committed_last_rows;
    logic committed_param_src;
    logic [15:0] committed_k_len, committed_w_base;
    logic [7:0] flags_seen;
    logic lockstep_seen;

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

    assign geometry_ok = geometry_valid_reg &&
        (cfg_c_in == committed_c_in) &&
        (cfg_c_phys == committed_c_phys) &&
        (cfg_kh == committed_kh) && (cfg_kw == committed_kw) &&
        (cfg_stride == committed_stride) && (cfg_pad == committed_pad) &&
        (cfg_out_h == committed_out_h) && (cfg_out_w == committed_out_w) &&
        (cfg_tile_idx == committed_tile_idx) &&
        (cfg_tile_count == committed_tile_count) &&
        (cfg_last_rows == committed_last_rows) &&
        (cfg_param_src == committed_param_src) &&
        (cfg_k_len == committed_k_len) &&
        (cfg_w_base_reg == committed_w_base);
    assign frame_start = start && geometry_ok;
    assign cycle_count = cycle_count_raw - cycle_count_base;
    assign cfg_w_base = cfg_w_base_reg[$clog2(W_DEPTH)-1:0];

    // ADR-015 ERROR map:
    // [0] ERR_CFG_M0: register validator only.
    // [1] ERR_CFG_SHIFT: unused optional canary.
    // [2] ERR_ACC_OVF: requant overflow or lockstep failure.
    // [3] ERR_CFG_WR_BUSY: register validator only.
    // [4] ERR_TLAST_EARLY: layer_ctrl bad tile-last / early window-done.
    // [5] ERR_TLAST_LATE: layer_ctrl changed active columns.
    // [6] ERR_TIMEOUT: layer_ctrl command/config/accept errors.
    // [7] ERR_PARAM_INCOMPLETE: register validator or rejected geometry.
    // drain_stall is expected flow control, not an ERROR event.
    assign hw_error_set[0] = 1'b0;
    assign hw_error_set[1] = 1'b0;
    assign hw_error_set[2] = (|(m_ovf_flat & m_lane_valid) && m_valid && m_ready) ||
                              (lockstep_error && !lockstep_seen);
    assign hw_error_set[3] = 1'b0;
    assign hw_error_set[4] = |((error_flags & ~flags_seen) & 8'h48);
    assign hw_error_set[5] = |((error_flags & ~flags_seen) & 8'h10);
    assign hw_error_set[6] = |((error_flags & ~flags_seen) & 8'h27);
    // conv1_top error_flags[7]: window geometry or cfg_k_len mismatch.
    assign hw_error_set[7] = (start && !geometry_ok) ||
                             |((error_flags & ~flags_seen) & 8'h80);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            stall_in <= '0;
            stall_out <= '0;
            frame_count <= '0;
            cycle_count_base <= '0;
            flags_seen <= '0;
            lockstep_seen <= 1'b0;
            cfg_in_h <= '0;
            cfg_in_w <= '0;
            geometry_valid_reg <= 1'b0;
            geometry_check_pending <= 1'b0;
            basic_geometry_valid_reg <= 1'b0;
            row_bytes_reg <= '0;
            weight_end_reg <= '0;
            committed_c_in <= '0;
            committed_c_phys <= '0;
            committed_kh <= '0;
            committed_kw <= '0;
            committed_stride <= '0;
            committed_pad <= '0;
            committed_out_h <= '0;
            committed_out_w <= '0;
            committed_tile_idx <= '0;
            committed_tile_count <= '0;
            committed_last_rows <= '0;
            committed_param_src <= 1'b0;
            committed_k_len <= '0;
            committed_w_base <= '0;
        end else begin
            flags_seen <= error_flags;
            lockstep_seen <= lockstep_error;
            geometry_check_pending <= 1'b0;
            if (cfg_commit) begin
                cfg_in_h <= IN_H_W'(in_h_calc);
                cfg_in_w <= IN_W_W'(in_w_calc);
                row_bytes_reg <= row_bytes_calc;
                weight_end_reg <= weight_end_calc;
                geometry_check_pending <= 1'b1;
                geometry_valid_reg <= 1'b0;
                basic_geometry_valid_reg <=
                    (cfg_c_in != 0) && (cfg_c_in <= C_MAX) &&
                    (cfg_c_phys >= cfg_c_in) && (cfg_c_phys <= C_MAX) &&
                    (cfg_kh != 0) && (cfg_kh <= K_H_MAX) &&
                    (cfg_kw != 0) && (cfg_kw <= K_W_MAX) &&
                    (cfg_stride == 1) && (cfg_pad <= PAD_MAX) &&
                    (in_h_calc > 0) && (in_h_calc <= IN_H_MAX) &&
                    (in_w_calc > 0) && (in_w_calc <= IN_W_MAX) &&
                    (cfg_k_len != 0) && (cfg_k_len <= K_MAX) &&
                    (cfg_tile_count != 0) &&
                    (cfg_tile_count <= TILE_MAX) &&
                    (cfg_tile_idx < cfg_tile_count) &&
                    (cfg_last_rows <= ROWS) && !cfg_param_src;
                committed_c_in <= cfg_c_in;
                committed_c_phys <= cfg_c_phys;
                committed_kh <= cfg_kh;
                committed_kw <= cfg_kw;
                committed_stride <= cfg_stride;
                committed_pad <= cfg_pad;
                committed_out_h <= cfg_out_h;
                committed_out_w <= cfg_out_w;
                committed_tile_idx <= cfg_tile_idx;
                committed_tile_count <= cfg_tile_count;
                committed_last_rows <= cfg_last_rows;
                committed_param_src <= cfg_param_src;
                committed_k_len <= cfg_k_len;
                committed_w_base <= cfg_w_base_reg;
            end else if (geometry_check_pending) begin
                geometry_valid_reg <= basic_geometry_valid_reg &&
                                      (row_bytes_reg <= ROW_BYTES_MAX) &&
                                      (weight_end_reg <= W_DEPTH);
            end
            if (counter_clear) begin
                cycle_count_base <= cycle_count_raw;
                stall_in <= '0;
                stall_out <= '0;
                frame_count <= '0;
            end else begin
                if (s_valid && !s_ready) stall_in <= stall_in + 1'b1;
                if (m_valid && !m_ready) stall_out <= stall_out + 1'b1;
                if (layer_done) frame_count <= frame_count + 1'b1;
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
        .busy(busy), .done(layer_done), .cycle_count(cycle_count),
        .stall_in(stall_in), .stall_out(stall_out), .frame_count(frame_count),
        .table_valid(1'b0), // Stage 1 has no BRAM parameter table.
        .hw_error_set(hw_error_set), .start(start), .soft_reset(soft_reset),
        .counter_clear(counter_clear), .cfg_commit(cfg_commit),
        .cfg_bias_q(cfg_bias_q), .cfg_m0(cfg_m0),
        .cfg_shift_n(cfg_shift_n), .cfg_relu(cfg_relu), .cfg_bypass(cfg_bypass),
        .cfg_c_in(cfg_c_in), .cfg_c_phys(cfg_c_phys),
        .cfg_kh(cfg_kh), .cfg_kw(cfg_kw),
        .cfg_stride(cfg_stride), .cfg_pad(cfg_pad), .cfg_out_h(cfg_out_h),
        .cfg_out_w(cfg_out_w), .cfg_tile_idx(cfg_tile_idx),
        .cfg_tile_count(cfg_tile_count), .cfg_last_rows(cfg_last_rows),
        .cfg_param_src(cfg_param_src), .cfg_k_len(cfg_k_len),
        .cfg_w_base(cfg_w_base_reg)
    );

    conv1_top #(
        .ROWS(ROWS), .IN_H_MAX(IN_H_MAX), .IN_W_MAX(IN_W_MAX), .C_MAX(C_MAX),
        .ROW_BYTES_MAX(ROW_BYTES_MAX), .K_H_MAX(K_H_MAX), .K_W_MAX(K_W_MAX),
        .PAD_MAX(PAD_MAX), .K_MAX(K_MAX), .TILE_MAX(TILE_MAX), .W_DEPTH(W_DEPTH)
    ) u_conv1 (
        .clk(clk), .rst_n(rst_n), .s_valid(s_valid), .s_ready(s_ready),
        .s_data(s_data), .s_last(s_last),
        .w_wr_en(w_wr_en), .w_wr_bank(w_wr_bank), .w_wr_addr(w_wr_addr),
        .w_wr_data(w_wr_data), .frame_start(frame_start),
        .cfg_active_rows(cfg_active_rows), .cfg_k_len(cfg_k_len[K_W-1:0]),
        .cfg_tile_idx(cfg_tile_idx[TILE_W-1:0]),
        .cfg_in_h(cfg_in_h), .cfg_in_w(cfg_in_w), .cfg_c_in(cfg_c_in),
        .cfg_c_phys(cfg_c_phys), .cfg_kh(cfg_kh), .cfg_kw(cfg_kw),
        .cfg_pad(cfg_pad), .cfg_w_base(cfg_w_base),
        .cfg_bias_q(cfg_bias_q), .cfg_m0(cfg_m0),
        .cfg_shift_n(cfg_shift_n), .cfg_relu(cfg_relu), .cfg_bypass(cfg_bypass),
        .m_valid(m_valid), .m_ready(m_ready), .m_y_flat(m_y_flat),
        .m_lane_valid(m_lane_valid), .m_col(m_col), .m_last(m_last),
        .m_sat_flat(m_sat_flat), .m_ovf_flat(m_ovf_flat),
        .busy(busy), .layer_done(layer_done), .window_done(), .tile_count(),
        .error_flags(error_flags), .lockstep_error(lockstep_error),
        .drain_stall(drain_stall), .engine_cycle_count(cycle_count_raw)
    );
endmodule
