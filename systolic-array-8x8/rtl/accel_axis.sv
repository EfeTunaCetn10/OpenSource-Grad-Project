`timescale 1ns/1ps

module accel_axis (
    input  logic         aclk,
    input  logic         aresetn,

    input  logic [11:0]  s_axi_awaddr,
    input  logic [2:0]   s_axi_awprot,
    input  logic         s_axi_awvalid,
    output logic         s_axi_awready,
    input  logic [31:0]  s_axi_wdata,
    input  logic [3:0]   s_axi_wstrb,
    input  logic         s_axi_wvalid,
    output logic         s_axi_wready,
    output logic [1:0]   s_axi_bresp,
    output logic         s_axi_bvalid,
    input  logic         s_axi_bready,
    input  logic [11:0]  s_axi_araddr,
    input  logic [2:0]   s_axi_arprot,
    input  logic         s_axi_arvalid,
    output logic         s_axi_arready,
    output logic [31:0]  s_axi_rdata,
    output logic [1:0]   s_axi_rresp,
    output logic         s_axi_rvalid,
    input  logic         s_axi_rready,

    input  logic [63:0]  s_axis_tdata,
    input  logic [7:0]   s_axis_tkeep,
    input  logic         s_axis_tlast,
    input  logic         s_axis_tvalid,
    output logic         s_axis_tready,

    output logic [63:0]  m_axis_tdata,
    output logic [7:0]   m_axis_tkeep,
    output logic         m_axis_tlast,
    output logic         m_axis_tvalid,
    input  logic         m_axis_tready,

    output logic         irq
);
    logic [7:0] lane_valid;
    logic [3:0] column;
    logic [7:0] saturated, overflow;
    logic soft_reset;

    logic unused;
    assign unused = ^{s_axi_awprot, s_axi_arprot, s_axis_tkeep,
                      lane_valid, column, saturated, overflow, soft_reset};
    assign m_axis_tkeep = 8'hFF;

    accel_top u_accel_top (
        .clk(aclk), .rst_n(aresetn),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready), .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready), .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready), .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),
        .s_valid(s_axis_tvalid), .s_ready(s_axis_tready),
        .s_data(s_axis_tdata), .s_last(s_axis_tlast),
        .w_wr_en(1'b0), .w_wr_bank(3'b000), .w_wr_addr(13'h0000),
        .w_wr_data(8'h00),
        .m_valid(m_axis_tvalid), .m_ready(m_axis_tready),
        .m_y_flat(m_axis_tdata), .m_lane_valid(lane_valid), .m_col(column),
        .m_last(m_axis_tlast), .m_sat_flat(saturated), .m_ovf_flat(overflow),
        .soft_reset(soft_reset), .irq(irq)
    );
endmodule
