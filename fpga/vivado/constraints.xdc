# Out-of-context timing constraint for the 8x8 array core.
#
# This lives in an XDC rather than inline in check_synth.tcl on purpose:
# `create_clock ... [get_ports clk]` executed before `synth_design` fails with
# "No open design" because no elaborated netlist exists yet, and executed after
# `synth_design` it arrives too late to constrain synthesis at all. read_xdc
# defers evaluation until synth_design has elaborated the ports, which is the
# only ordering that both parses and actually constrains the optimizer.
create_clock -name clk -period 10.000 [get_ports clk]
