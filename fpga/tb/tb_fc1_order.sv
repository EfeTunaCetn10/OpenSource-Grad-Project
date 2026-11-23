`timescale 1ns/1ps

module tb_fc1_order;
    prog_replay_env #(.PRIMARY("diag_fc1_order"),
                      .PASS_TAG("T_FC1_ORDER_001"),
                      .PASS_DETAIL(" k=(0,24,47,57) for HWC points")) env();
endmodule
