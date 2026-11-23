#!/usr/bin/env bash
# faz4 lane C system smoke (scratch).  Usage: bash run_smoke.sh [RTL_DIR]
# Regenerates vectors, compiles RTL_DIR/*.sv + tb_smoke_accel.sv in XSim and
# prints the S1..S4 / SMOKE result lines.  Trust only those lines.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
RTL="${1:-$HERE/../systolic-array-8x8/rtl}"
BIN=/c/Vivado/2025.1/Vivado/bin
python "$HERE/gen_smoke.py" || exit 1
rm -rf "$HERE/build" && mkdir -p "$HERE/build" && cd "$HERE/build" || exit 1
"$BIN/xvlog.bat" -sv "$RTL"/*.sv ../tb_smoke_accel.sv > xvlog.log 2>&1 || { tail -20 xvlog.log; exit 1; }
"$BIN/xelab.bat" -debug off -top tb_smoke_accel -snapshot smoke > xelab.log 2>&1 || { tail -20 xelab.log; exit 1; }
"$BIN/xsim.bat" smoke -runall > xsim.log 2>&1
grep -E "^S[1-7][a-c]? |SMOKE|S4 bad pass|Error:|Assertion|\\\$error" xsim.log | head -40
