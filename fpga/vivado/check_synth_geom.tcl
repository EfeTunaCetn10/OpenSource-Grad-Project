set script_dir [file dirname [file normalize [info script]]]
set design_dir [file normalize [file join $script_dir ..]]
set report_dir [file join $design_dir reports]
file mkdir $report_dir

# Runtime-geometry gate (faz3-param, lane G).  Same scope and flow as
# check_synth_conv1.tcl, but conv1_top is synthesized with its envelope
# defaults (48x48 frame, 512-byte rows, 5x5 kernel, pad <= 2): the geometry is
# now on cfg_* ports, so this is the one datapath every layer runs on.  The
# contract target is synthesis WNS >= +1.0 ns at 100 MHz; the Faz 2 conv1 path
# kept only 0.348 ns after routing.
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

report_utilization -hierarchical \
    -file [file join $report_dir geom_utilization_hier.rpt]
report_utilization -file [file join $report_dir geom_utilization.rpt]
report_timing_summary -delay_type max -max_paths 20 \
    -file [file join $report_dir geom_timing_summary.rpt]

# 64 DSP48 for the PE array plus 2 per requantizer lane = 80, as in the conv1
# gate.  The geometry latch has two small multiplies (in_w*c_phys and
# c_in*kh*kw); if they land in DSP48 the count says so.
set dsp_count [llength [get_cells -hierarchical -filter {REF_NAME =~ DSP48*}]]
puts "DSP_CHECK: found $dsp_count DSP48 cells; expected 80 (64 PE + 16 requant)"
set dsp_ok [expr {$dsp_count == 80}]
if {!$dsp_ok} {
    puts stderr "ERROR: expected 80 DSP48 cells, found $dsp_count"
}

set timing_paths [get_timing_paths -delay_type max -max_paths 1]
if {[llength $timing_paths] == 0} {
    puts stderr "ERROR: no max-delay timing path was produced"
    exit 3
}
set worst [lindex $timing_paths 0]
set wns [get_property SLACK $worst]
puts "WNS_CHECK: worst slack ${wns} ns; target >= 1.0 at 100 MHz"
puts "WORST_PATH: [get_property STARTPOINT_PIN $worst] -> [get_property ENDPOINT_PIN $worst], levels [get_property LOGIC_LEVELS $worst]"
# The geometry change lives in u_window (window_gen + line_buffer); report its
# own worst endpoint separately so a path elsewhere cannot hide it.
set win_paths [get_timing_paths -quiet -delay_type max -max_paths 1 \
    -to [get_cells -quiet -hierarchical -filter {NAME =~ u_window/*}]]
if {[llength $win_paths] > 0} {
    set wp [lindex $win_paths 0]
    puts "WINDOW_WNS: [get_property SLACK $wp] ns, [get_property STARTPOINT_PIN $wp] -> [get_property ENDPOINT_PIN $wp], levels [get_property LOGIC_LEVELS $wp]"
}
set wns_ok [expr {$wns >= 1.0}]
if {!$wns_ok} {
    puts stderr "ERROR: worst slack ${wns} ns is below the +1.0 ns target"
}

set ramb36  [llength [get_cells -hierarchical -filter {REF_NAME =~ RAMB36*}]]
set ramb18  [llength [get_cells -hierarchical -filter {REF_NAME =~ RAMB18*}]]
set lutram  [llength [get_cells -hierarchical -filter {REF_NAME =~ RAM??M* || REF_NAME =~ RAM??X*}]]
set ff      [llength [get_cells -hierarchical -filter {REF_NAME =~ FD*}]]
set lut     [llength [get_cells -hierarchical -filter {REF_NAME =~ LUT*}]]
puts "MEM_REPORT: RAMB36 = $ramb36, RAMB18 = $ramb18, LUTRAM = $lutram, FF = $ff, LUT cells = $lut"

# The weight banks must still be block RAM (see check_synth_conv1.tcl).
set weight_cells [get_cells -quiet -hierarchical u_weights]
set weights_ok [expr {([llength $weight_cells] > 0) && (($ramb36 + $ramb18) >= 8)}]
if {!$weights_ok} {
    puts stderr "ERROR: the weight banks were not realized as block RAM (RAMB36 = $ramb36, RAMB18 = $ramb18)"
}

if {$dsp_ok && $wns_ok && $weights_ok} {
    puts "PASS: conv1_top (runtime geometry, envelope defaults) synthesized, $dsp_count DSP48, WNS ${wns} ns"
    exit 0
}
puts stderr "GATE FAILED: see the ERROR lines above (WNS ${wns} ns, DSP $dsp_count)"
exit 2
