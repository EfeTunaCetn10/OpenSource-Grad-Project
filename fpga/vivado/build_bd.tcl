# Rebuild the complete PS7 + AXI DMA + accelerator block design.
#
# Usage (Vivado 2025.1):
#   vivado -mode batch -source vivado/build_bd.tcl
#   vivado -mode batch -source vivado/build_bd.tcl -tclargs impl
#
# The generated project is disposable.  This Tcl file is the source of truth.

set mode bd
if {[llength $argv] > 0} {
    set mode [string tolower [lindex $argv 0]]
}
if {$mode ni {bd synth impl}} {
    puts stderr "ERROR: mode must be bd, synth, or impl (got '$mode')"
    exit 2
}

set script_dir [file dirname [file normalize [info script]]]
set design_dir [file normalize [file join $script_dir ..]]
set build_root [file normalize [file join $script_dir build]]
set project_dir [file join $build_root bd]
set overlay_dir [file join $build_root overlay]
set project_name accel_bd_project
set bd_name accel_bd
set part xc7z020clg400-1

if {![string is ascii $design_dir]} {
    puts stderr "ERROR: Vivado cannot reliably use the non-ASCII design path: $design_dir"
    exit 2
}

# The requirement deliberately makes each invocation clean and deterministic.
if {[file exists $project_dir]} {
    file delete -force -- $project_dir
}
file mkdir $project_dir
create_project $project_name $project_dir -part $part -force
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

# Prefer an installed PYNQ-Z2 board preset, but never require board files.
set pynq_parts [get_board_parts -quiet *pynq*z2*]
set used_board_preset 0
if {[llength $pynq_parts] > 0} {
    set board_part [lindex [lsort $pynq_parts] end]
    set_property board_part $board_part [current_project]
    set used_board_preset 1
    puts "BD_BOARD: using installed board preset $board_part"
} else {
    puts "BD_BOARD: no PYNQ-Z2 board files installed; using explicit PS7 fallback"
}

# Add only synthesizable RTL.  accel_axis_wrapper is intentionally a module
# reference rather than a packaged custom IP.
set rtl_dir [file join $design_dir rtl]
if {[info exists ::env(K3_RTL_DIR)] && $::env(K3_RTL_DIR) ne ""} {
    set rtl_dir [file normalize $::env(K3_RTL_DIR)]
    puts "BD_RTL: using scratch RTL directory $rtl_dir"
}
foreach f {
    pe_os.sv systolic_array_os.sv compute_engine.sv
    window_gen.sv line_buffer.sv requant_unit.sv requant_array.sv
    weight_feeder.sv layer_ctrl.sv conv1_top.sv
    pool2x2.sv act_buffer.sv axi_lite_regs.sv accel_top.sv accel_axis.sv
} {
    add_files -norecurse [file join $rtl_dir $f]
}
add_files -norecurse [file join $rtl_dir accel_axis_wrapper.v]
set_property file_type SystemVerilog [get_files -quiet *.sv]
update_compile_order -fileset sources_1

create_bd_design $bd_name

set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:* processing_system7_0]
if {$used_board_preset} {
    apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
        -config {apply_board_preset "1" make_external "FIXED_IO, DDR"} $ps7
} else {
    # Simulation- and PL-interface-critical settings.  Physical DDR/MIO/clock
    # electrical settings cannot be verified without the PYNQ-Z2 preset and
    # are listed in bd_build_summary.txt for the board bring-up owner.
    set_property -dict [list \
        CONFIG.PCW_USE_M_AXI_GP0 {1} \
        CONFIG.PCW_USE_S_AXI_HP0 {1} \
        CONFIG.PCW_USE_FABRIC_INTERRUPT {1} \
        CONFIG.PCW_IRQ_F2P_INTR {1} \
        CONFIG.PCW_EN_CLK0_PORT {1} \
        CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100.000000} \
    ] $ps7
    make_bd_intf_pins_external [get_bd_intf_pins processing_system7_0/DDR]
    make_bd_intf_pins_external [get_bd_intf_pins processing_system7_0/FIXED_IO]
}

