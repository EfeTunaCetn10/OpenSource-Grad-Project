set script_dir [file dirname [file normalize [info script]]]
set design_dir [file normalize [file join $script_dir ..]]
set report_dir [file join $design_dir reports]
file mkdir $report_dir

read_verilog -sv [file join $design_dir rtl pe_os.sv]
read_verilog -sv [file join $design_dir rtl systolic_array_os.sv]
read_verilog -sv [file join $design_dir rtl systolic_tile_engine.sv]
read_verilog -sv [file join $design_dir rtl systolic_array_8x8.sv]

synth_design -mode out_of_context -flatten_hierarchy rebuilt \
    -top systolic_array_8x8 -part xc7z020clg400-1
create_clock -name clk -period 10.000 [get_ports clk]

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

puts "PASS: synthesis completed and all 64 PEs mapped to DSP48 cells"
exit 0
