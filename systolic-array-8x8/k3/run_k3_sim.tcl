# Project-mode XSim launch used by run_k3.py after build_bd.tcl has generated
# the BD simulation products.
if {[llength $argv] != 2} {
    puts stderr "ERROR: run_k3_sim.tcl requires <program-base> <testbench-path>"
    exit 2
}
set program_base [file normalize [lindex $argv 0]]
set tb_path [file normalize [lindex $argv 1]]
set script_dir [file dirname [file normalize [info script]]]
set design_dir [file normalize [file join $script_dir ..]]
set xpr [file join $design_dir vivado build bd accel_bd_project.xpr]
if {![file exists $xpr]} {
    puts stderr "ERROR: generated BD project not found: $xpr"
    exit 3
}
open_project $xpr
add_files -fileset sim_1 -norecurse $tb_path
set_property file_type SystemVerilog [get_files -of_objects [get_filesets sim_1] $tb_path]
set_property top tb_k3_prog [get_filesets sim_1]
set_property xsim.simulate.runtime all [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation -simset sim_1 -mode behavioral -scripts_only
close_project
exit 0
