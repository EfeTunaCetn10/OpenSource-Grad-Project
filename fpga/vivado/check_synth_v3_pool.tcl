# Representative largest v3 pooling geometry: C16,H32,W32, 100 MHz OOC.
set script_dir [file dirname [file normalize [info script]]]
set design_dir [file normalize [file join $script_dir ..]]
if {$argc != 1} {error "Supply a new report directory"}
set report_dir [file normalize [lindex $argv 0]]
if {[file exists $report_dir]} {error "Refusing to overwrite $report_dir"}
file mkdir $report_dir
read_verilog -sv [file join $design_dir rtl maxpool2d_int8.sv]
read_xdc [file join $script_dir constraints.xdc]
synth_design -mode out_of_context -flatten_hierarchy rebuilt -top maxpool2d_int8 \
    -part xc7z020clg400-1 -generic {CHANNELS=16 HEIGHT=32 WIDTH=32}
report_utilization -file [file join $report_dir utilization.rpt]
report_timing_summary -delay_type max -max_paths 20 -file [file join $report_dir timing.rpt]
report_methodology -file [file join $report_dir methodology.rpt]
set paths [get_timing_paths -delay_type max -max_paths 1]
if {[llength $paths] == 0} {error "No constrained timing path"}
set wns [get_property SLACK [lindex $paths 0]]
set f [open [file join $report_dir summary.txt] w]
puts $f "maxpool2d_int8 C16 H32 W32 OOC post-synthesis, not routed"
puts $f "part=xc7z020clg400-1 target_clock_MHz=100 WNS_ns=$wns"
foreach {label pattern} {LUT_PRIMITIVE_CELLS LUT* FF FD* DSP DSP48* RAMB36 RAMB36* RAMB18 RAMB18*} {
    set count [llength [get_cells -quiet -hierarchical -filter "REF_NAME =~ $pattern"]]
    puts $f "$label=$count"
}
close $f
puts "SYNTHESIS_COMPLETE: MaxPool C16 H32 W32, WNS=$wns ns at 100 MHz"
exit 0
