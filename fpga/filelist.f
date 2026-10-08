# Compute-core synthesis scope (vivado/check_synth.tcl, top systolic_array_8x8).
rtl/pe_os.sv
rtl/systolic_array_os.sv
rtl/compute_engine.sv
rtl/systolic_array_8x8.sv

# Conv1 integration scope (vivado/check_synth_conv1.tcl, top conv1_top).
rtl/line_buffer.sv
rtl/window_gen.sv
rtl/requant_unit.sv
rtl/requant_array.sv
rtl/weight_feeder.sv
rtl/layer_ctrl.sv
rtl/conv1_top.sv
rtl/act_buffer.sv

# AXI4-Lite control wrapper (vivado/check_synth_accel.tcl).
rtl/axi_lite_regs.sv
rtl/accel_top.sv
