`timescale 1ns/1ps
// Isolated Conv2 POC: tile-major ingress -> local repack -> unchanged conv1_top.
// Only the testbench sequences output-channel tiles and replays each input.
module v3_conv2_poc_top #(
    parameter int ROWS       = 8,
    parameter int COLS       = 8,
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH  = 32,
    parameter int M0_W       = 18,

    // Fixed POC geometry; parameters retained only for interface widths.
    parameter int KERN_H     = 3,
    parameter int KERN_W     = 3,
    parameter int C_IN         = 16,
    parameter int C_PHYS_STRIDE = C_IN,
    parameter int IN_H       = 16,
    parameter int IN_W       = 16,
    parameter int STRIDE     = 1,
    parameter int PAD        = 1,

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

    // Input frame: 512 tile-major beats; c_tile then h then w, eight lanes.
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
    logic dense_valid, dense_ready, dense_last, repack_error, core_restart_error;
    logic [63:0] dense_data;
    assign restart_error = repack_error | core_restart_error;
    v3_conv2_repack u_repack(
        .clk(clk),.rst_n(rst_n),.restart(restart),
        .s_valid(s_valid),.s_ready(s_ready),.s_data(s_data),.s_last(s_last),
        .m_valid(dense_valid),.m_ready(dense_ready),.m_data(dense_data),.m_last(dense_last),
        .done(),.error(repack_error));
    conv1_top #(.KERN_H(3),.KERN_W(3),.C_IN(16),.C_PHYS_STRIDE(16),
                .IN_H(16),.IN_W(16),.PAD(1)) u_core(
        .s_valid(dense_valid),.s_ready(dense_ready),.s_data(dense_data),.s_last(dense_last),
        .restart_error(core_restart_error), .*);
`ifndef SYNTHESIS
    initial if(ROWS!=8 || COLS!=8 || DATA_WIDTH!=8 || ACC_WIDTH!=32 || M0_W!=18 ||
               KERN_H!=3 || KERN_W!=3 || C_IN!=16 || C_PHYS_STRIDE!=16 ||
               IN_H!=16 || IN_W!=16 || PAD!=1 || STRIDE!=1 ||
               K_MAX!=1024 || TILE_MAX!=16 || W_DEPTH!=8192)
        $fatal(1,"v3_conv2_poc_top supports only its fixed Conv2 geometry");
`endif
endmodule
