set script_dir [file dirname [file normalize [info script]]]
set design_dir [file normalize [file join $script_dir ..]]
set report_dir [file join $design_dir reports]
file mkdir $report_dir

# The conv1 integration gate.  check_synth.tcl stays the compute-core gate (its
# 64-DSP48 claim is about the PE array alone); this script is the first one that
# takes the whole conv1 datapath through synthesis and timing, which is what
# ADR-018's "no integration top has ever been synthesized" item asked for.
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

# The clock must constrain synthesis itself, not just the post-synthesis
# report -- see the comment in check_synth.tcl for why read_xdc is the only
# ordering that works.
read_xdc [file join $script_dir constraints.xdc]

synth_design -mode out_of_context -flatten_hierarchy rebuilt \
    -top conv1_top -part xc7z020clg400-1

report_utilization -hierarchical \
    -file [file join $report_dir conv1_utilization_hier.rpt]
report_timing_summary -delay_type max -max_paths 20 \
    -file [file join $report_dir conv1_timing_summary.rpt]
report_methodology -file [file join $report_dir conv1_methodology.rpt]

# 64 DSP48 for the PE array plus 2 per requantizer lane = 80.  A count below
# that means a multiplier fell back to LUT logic, which would pass a functional
# test and silently cost both timing and area.
set dsp_count [llength [get_cells -hierarchical -filter {REF_NAME =~ DSP48*}]]
puts "DSP_CHECK: found $dsp_count DSP48 cells; expected 80 (64 PE + 16 requant)"
set dsp_ok [expr {$dsp_count == 80}]
if {!$dsp_ok} {
    puts stderr "ERROR: expected 80 DSP48 cells, found $dsp_count"
}

# Timing is reported and gated BEFORE the memory checks: a memory finding must
# not hide the integration WNS, which is the number this gate exists to produce.
set timing_paths [get_timing_paths -delay_type max -max_paths 1]
if {[llength $timing_paths] == 0} {
    puts stderr "ERROR: no max-delay timing path was produced"
    exit 3
}
set wns [get_property SLACK [lindex $timing_paths 0]]
puts "WNS_CHECK: worst slack ${wns} ns; expected >= 0 at 100 MHz"
set wns_ok [expr {$wns >= 0.0}]
if {!$wns_ok} {
    puts stderr "ERROR: worst negative slack is ${wns} ns"
}

# Memory realization, reported as measurement.  ram_style = "block" is a hint,
# not a guarantee: a memory that is read combinationally becomes flip-flops and
# a memory with neither an initialization nor a write port is removed outright.
# Both of those happen in this design today, so these numbers are the evidence
# rather than a pass/fail line.
set ramb36  [llength [get_cells -hierarchical -filter {REF_NAME =~ RAMB36*}]]
set ramb18  [llength [get_cells -hierarchical -filter {REF_NAME =~ RAMB18*}]]
set lutram  [llength [get_cells -hierarchical -filter {REF_NAME =~ RAM??M* || REF_NAME =~ RAM??X*}]]
set ff      [llength [get_cells -hierarchical -filter {REF_NAME =~ FD*}]]
puts "MEM_REPORT: RAMB36 = $ramb36, RAMB18 = $ramb18, LUTRAM = $lutram, FF = $ff"

# The weight banks must be realized as memory, not optimized into constants.
# Checking that the u_weights INSTANCE exists is not enough -- the hierarchical
# cell survives as an empty shell even when everything inside it is removed, as
# measured on 2026-10-07.  Eight banks of 8192 x 8 bit is 2 RAMB36 each, so a
# correct realization is at least 8 block RAM primitives.  ADR-011 loads these
# from eight .coe files through the Block Memory Generator; the RTL equivalent
# is the wr_* load port on conv1_top's boundary.
set weight_cells [get_cells -quiet -hierarchical u_weights]
puts "WEIGHT_PATH_CHECK: weight_feeder instances = [llength $weight_cells], block RAM primitives = [expr {$ramb36 + $ramb18}]"
set weights_ok [expr {([llength $weight_cells] > 0) && (($ramb36 + $ramb18) >= 8)}]
if {!$weights_ok} {
    puts stderr "ERROR: the weight banks were not realized as block RAM (RAMB36 = $ramb36, RAMB18 = $ramb18)"
}

if {$dsp_ok && $wns_ok && $weights_ok} {
    puts "PASS: conv1_top synthesized, 80 DSP48, weight path present, WNS ${wns} ns"
    exit 0
}
puts stderr "GATE FAILED: see the ERROR lines above"
exit 2
