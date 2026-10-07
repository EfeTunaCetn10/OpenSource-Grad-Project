set script_dir [file dirname [file normalize [info script]]]
set design_dir [file normalize [file join $script_dir ..]]
set report_dir [file join $design_dir reports]
file mkdir $report_dir

# Full out-of-context implementation of the conv1 datapath: synthesis, then
# opt/place/route, then post-route timing.  check_synth_conv1.tcl is the fast
# gate and reports an estimated WNS on an unplaced netlist; this script is the
# one that answers "does conv1_top actually close 100 MHz on this part".  It is
# slower, so it is a separate script rather than more work in the gate.
foreach f {
    pe_os.sv
    systolic_array_os.sv
    compute_engine.sv
    window_gen.sv
    line_buffer.sv
    requant_unit.sv
    requant_array.sv
    weight_feeder.sv
    layer_ctrl.sv
    conv1_top.sv
} {
    read_verilog -sv [file join $design_dir rtl $f]
}

read_xdc [file join $script_dir constraints.xdc]

synth_design -mode out_of_context -flatten_hierarchy rebuilt \
    -top conv1_top -part xc7z020clg400-1

opt_design
place_design
phys_opt_design
route_design

report_utilization -hierarchical \
    -file [file join $report_dir conv1_impl_utilization.rpt]
report_timing_summary -delay_type min_max -max_paths 20 \
    -file [file join $report_dir conv1_impl_timing.rpt]
report_drc -file [file join $report_dir conv1_impl_drc.rpt]

# Post-route numbers.  Setup and hold are both checked: an out-of-context run
# with no placement constraints can produce hold violations that the estimated
# synthesis report never shows.
set setup_paths [get_timing_paths -delay_type max -max_paths 1]
set hold_paths  [get_timing_paths -delay_type min -max_paths 1]
if {[llength $setup_paths] == 0 || [llength $hold_paths] == 0} {
    puts stderr "ERROR: post-route timing produced no paths"
    exit 3
}
set wns [get_property SLACK [lindex $setup_paths 0]]
set whs [get_property SLACK [lindex $hold_paths 0]]
puts "IMPL_WNS: post-route worst setup slack ${wns} ns at 100 MHz"
puts "IMPL_WHS: post-route worst hold slack ${whs} ns"

set dsp_count [llength [get_cells -hierarchical -filter {REF_NAME =~ DSP48*}]]
set ramb36    [llength [get_cells -hierarchical -filter {REF_NAME =~ RAMB36*}]]
set ramb18    [llength [get_cells -hierarchical -filter {REF_NAME =~ RAMB18*}]]
puts "IMPL_RESOURCES: DSP48 = $dsp_count, RAMB36 = $ramb36, RAMB18 = $ramb18"

set ok 1
if {$wns < 0.0} {
    puts stderr "ERROR: post-route setup WNS is ${wns} ns"
    set ok 0
}
if {$whs < 0.0} {
    puts stderr "ERROR: post-route hold WHS is ${whs} ns"
    set ok 0
}
if {$dsp_count != 80} {
    puts stderr "ERROR: expected 80 DSP48 cells after implementation, found $dsp_count"
    set ok 0
}

if {$ok} {
    puts "PASS: conv1_top routes and closes 100 MHz (WNS ${wns} ns, WHS ${whs} ns)"
    exit 0
}
puts stderr "IMPL GATE FAILED: see the ERROR lines above"
exit 2