# Board presets describe physical PS wiring; this design still owns which PL
# interfaces are enabled.  Apply these after either branch so HP0/IRQ cannot be
# silently disabled by a preset default.
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_USE_S_AXI_HP0 {1} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT {1} \
    CONFIG.PCW_IRQ_F2P_INTR {1} \
    CONFIG.PCW_EN_CLK0_PORT {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100.000000} \
] $ps7
# The PYNQ preset marks derived AXI frequencies as USER (10 MHz).  Return
# those read-only derived fields to propagation so the common FCLK0 net sets
# both interfaces to 100 MHz without a validation conflict.
set_property CONFIG.PCW_M_AXI_GP0_FREQMHZ.VALUE_SRC DEFAULT $ps7
set_property CONFIG.PCW_S_AXI_HP0_FREQMHZ.VALUE_SRC DEFAULT $ps7

set dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:* axi_dma_0]
set_property -dict [list \
    CONFIG.c_include_sg {0} \
    CONFIG.c_include_mm2s {1} \
    CONFIG.c_include_s2mm {1} \
    CONFIG.c_m_axi_mm2s_data_width {64} \
    CONFIG.c_m_axis_mm2s_tdata_width {64} \
    CONFIG.c_m_axi_s2mm_data_width {64} \
    CONFIG.c_s_axis_s2mm_tdata_width {64} \
    CONFIG.c_sg_length_width {23} \
    CONFIG.c_addr_width {32} \
] $dma

set accel [create_bd_cell -type module -reference accel_axis_wrapper accel_0]
set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:* rst_ps7_0_100M]
set one [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:* const_one]
set_property -dict [list CONFIG.CONST_VAL {1} CONFIG.CONST_WIDTH {1}] $one
set reset_inv [create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:* reset_inv]
set_property -dict [list CONFIG.C_OPERATION {not} CONFIG.C_SIZE {1}] $reset_inv

# GP0 is 32-bit control traffic.  Its two slaves are the DMA registers and
# the accelerator AXI4-Lite register file.
set ctrl_ic [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:* axi_ctrl_ic]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {2}] $ctrl_ic
connect_bd_intf_net [get_bd_intf_pins processing_system7_0/M_AXI_GP0] \
                    [get_bd_intf_pins axi_ctrl_ic/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ctrl_ic/M00_AXI] \
                    [get_bd_intf_pins axi_dma_0/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins axi_ctrl_ic/M01_AXI] \
                    [get_bd_intf_pins accel_0/S_AXI]

# The two 64-bit DMA memory masters share the PS7 64-bit HP0 slave port.
set mem_ic [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:* axi_mem_ic]
set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] $mem_ic
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_MM2S] \
                    [get_bd_intf_pins axi_mem_ic/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_S2MM] \
                    [get_bd_intf_pins axi_mem_ic/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_mem_ic/M00_AXI] \
                    [get_bd_intf_pins processing_system7_0/S_AXI_HP0]

# One DMA transaction is one pass.  Width/TKEEP/TLAST are preserved end to end.
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXIS_MM2S] \
                    [get_bd_intf_pins accel_0/S_AXIS]
connect_bd_intf_net [get_bd_intf_pins accel_0/M_AXIS] \
                    [get_bd_intf_pins axi_dma_0/S_AXIS_S2MM]

