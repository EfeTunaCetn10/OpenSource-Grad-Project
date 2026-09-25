# T_NUM_REQ_001 -- requantizer bit-exact test (ADR-003, Layer 1 per ADR-009).
# Requires cocotb + Icarus Verilog, neither installed on this machine yet
# (see Threads.md). Once available:
#   cd tb/cocotb && make

SIM ?= icarus
TOPLEVEL_LANG ?= verilog

PWD := $(shell pwd)

VERILOG_SOURCES = $(PWD)/../../rtl/requantizer.sv
TOPLEVEL = requantizer
MODULE = test_requantizer

include $(shell cocotb-config --makefiles)/Makefile.sim
