`timescale 1ns/1ps

// Signed, output-stationary processing element.
// A moves right, B moves down, and the partial sum remains local.
module pe_os #(
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH  = 32
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         step,
    input  logic                         clear_acc,
    input  logic                         pipe_flush,
    input  logic signed [DATA_WIDTH-1:0] a_in,
    input  logic signed [DATA_WIDTH-1:0] b_in,
    input  logic                         a_valid_in,
    input  logic                         b_valid_in,
    output logic signed [DATA_WIDTH-1:0] a_out,
    output logic signed [DATA_WIDTH-1:0] b_out,
    output logic                         a_valid_out,
    output logic                         b_valid_out,
    output logic signed [ACC_WIDTH-1:0]  acc_out,
    output logic                         mac_fire
);
    localparam int PROD_WIDTH = 2 * DATA_WIDTH;

    logic signed [PROD_WIDTH-1:0] product;
    logic signed [ACC_WIDTH-1:0]  product_ext;

    // Vivado should map each PE MAC to one DSP48E1. Post-synthesis checking is
    // still mandatory; the attribute is an implementation request, not proof.
    (* use_dsp = "yes" *) logic signed [ACC_WIDTH-1:0] acc_reg;

    initial begin
        if (DATA_WIDTH < 1)
            $error("DATA_WIDTH must be positive");
        if (ACC_WIDTH < PROD_WIDTH)
            $error("ACC_WIDTH must be at least 2*DATA_WIDTH");
    end

    always_comb begin
        product     = a_in * b_in;
        product_ext = $signed({{(ACC_WIDTH-PROD_WIDTH){product[PROD_WIDTH-1]}}, product});
        mac_fire    = step && a_valid_in && b_valid_in &&
                      !clear_acc && !pipe_flush;
    end

    // Synchronous active-low reset is deliberate: it is friendly to DSP48
    // inference and is driven by a reset synchronizer in the SoC wrapper.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            a_out       <= '0;
            b_out       <= '0;
            a_valid_out <= 1'b0;
            b_valid_out <= 1'b0;
            acc_reg     <= '0;
        end else begin
            if (pipe_flush) begin
                a_out       <= '0;
                b_out       <= '0;
                a_valid_out <= 1'b0;
                b_valid_out <= 1'b0;
            end else if (step) begin
                a_out       <= a_in;
                b_out       <= b_in;
                a_valid_out <= a_valid_in;
                b_valid_out <= b_valid_in;
            end

            if (clear_acc)
                acc_reg <= '0;
            // Fixed-width addition wraps modulo 2**ACC_WIDTH. Saturation is
            // applied only after requantization, never in the MAC reduction.
            else if (mac_fire)
                acc_reg <= acc_reg + product_ext;
        end
    end

    assign acc_out = acc_reg;

endmodule
