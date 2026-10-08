set script_dir [file dirname [file normalize [info script]]]
set design_dir [file normalize [file join $script_dir ..]]
set report_dir [file join $design_dir reports]
file mkdir $report_dir

read_verilog -sv [file join $design_dir rtl pe_os.sv]
read_verilog -sv [file join $design_dir rtl systolic_array_os.sv]
read_verilog -sv [file join $design_dir rtl compute_engine.sv]
read_verilog -sv [file join $design_dir rtl systolic_array_8x8.sv]

# The 100 MHz constraint must be in force *during* synthesis so the optimizer
# and DSP inference see the real requirement. It is read from an XDC rather
# than called inline: create_clock before synth_design fails ("No open
# design" -- get_ports has no elaborated netlist to query), and after
# synth_design it is too late to constrain synthesis at all. Only read_xdc
# gets both the parse order and the timing semantics right.
read_xdc [file join $script_dir constraints.xdc]

synth_design -mode out_of_context -flatten_hierarchy rebuilt \
    -top systolic_array_8x8 -part xc7z020clg400-1

report_utilization -hierarchical -file [file join $report_dir utilization_hier.rpt]
report_timing_summary -delay_type max -max_paths 20 \
    -file [file join $report_dir timing_summary.rpt]
report_methodology -file [file join $report_dir methodology.rpt]

set dsp_cells [get_cells -hierarchical -filter {REF_NAME =~ DSP48*}]
set dsp_count [llength $dsp_cells]
puts "DSP_CHECK: found $dsp_count DSP48 cells; expected 64"
if {$dsp_count != 64} {
    puts stderr "ERROR: PE-to-DSP mapping is not one DSP48 per PE"
    exit 2
}

set timing_paths [get_timing_paths -delay_type max -max_paths 1]
if {[llength $timing_paths] == 0} {
    puts stderr "ERROR: no max-delay timing path was produced"
    exit 3
}
set wns [get_property SLACK [lindex $timing_paths 0]]
puts "WNS_CHECK: worst slack ${wns} ns; expected >= 0 at 100 MHz"
if {$wns < 0.0} {
    puts stderr "ERROR: worst negative slack is ${wns} ns"
    exit 4
}

puts "PASS: synthesis completed and all 64 PEs mapped to DSP48 cells"
exit 0