# ADR-008: every PL interface is on FCLK0, with no clock converters.
set fclk [get_bd_pins processing_system7_0/FCLK_CLK0]
connect_bd_net $fclk \
    [get_bd_pins processing_system7_0/M_AXI_GP0_ACLK] \
    [get_bd_pins processing_system7_0/S_AXI_HP0_ACLK] \
    [get_bd_pins rst_ps7_0_100M/slowest_sync_clk] \
    [get_bd_pins axi_dma_0/s_axi_lite_aclk] \
    [get_bd_pins axi_dma_0/m_axi_mm2s_aclk] \
    [get_bd_pins axi_dma_0/m_axi_s2mm_aclk] \
    [get_bd_pins accel_0/aclk] \
    [get_bd_pins axi_ctrl_ic/ACLK] \
    [get_bd_pins axi_ctrl_ic/S00_ACLK] \
    [get_bd_pins axi_ctrl_ic/M00_ACLK] \
    [get_bd_pins axi_ctrl_ic/M01_ACLK] \
    [get_bd_pins axi_mem_ic/ACLK] \
    [get_bd_pins axi_mem_ic/S00_ACLK] \
    [get_bd_pins axi_mem_ic/S01_ACLK] \
    [get_bd_pins axi_mem_ic/M00_ACLK]

connect_bd_net [get_bd_pins processing_system7_0/FCLK_RESET0_N] \
               [get_bd_pins reset_inv/Op1]
connect_bd_net [get_bd_pins reset_inv/Res] [get_bd_pins rst_ps7_0_100M/ext_reset_in]
connect_bd_net [get_bd_pins const_one/dout] [get_bd_pins rst_ps7_0_100M/dcm_locked]
set aresetn [get_bd_pins rst_ps7_0_100M/peripheral_aresetn]
connect_bd_net $aresetn \
    [get_bd_pins axi_dma_0/axi_resetn] \
    [get_bd_pins accel_0/aresetn] \
    [get_bd_pins axi_ctrl_ic/ARESETN] \
    [get_bd_pins axi_ctrl_ic/S00_ARESETN] \
    [get_bd_pins axi_ctrl_ic/M00_ARESETN] \
    [get_bd_pins axi_ctrl_ic/M01_ARESETN] \
    [get_bd_pins axi_mem_ic/ARESETN] \
    [get_bd_pins axi_mem_ic/S00_ARESETN] \
    [get_bd_pins axi_mem_ic/S01_ARESETN] \
    [get_bd_pins axi_mem_ic/M00_ARESETN]

set irq_concat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:* irq_concat]
set_property -dict [list CONFIG.NUM_PORTS {3}] $irq_concat
connect_bd_net [get_bd_pins axi_dma_0/mm2s_introut] [get_bd_pins irq_concat/In0]
connect_bd_net [get_bd_pins axi_dma_0/s2mm_introut] [get_bd_pins irq_concat/In1]
connect_bd_net [get_bd_pins accel_0/irq] [get_bd_pins irq_concat/In2]
connect_bd_net [get_bd_pins irq_concat/dout] [get_bd_pins processing_system7_0/IRQ_F2P]

# Stable software-visible addresses.  The accelerator register interface is
# 4 KiB; a 64 KiB decode window avoids interconnect range corner cases.
assign_bd_address
set_property offset 0x40400000 [get_bd_addr_segs processing_system7_0/Data/SEG_axi_dma_0_Reg]
set_property range 64K [get_bd_addr_segs processing_system7_0/Data/SEG_axi_dma_0_Reg]
set accel_segs [get_bd_addr_segs -quiet processing_system7_0/Data/SEG_accel_0_reg0]
if {[llength $accel_segs] != 1} {
    puts stderr "ERROR: expected one PS7 address segment for accel_0, found [llength $accel_segs]: $accel_segs"
    exit 3
}
set_property offset 0x43C00000 $accel_segs
set_property range 64K $accel_segs

validate_bd_design
save_bd_design

set bd_file [get_files [file join $project_dir $project_name.srcs sources_1 bd $bd_name ${bd_name}.bd]]
generate_target all $bd_file
set wrapper [make_wrapper -files $bd_file -top]
add_files -norecurse $wrapper
set_property top ${bd_name}_wrapper [get_filesets sources_1]
update_compile_order -fileset sources_1

