`timescale 1ns/1ps

// Conv1 integration top: the first end-to-end datapath of the accelerator.
//
//   s_* (64-bit HWC frame beats)
//        -> window_gen (+ its internal line_buffer)
//        -> layer_ctrl  (tile sequencer: metadata -> start commands)
//        -> compute_engine  <- weight_feeder (ADR-011 banks)
//        -> requant_array
//        -> m_* (64-bit INT8 activation beats, one output column per beat)
//
// Scope is deliberately one layer and one output-channel tile: LeNet-5 conv1
// has six output channels, so `active_rows = 6` covers it in a single pass and
// the conv2 activation-replay problem (ADR-018 addendum item 3) cannot appear.
// This top does NOT contain the intermediate activation buffer.  Its physical
// layout was locked on 2026-10-07 (ADR-018 Decision 2: padded tile-major,
// addr = (((c>>3)*H + h)*W + w)*8 + (c&7)); the address generator and the
// ping-pong swap are still unwritten, so the requantized stream leaves this
// block directly.  The C_LOGICAL/C_PHYS_STRIDE split that layout needs IS now
// in window_gen/line_buffer and is carried on this top's cfg ports, so a
// conv2-geometry layer (c_in=6, c_phys=8) is expressible here.
//
// Runtime geometry (faz3-param).  One instance runs every layer: in_h, in_w,
// c_in, c_phys, kh, kw and pad are quasi-static cfg_* inputs bounded by the
// *_MAX envelope parameters, changed only between frames.  An out-of-envelope
// geometry, or a cfg_k_len that disagrees with the generator's own latched
// c_in*kh*kw, sets error_flags[7] (reserved-zero in layer_ctrl).  Like the
// layer_ctrl bits it is cleared by frame_start and set while busy.
//
// Every submodule instantiated here was previously verified only in isolation.
// This is the first time window_gen, compute_engine and requant_array share one
// clock, one reset and one backpressure chain, which is also the first time
// they are exposed to synthesis and timing analysis together.
module conv1_top #(
    parameter int ROWS       = 8,
    parameter int COLS       = 8,
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH  = 32,
    parameter int M0_W       = 18,

    // Geometry envelope.  The actual layer geometry is on the cfg_* ports;
    // these only size the hardware.  Stride is always 1.
    parameter int IN_H_MAX      = 48,
    parameter int IN_W_MAX      = 48,
    parameter int C_MAX         = 511,
    parameter int ROW_BYTES_MAX = 512,    // max in_w * c_phys
    parameter int K_H_MAX       = 5,
    parameter int K_W_MAX       = 5,
    parameter int PAD_MAX       = 2,

    parameter int K_MAX      = 1024,
    parameter int TILE_MAX   = 16,
    parameter int W_DEPTH    = 8192,   // weight words per bank

    parameter int ROW_W      = $clog2(ROWS+1),
    parameter int COL_W      = $clog2(COLS+1),
    parameter int K_W        = $clog2(K_MAX+1),
    parameter int TILE_W     = $clog2(TILE_MAX)
) (
    input  logic                        clk,
    input  logic                        rst_n,

    // Input frame stream (ADR-006 semantics, TKEEP functionally all ones).
    input  logic                        s_valid,
    output logic                        s_ready,
    input  logic [63:0]                 s_data,
    input  logic                        s_last,

    // Frame restart (window_gen's ST_DONE is no longer terminal).  One-cycle
    // pulse; accepted only once the generator is done or still idle.  A
    // mid-frame pulse is refused and latches restart_error, which is a
    // separate boundary output on purpose: error_flags belongs to layer_ctrl
    // and this condition is not layer_ctrl's to report.  Defaulted so an
    // existing instantiation that does not drive it stays at a known 0.
    input  logic                        restart = 1'b0,
    output logic                        restart_error,

    // Weight load port (ADR-011 bank r = output channel tile_idx*ROWS + r,
    // bank-local address tile_idx*K + k).  Exposed on the boundary so the banks
    // survive out-of-context synthesis and so ADR-012 runtime loading has a
    // place to attach; Stage 1 drives it from the testbench.
    input  logic                        w_wr_en,
    input  logic [$clog2(ROWS)-1:0]     w_wr_bank,
    input  logic [$clog2(W_DEPTH)-1:0]  w_wr_addr,
    input  logic [DATA_WIDTH-1:0]       w_wr_data,

    // Layer command.  Stage 1 drives these from the testbench; ADR-015 maps
    // them onto axi_lite_regs later.
    input  logic                        frame_start,
    input  logic [ROW_W-1:0]            cfg_active_rows,
    input  logic [K_W-1:0]              cfg_k_len,
    input  logic [TILE_W-1:0]           cfg_tile_idx,

    // Layer geometry.  cfg_c_in is the LOGICAL channel count: it alone sets
    // the reduction length K = c_in*kh*kw, which is what the weight banks and
    // cfg_k_len are indexed by.  cfg_c_phys is the byte distance between
    // adjacent columns of the stored frame (ADR-018 Decision 2, padded
    // tile-major); conv1 input is 3/3, conv2 input 6/8.
    input  logic [$clog2(IN_H_MAX+1)-1:0] cfg_in_h,
    input  logic [$clog2(IN_W_MAX+1)-1:0] cfg_in_w,
    input  logic [8:0]                  cfg_c_in,     // logical channels
    input  logic [8:0]                  cfg_c_phys,   // physical channel stride in memory/stream
    input  logic [2:0]                  cfg_kh,
    input  logic [2:0]                  cfg_kw,
    input  logic [1:0]                  cfg_pad,
    input  logic [$clog2(W_DEPTH)-1:0]  cfg_w_base,   // weight bank base address

    // Per-output-channel requant configuration (ADR-014).  Lane r is output
    // channel cfg_tile_idx*ROWS + r, the same indexing the weight banks use.
    input  logic signed [ACC_WIDTH-1:0] cfg_bias_q  [0:ROWS-1],
    input  logic signed [M0_W-1:0]      cfg_m0      [0:ROWS-1],
    input  logic        [5:0]           cfg_shift_n [0:ROWS-1],
    input  logic                        cfg_relu    [0:ROWS-1],
    input  logic                        cfg_bypass,

    // Output activation stream: one output column per beat, lane r = channel r.
    output logic                        m_valid,
    input  logic                        m_ready,
    output logic [ROWS*8-1:0]           m_y_flat,
    output logic [ROWS-1:0]             m_lane_valid,
    output logic [COL_W-1:0]            m_col,
    output logic                        m_last,
    output logic [ROWS-1:0]             m_sat_flat,
    output logic [ROWS-1:0]             m_ovf_flat,

    // Status / error aggregation.
    output logic                        busy,
    output logic                        layer_done,
    output logic                        window_done,
    output logic [31:0]                 tile_count,
    output logic [7:0]                  error_flags,
    output logic                        lockstep_error,
    output logic                        drain_stall,
    output logic [31:0]                 engine_cycle_count
);
    // window_gen -> layer_ctrl
    logic        win_valid;
    logic        win_ready;
    logic [63:0] win_data;
    logic [3:0]  win_active_cols;
    logic [31:0] win_k;
    logic        win_tile_start;
    logic        win_tile_last;
    logic        win_done;
    logic        win_cfg_error;
    logic [K_W-1:0] win_k_len;

    // Geometry error -> error_flags[7]; see the header.
    logic [7:0]  ctrl_error_flags;
    logic        geom_bad;
    logic        geom_error;

    // layer_ctrl -> compute_engine
    logic             eng_start;
    logic             eng_start_ready;
    logic [ROW_W-1:0] eng_active_rows;
    logic [COL_W-1:0] eng_active_cols;
    logic [K_W-1:0]   eng_k_len;
    logic             eng_act_valid;
    logic             eng_act_ready;
    logic [63:0]      eng_act_data;
    logic             eng_done;
    logic             eng_config_error;

    // layer_ctrl -> weight_feeder
    logic             wf_start;
    logic             wf_ready;
    logic [TILE_W-1:0] wf_tile_idx;
    logic [K_W-1:0]   wf_k_len;
    logic             wf_done;
    logic             wf_cfg_error;

    // weight_feeder -> compute_engine
    logic                        w_valid;
    logic                        w_ready;
    logic [ROWS*DATA_WIDTH-1:0]  w_data;

    // compute_engine -> requant_array
    logic                        acc_valid;
    logic                        acc_ready;
    logic [ROWS*ACC_WIDTH-1:0]   acc_flat;
    logic [ROWS-1:0]             acc_lane_valid;
    logic [COL_W-1:0]            acc_col;
    logic                        acc_k_last;
    logic                        acc_last;

    logic [ROWS*COLS-1:0] mac_fire_flat_unused;

    assign window_done = win_done;

    window_gen #(
        .IN_H_MAX      (IN_H_MAX),
        .IN_W_MAX      (IN_W_MAX),
        .C_MAX         (C_MAX),
        .ROW_BYTES_MAX (ROW_BYTES_MAX),
        .K_H_MAX       (K_H_MAX),
        .K_W_MAX       (K_W_MAX),
        .PAD_MAX       (PAD_MAX),
        .K_MAX         (K_MAX),
        .DATA_WIDTH    (DATA_WIDTH)
    ) u_window (
        .clk           (clk),
        .rst_n         (rst_n),
        .cfg_in_h      (cfg_in_h),
        .cfg_in_w      (cfg_in_w),
        .cfg_c_in      (cfg_c_in),
        .cfg_c_phys    (cfg_c_phys),
        .cfg_kh        (cfg_kh),
        .cfg_kw        (cfg_kw),
        .cfg_pad       (cfg_pad),
        .cfg_error     (win_cfg_error),
        .k_len         (win_k_len),
        .restart       (restart),
        .restart_error (restart_error),
        .s_valid       (s_valid),
        .s_ready       (s_ready),
        .s_data        (s_data),
        .s_last        (s_last),
        .m_valid       (win_valid),
        .m_ready       (win_ready),
        .m_data        (win_data),
        .m_active_cols (win_active_cols),
        .m_k           (win_k),
        .m_tile_row    (),
        .m_tile_x      (),
        .m_tile_start  (win_tile_start),
        .m_tile_last   (win_tile_last),
        .done          (win_done)
    );

    layer_ctrl #(
        .ROWS     (ROWS),
        .COLS     (COLS),
        .K_MAX    (K_MAX),
        .TILE_MAX (TILE_MAX)
    ) u_ctrl (
        .clk                  (clk),
        .rst_n                (rst_n),
        .frame_start          (frame_start),
        .cfg_active_rows      (cfg_active_rows),
        .cfg_k_len            (cfg_k_len),
        .cfg_tile_idx         (cfg_tile_idx),
        .busy                 (busy),
        .layer_done           (layer_done),
        .w_valid              (win_valid),
        .w_ready              (win_ready),
        .w_data               (win_data),
        .w_active_cols        (win_active_cols),
        .w_k                  (win_k),
        .w_tile_start         (win_tile_start),
        .w_tile_last          (win_tile_last),
        .w_done               (win_done),
        .eng_start            (eng_start),
        .eng_start_ready      (eng_start_ready),
        .eng_active_rows      (eng_active_rows),
        .eng_active_cols      (eng_active_cols),
        .eng_k_len            (eng_k_len),
        .eng_activation_valid (eng_act_valid),
        .eng_activation_ready (eng_act_ready),
        .eng_activation_data  (eng_act_data),
        .eng_done             (eng_done),
        .eng_config_error     (eng_config_error),
        .wf_start             (wf_start),
        .wf_ready             (wf_ready),
        .wf_tile_idx          (wf_tile_idx),
        .wf_k_len             (wf_k_len),
        .wf_done              (wf_done),
        .wf_cfg_error         (wf_cfg_error),
        .tile_count           (tile_count),
        .error_flags          (ctrl_error_flags)
    );

    // cfg_k_len stays an input (the driver writes c_in*kh*kw); it must agree
    // with the generator's registered product, or the engine would reduce a
    // different number of beats than the generator emits per tile.
    assign geom_bad = win_cfg_error || (cfg_k_len != win_k_len);

    always_ff @(posedge clk) begin
        if (!rst_n)
            geom_error <= 1'b0;
        else if (frame_start)
            geom_error <= 1'b0;
        else if (busy && geom_bad)
            geom_error <= 1'b1;
    end

    assign error_flags = {ctrl_error_flags[7] | geom_error, ctrl_error_flags[6:0]};

    weight_feeder #(
        .ROWS       (ROWS),
        .DATA_WIDTH (DATA_WIDTH),
        .K_MAX      (K_MAX),
        .DEPTH      (W_DEPTH),
        .TILE_MAX   (TILE_MAX)
    ) u_weights (
        .clk          (clk),
        .rst_n        (rst_n),
        .wr_en        (w_wr_en),
        .wr_bank      (w_wr_bank),
        .wr_addr      (w_wr_addr),
        .wr_data      (w_wr_data),
        .start        (wf_start),
        .base         (cfg_w_base),
        .ready        (wf_ready),
        .tile_idx     (wf_tile_idx),
        .k_len        (wf_k_len),
        .weight_valid (w_valid),
        .weight_ready (w_ready),
        .weight_data  (w_data),
        .done         (wf_done),
        .cfg_error    (wf_cfg_error)
    );

    compute_engine #(
        .ROWS       (ROWS),
        .COLS       (COLS),
        .K_MAX      (K_MAX),
        .DATA_WIDTH (DATA_WIDTH),
        .ACC_WIDTH  (ACC_WIDTH)
    ) u_engine (
        .clk              (clk),
        .rst_n            (rst_n),
        .start            (eng_start),
        .start_ready      (eng_start_ready),
        .active_rows      (eng_active_rows),
        .active_cols      (eng_active_cols),
        .k_len            (eng_k_len),
        .weight_valid     (w_valid),
        .weight_ready     (w_ready),
        .weight_data      (w_data),
        .activation_valid (eng_act_valid),
        .activation_ready (eng_act_ready),
        .activation_data  (eng_act_data),
        .busy             (),
        .done             (eng_done),
        .config_error     (eng_config_error),
        .out_valid        (acc_valid),
        .out_ready        (acc_ready),
        .out_acc_flat     (acc_flat),
        .out_lane_valid   (acc_lane_valid),
        .out_col          (acc_col),
        .out_k_last       (acc_k_last),
        .out_last         (acc_last),
        .drain_stall      (drain_stall),
        .cycle_count      (engine_cycle_count),
        .mac_fire_flat    (mac_fire_flat_unused)
    );

    requant_array #(
        .LANES (ROWS),
        .ACC_W (ACC_WIDTH),
        .M0_W  (M0_W),
        .COL_W (COL_W)
    ) u_requant (
        .clk            (clk),
        .rst_n          (rst_n),
        .cfg_bias_q     (cfg_bias_q),
        .cfg_m0         (cfg_m0),
        .cfg_shift_n    (cfg_shift_n),
        .cfg_relu       (cfg_relu),
        .cfg_bypass     (cfg_bypass),
        .in_valid       (acc_valid),
        .in_ready       (acc_ready),
        .in_acc_flat    (acc_flat),
        .in_lane_valid  (acc_lane_valid),
        .in_col         (acc_col),
        .in_k_last      (acc_k_last),
        .in_last        (acc_last),
        .out_valid      (m_valid),
        .out_ready      (m_ready),
        .out_y_flat     (m_y_flat),
        .out_lane_valid (m_lane_valid),
        .out_col        (m_col),
        .out_last       (m_last),
        .out_sat_flat   (m_sat_flat),
        .out_ovf_flat   (m_ovf_flat),
        .lockstep_error (lockstep_error)
    );

`ifndef SYNTHESIS
    // The geometry the command ports describe must be the geometry the window
    // generator latched; a mismatch produces a correctly shaped tensor full of
    // wrong values, which is the failure class ADR-018 flags.  The hardware
    // flag is error_flags[7]; this is the simulation-side message.
    a_k_len_matches_geometry: assert property (
        @(posedge clk) disable iff (!rst_n)
        busy |-> (cfg_k_len == win_k_len)
    ) else $error("conv1_top: cfg_k_len %0d != latched c_in*kh*kw %0d",
                  cfg_k_len, win_k_len);

    a_active_rows_in_range: assert property (
        @(posedge clk) disable iff (!rst_n)
        frame_start |-> (cfg_active_rows != 0 && cfg_active_rows <= ROW_W'(ROWS))
    ) else $error("conv1_top: cfg_active_rows %0d out of range", cfg_active_rows);

    a_no_error_flags: assert property (
        @(posedge clk) disable iff (!rst_n)
        error_flags == 8'h00
    ) else $error("conv1_top: error_flags raised %02h", error_flags);

    a_no_lockstep_error: assert property (
        @(posedge clk) disable iff (!rst_n)
        !lockstep_error
    ) else $error("conv1_top: requant lockstep error");
`endif
endmodule
