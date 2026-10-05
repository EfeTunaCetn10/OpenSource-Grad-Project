# Creates or refreshes the Vivado GUI project for the 8x8 array.
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
#
# Reopening reconciles sources instead of returning early. The earlier version
# opened an existing .xpr and stopped before add_files, so every file written
# after the project was first created stayed invisible to the GUI while the
# batch runner (which globs rtl/ and tb/ fresh each time) saw it and passed.
# Observed 2026-10-05: requant_array.sv and tb_requant_array.sv were missing
# from a project generated on 2026-09-27, with nothing to signal it. Source
# discovery is therefore run on both paths, which also makes the script
# idempotent -- running it twice is a no-op.
#
# Only file membership is reconciled. The two `top` properties are set on
# creation and never rewritten, because changing the simulation top in
# Sources > Simulation Sources is the intended way to pick a testbench and a
# refresh must not undo it.

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

# Adds whatever matches $pattern under $dir and is not already a member of
# $fileset. Comparison is on normalized paths: Vivado reports file names with
# forward slashes regardless of platform, so a raw string compare would treat
# every file as new and re-add it.
proc sync_fileset {fileset dir pattern} {
    set existing {}
    foreach f [get_files -quiet -of_objects [get_filesets $fileset]] {
        lappend existing [file normalize $f]
    }

    set added {}
    foreach f [lsort [glob -nocomplain [file join $dir $pattern]]] {
        if {[lsearch -exact $existing [file normalize $f]] < 0} {
            add_files -fileset $fileset $f
            lappend added [file tail $f]
        }
    }

    if {[llength $added] > 0} {
        set sv [get_files -quiet -of_objects [get_filesets $fileset] *.sv]
        if {[llength $sv] > 0} {
            set_property file_type SystemVerilog $sv
        }
        puts "  $fileset += [join $added {, }]"
    } else {
        puts "  $fileset up to date"
    }
    return $added
}

# tb_requant_unit_num reads "../vectors/req_*.mem" relative to the simulator's
# working directory. The batch runner sits in sim/build so that path resolves;
# in a project the xsim cwd is <proj>.sim/sim_1/behav/xsim, which does not.
# A junction one level up makes both layouts agree. Best effort: mklink /J
# needs no privileges, but skip quietly if it is unavailable.
#
# This runs on a refresh too: the link lives under the generated .sim tree, so
# cleaning simulation output removes it and only re-running would restore it.
proc link_vectors {proj_dir proj_name design_dir} {
    set sim_behav [file join $proj_dir $proj_name.sim sim_1 behav]
    set vec_link  [file join $sim_behav vectors]
    set vec_src   [file join $design_dir sim vectors]

    if {![file isdirectory $vec_src]} {
        return
    }
    file mkdir $sim_behav
    if {[file exists $vec_link]} {
        return
    }
    if {[catch {exec cmd /c mklink /J [file nativename $vec_link] \
                                      [file nativename $vec_src]} err]} {
        puts "NOTE: could not link test vectors into the sim dir ($err)."
        puts "NOTE: run tb_requant_unit_num with 'python sim/run_tests.py' instead."
    }
}

set xpr [file join $proj_dir $proj_name.xpr]
set fresh 0

if {[file exists $xpr]} {
    puts "Refreshing existing project: $xpr"
    open_project $xpr
} else {
    puts "Creating project: $xpr"
    file mkdir $proj_dir
    create_project $proj_name $proj_dir -part $part -force
    set fresh 1
}

# --- source discovery -------------------------------------------------------
# Every rtl/*.sv is added, including the blocks not yet wired into the top
# (window_gen, line_buffer, requant_unit, requant_array, axi_lite_regs). They
# elaborate as out-of-context tops, which is exactly how you want to check
# their timing before integration.
sync_fileset constrs_1  [file join $design_dir vivado] *.xdc
sync_fileset sources_1  [file join $design_dir rtl]    *.sv
sync_fileset sim_1      [file join $design_dir tb]     *.sv

if {$fresh} {
    set_property top systolic_array_8x8 [get_filesets sources_1]
    set_property top tb_compute_engine  [get_filesets sim_1]
}

link_vectors $proj_dir $proj_name $design_dir

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts ""
puts "Project ready: $xpr"
puts "  synth top : [get_property top [get_filesets sources_1]]"
puts "  sim top   : [get_property top [get_filesets sim_1]]  (change in Sources > Simulation Sources)"
puts "  rtl files : [llength [get_files -quiet -of_objects [get_filesets sources_1]]]"
puts "  tb files  : [llength [get_files -quiet -of_objects [get_filesets sim_1]]]"
puts "  not yet in the top: window_gen, line_buffer, requant_unit, requant_array, axi_lite_regs"
