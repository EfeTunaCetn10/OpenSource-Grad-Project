`timescale 1ns/1ps

module tb_axis_lane;
    prog_replay_env #(.PRIMARY("diag_axis_lane"),
                      .PASS_TAG("T_AXI_LANE_001"),
                      .PASS_DETAIL(" coordinates=2x4x8")) env();
endmodule
