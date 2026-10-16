# Isolated v3 Conv1 datapath OOC synthesis; TB owns the two channel passes.
# Usage: vivado -mode batch -source check_synth_v3_conv1.tcl -tclargs NEW_REPORT_DIR
set script_dir [file dirname [file normalize [info script]]]
set design_dir [file normalize [file join $script_dir ..]]
if {$argc != 1} {error "Supply a new report directory"}
set report_dir [file normalize [lindex $argv 0]]
if {[file exists $report_dir]} {error "Refusing to overwrite $report_dir"}
file mkdir $report_dir
foreach f {pe_os.sv systolic_array_os.sv compute_engine.sv window_gen.sv
           line_buffer.sv requant_unit.sv requant_array.sv weight_feeder.sv
           layer_ctrl.sv conv1_top.sv} {
    read_verilog -sv [file join $design_dir rtl $f]
}
read_xdc [file join $script_dir constraints.xdc]
synth_design -mode out_of_context -flatten_hierarchy rebuilt \
    -top conv1_top -part xc7z020clg400-1 \
    -generic {KERN_H=3 KERN_W=3 C_IN=3 C_PHYS_STRIDE=3 IN_H=32 IN_W=32 STRIDE=1 PAD=1}
report_utilization -hierarchical -file [file join $report_dir utilization.rpt]
report_timing_summary -delay_type max -max_paths 20 -file [file join $report_dir timing.rpt]
report_methodology -file [file join $report_dir methodology.rpt]
set paths [get_timing_paths -delay_type max -max_paths 1]
if {[llength $paths] == 0} {error "No constrained timing path"}
set wns [get_property SLACK [lindex $paths 0]]
set summary [open [file join $report_dir summary.txt] w]
puts $summary "v3 Conv1 OOC synthesis only; not implementation or board timing"
puts $summary "part=xc7z020clg400-1 target_clock_MHz=100 WNS_ns=$wns"
foreach {label pattern} {LUT_PRIMITIVE_CELLS LUT* FF FD* DSP DSP48* RAMB36 RAMB36* RAMB18 RAMB18*} {
    set count [llength [get_cells -hierarchical -filter "REF_NAME =~ $pattern"]]
    puts $summary "$label=$count"
}
close $summary
puts "SYNTHESIS_COMPLETE: v3 Conv1 OOC, WNS=$wns ns at 100 MHz (see reports)"
exit 0
