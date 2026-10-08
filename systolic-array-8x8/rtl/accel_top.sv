`timescale 1ns/1ps

// AXI4-Lite control plane around the fixed-geometry conv1 datapath.
module accel_top #(
    parameter int ROWS = 8,
    parameter int C_OUT = 6,
    parameter int KERN_H = 5,
    parameter int KERN_W = 5,
    parameter int C_IN = 3,
    parameter int IN_H = 32,
    parameter int IN_W = 32,
    parameter int STRIDE = 1,
    parameter int PAD = 0,
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
    localparam int OUT_H = (IN_H + 2*PAD - KERN_H) / STRIDE + 1;
    localparam int OUT_W = (IN_W + 2*PAD - KERN_W) / STRIDE + 1;
    localparam int ROW_W = $clog2(ROWS+1);
    localparam int K_W = $clog2(K_MAX+1);
    localparam int TILE_W = $clog2(TILE_MAX);

    logic start, counter_clear, busy, layer_done;
    logic [31:0] cycle_count, cycle_count_raw, cycle_count_base;
    logic [31:0] stall_in, stall_out, frame_count;
    logic [7:0] error_flags, hw_error_set;
    logic lockstep_error, drain_stall;
    logic [8:0] cfg_c_in;
    logic [2:0] cfg_kh, cfg_kw;
    logic [1:0] cfg_stride, cfg_pad;
    logic [5:0] cfg_out_h, cfg_out_w;
    logic [7:0] cfg_tile_idx, cfg_tile_count;
    logic cfg_param_src, cfg_bypass;
    logic [15:0] cfg_k_len;
    logic signed [31:0] cfg_bias_q [0:7];
    logic signed [17:0] cfg_m0 [0:7];
    logic [5:0] cfg_shift_n [0:7];
    logic cfg_relu [0:7];
    logic geometry_ok, frame_start;
    logic [7:0] flags_seen;
    logic lockstep_seen;

    // TILE_CFG.tile_count counts output-channel tiles, not channels.  This
    // fixed conv1 instance has C_OUT=6 in its sole tile; the final tile size
    // cannot be reconstructed from tile_count alone for a generic layer.
    localparam logic [ROW_W-1:0] ACTIVE_ROWS = ROW_W'(C_OUT);

    assign geometry_ok =
        (cfg_c_in == 9'(C_IN)) &&
        (cfg_kh == 3'(KERN_H)) && (cfg_kw == 3'(KERN_W)) &&
        (cfg_stride == 2'(STRIDE)) && (cfg_pad == 2'(PAD)) &&
        (cfg_out_h == 6'(OUT_H)) && (cfg_out_w == 6'(OUT_W)) &&
        (cfg_k_len == 16'(C_IN*KERN_H*KERN_W)) &&
        (cfg_tile_idx == 8'd0) && (cfg_tile_count == 8'd1) &&
        !cfg_param_src && (C_OUT > 0) && (C_OUT <= ROWS);
    assign frame_start = start && geometry_ok;
    assign cycle_count = cycle_count_raw - cycle_count_base;

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
    assign hw_error_set[7] = start && !geometry_ok;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            stall_in <= '0;
            stall_out <= '0;
            frame_count <= '0;
            cycle_count_base <= '0;
            flags_seen <= '0;
            lockstep_seen <= 1'b0;
        end else begin
            flags_seen <= error_flags;
            lockstep_seen <= lockstep_error;
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
        .counter_clear(counter_clear), .cfg_bias_q(cfg_bias_q), .cfg_m0(cfg_m0),
        .cfg_shift_n(cfg_shift_n), .cfg_relu(cfg_relu), .cfg_bypass(cfg_bypass),
        .cfg_c_in(cfg_c_in), .cfg_kh(cfg_kh), .cfg_kw(cfg_kw),
        .cfg_stride(cfg_stride), .cfg_pad(cfg_pad), .cfg_out_h(cfg_out_h),
        .cfg_out_w(cfg_out_w), .cfg_tile_idx(cfg_tile_idx),
        .cfg_tile_count(cfg_tile_count), .cfg_param_src(cfg_param_src),
        .cfg_k_len(cfg_k_len)
    );

    conv1_top #(
        .ROWS(ROWS), .KERN_H(KERN_H), .KERN_W(KERN_W), .C_IN(C_IN),
        .IN_H(IN_H), .IN_W(IN_W), .STRIDE(STRIDE), .PAD(PAD),
        .K_MAX(K_MAX), .TILE_MAX(TILE_MAX), .W_DEPTH(W_DEPTH)
    ) u_conv1 (
        .clk(clk), .rst_n(rst_n), .s_valid(s_valid), .s_ready(s_ready),
        .s_data(s_data), .s_last(s_last),
        .w_wr_en(w_wr_en), .w_wr_bank(w_wr_bank), .w_wr_addr(w_wr_addr),
        .w_wr_data(w_wr_data), .frame_start(frame_start),
        .cfg_active_rows(ACTIVE_ROWS), .cfg_k_len(cfg_k_len[K_W-1:0]),
        .cfg_tile_idx(cfg_tile_idx[TILE_W-1:0]),
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
