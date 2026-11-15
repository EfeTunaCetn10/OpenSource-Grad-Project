set script_dir [file dirname [file normalize [info script]]]
set design_dir [file normalize [file join $script_dir ..]]
set report_dir [file join $design_dir reports]
file mkdir $report_dir

foreach f {
    pe_os.sv systolic_array_os.sv compute_engine.sv
    window_gen.sv line_buffer.sv requant_unit.sv requant_array.sv
    weight_feeder.sv layer_ctrl.sv conv1_top.sv
    pool2x2.sv act_buffer.sv axi_lite_regs.sv accel_top.sv accel_axis.sv
} {
    read_verilog -sv [file join $design_dir rtl $f]
}
read_verilog [file join $design_dir rtl accel_axis_wrapper.v]
set axis_xdc [file join $report_dir .axis_constraints.xdc]
set axis_xdc_fh [open $axis_xdc w]
puts $axis_xdc_fh {create_clock -name aclk -period 10.000 [get_ports aclk]}
close $axis_xdc_fh
read_xdc $axis_xdc
synth_design -mode out_of_context -flatten_hierarchy rebuilt \
    -top accel_axis_wrapper -part xc7z020clg400-1
file delete $axis_xdc
report_utilization -file [file join $report_dir axis_utilization.rpt]
report_timing_summary -delay_type max -max_paths 20 \
    -file [file join $report_dir axis_timing_summary.rpt]
set paths [get_timing_paths -delay_type max -max_paths 1]
if {[llength $paths] == 0} {
    puts stderr "ERROR: no timing path"
    exit 3
}
set wns [get_property SLACK [lindex $paths 0]]
set lut [llength [get_cells -hierarchical -filter {REF_NAME =~ LUT*}]]
set ff [llength [get_cells -hierarchical -filter {REF_NAME =~ FD*}]]
set bram [llength [get_cells -hierarchical -filter {REF_NAME =~ RAMB*}]]
set dsp [llength [get_cells -hierarchical -filter {REF_NAME =~ DSP48*}]]
puts "AXIS_SYNTH: WNS=$wns ns LUT=$lut FF=$ff BRAM=$bram DSP=$dsp"
if {$wns < 1.0} {
    puts stderr "ERROR: synthesis margin below +1.0 ns"
    exit 2
}
puts "PASS: accel_axis_wrapper synthesis margin"