set summary_path [file join $project_dir bd_build_summary.txt]
set summary [open $summary_path w]
puts $summary "part=$part"
puts $summary "fclk0_mhz=100"
puts $summary "accelerator_base=0x43C00000"
puts $summary "dma_base=0x40400000"
puts $summary "dma_stream_width=64"
puts $summary "dma_memory_width=64"
puts $summary "dma_length_width=23"
puts $summary "board_preset_used=$used_board_preset"
if {!$used_board_preset} {
    puts $summary "UNVERIFIED_BOARD_SETTINGS: DDR part/timing/termination, PS input clock frequency, MIO voltage/bank mapping, UART/SD/USB/Ethernet peripheral MIO, and fixed-IO electrical settings require comparison with the real PYNQ-Z2 preset before hardware programming."
}
close $summary

puts "BD_VALIDATE: PASS design=$bd_name accel_base=0x43C00000 dma_base=0x40400000 board_preset=$used_board_preset"

if {$mode eq "bd"} {
    close_project
    exit 0
}

launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {![string match "*Complete*" [get_property STATUS [get_runs synth_1]]]} {
    puts stderr "ERROR: synth_1 failed: [get_property STATUS [get_runs synth_1]]"
    exit 4
}
open_run synth_1
report_utilization -file [file join $project_dir bd_synth_utilization.rpt]
puts "BD_SYNTH: PASS"
if {$mode eq "synth"} {
    close_project
    exit 0
}

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {![string match "*Complete*" [get_property STATUS [get_runs impl_1]]]} {
    puts stderr "ERROR: impl_1 failed: [get_property STATUS [get_runs impl_1]]"
    exit 5
}
open_run impl_1
report_timing_summary -delay_type min_max -max_paths 20 \
    -file [file join $project_dir bd_timing_summary.rpt]
report_utilization -file [file join $project_dir bd_utilization.rpt]
report_cdc -details -file [file join $project_dir bd_cdc.rpt]
report_methodology -file [file join $project_dir bd_methodology.rpt]

set setup_paths [get_timing_paths -delay_type max -max_paths 1]
set hold_paths [get_timing_paths -delay_type min -max_paths 1]
set wns [expr {[llength $setup_paths] ? [get_property SLACK [lindex $setup_paths 0]] : -999.0}]
set whs [expr {[llength $hold_paths] ? [get_property SLACK [lindex $hold_paths 0]] : -999.0}]
set lut [llength [get_cells -hierarchical -filter {REF_NAME =~ LUT*}]]
set ff [llength [get_cells -hierarchical -filter {REF_NAME =~ FD*}]]
set bram [llength [get_cells -hierarchical -filter {REF_NAME =~ RAMB*}]]
set dsp [llength [get_cells -hierarchical -filter {REF_NAME =~ DSP48*}]]

file mkdir $overlay_dir
set bit_file [file join $project_dir ${project_name}.runs impl_1 ${bd_name}_wrapper.bit]
if {![file exists $bit_file]} {
    puts stderr "ERROR: bitstream not found at $bit_file"
    exit 6
}
file copy -force $bit_file [file join $overlay_dir accel.bit]
set hwh_candidates [glob -nocomplain -types f \
    [file join $project_dir ${project_name}.gen sources_1 bd $bd_name hw_handoff *.hwh]]
if {[llength $hwh_candidates] != 1} {
    puts stderr "ERROR: expected one HWH file, found: $hwh_candidates"
    exit 7
}
file copy -force [lindex $hwh_candidates 0] [file join $overlay_dir accel.hwh]

puts "BD_IMPL: WNS=$wns WHS=$whs LUT=$lut FF=$ff BRAM=$bram DSP=$dsp"
if {$wns < 0.0 || $whs < 0.0} {
    puts stderr "ERROR: implementation timing failed"
    exit 8
}
close_project
exit 0
