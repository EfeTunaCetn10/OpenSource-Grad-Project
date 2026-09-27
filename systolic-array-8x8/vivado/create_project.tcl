# Creates (or reopens) the Vivado GUI project for the 8x8 array.
#
# The project itself is never committed -- ADR-001 stores it as Tcl only, so
# this script is the source of truth and `vivado/.project/` is gitignored.
# Run it from the design root:
#
#   vivado -source vivado/create_project.tcl                 # GUI
#   vivado -mode batch -source vivado/create_project.tcl     # regenerate only
#
# Part and clock come from ADR-001 / ADR-008. Synthesis acceptance checks
# (64 DSP48, WNS >= 0) stay in check_synth.tcl -- that one is the gate, this
# one is the workbench.

set script_dir [file dirname [file normalize [info script]]]
set design_dir [file normalize [file join $script_dir ..]]
set proj_dir   [file join $script_dir .project]
set proj_name  systolic_array_8x8
set part       xc7z020clg400-1

# Vivado mangles non-ASCII path characters into '?' and then reports sources as
# missing. Fail here instead of chasing a phantom file later.
if {![string is ascii $design_dir]} {
    puts stderr "ERROR: design path is not ASCII, Vivado cannot read it: $design_dir"
    exit 1
}

set xpr [file join $proj_dir $proj_name.xpr]
if {[file exists $xpr]} {
    puts "Reopening existing project: $xpr"
    open_project $xpr
    return
}

file mkdir $proj_dir
create_project $proj_name $proj_dir -part $part -force

# --- synthesis sources ------------------------------------------------------
# Every rtl/*.sv is added, including the blocks not yet wired into the top
# (window_gen, line_buffer, requant_unit, axi_lite_regs). They elaborate as
# out-of-context tops, which is exactly how you want to check their timing
# before integration.
add_files -fileset sources_1 [glob [file join $design_dir rtl *.sv]]
set_property file_type SystemVerilog [get_files -of_objects [get_filesets sources_1] *.sv]
set_property top systolic_array_8x8 [get_filesets sources_1]

add_files -fileset constrs_1 [file join $design_dir vivado constraints.xdc]

# --- simulation sources -----------------------------------------------------
add_files -fileset sim_1 [glob [file join $design_dir tb *.sv]]
set_property file_type SystemVerilog [get_files -of_objects [get_filesets sim_1] *.sv]
set_property top tb_compute_engine [get_filesets sim_1]

# tb_requant_unit_num reads "../vectors/req_*.mem" relative to the simulator's
# working directory. The batch runner sits in sim/build so that path resolves;
# in a project the xsim cwd is <proj>.sim/sim_1/behav/xsim, which does not.
# A junction one level up makes both layouts agree. Best effort: mklink /J
# needs no privileges, but skip quietly if it is unavailable.
set sim_behav [file join $proj_dir $proj_name.sim sim_1 behav]
set vec_link  [file join $sim_behav vectors]
set vec_src   [file join $design_dir sim vectors]
if {[file isdirectory $vec_src]} {
    file mkdir $sim_behav
    if {![file exists $vec_link]} {
        if {[catch {exec cmd /c mklink /J [file nativename $vec_link] \
                                          [file nativename $vec_src]} err]} {
            puts "NOTE: could not link test vectors into the sim dir ($err)."
            puts "NOTE: run tb_requant_unit_num with 'python sim/run_tests.py' instead."
        }
    }
}

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "Project created: $xpr"
puts "  synth top : systolic_array_8x8  (compute_engine -> systolic_array_os -> pe_os)"
puts "  sim top   : tb_compute_engine   (change in Sources > Simulation Sources)"
puts "  not yet in the top: window_gen, line_buffer, requant_unit, axi_lite_regs"
