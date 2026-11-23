# Lane S6 report — AXI shell RTL

Date: 2026-11-14  
Worktree: `C:\grad-wt\s6`  
Branch supplied by orchestrator: `lane/s6-shell`

## Result

Requirements B-01 through B-04 were implemented and the focused shell test and
Vivado synthesis pass. The binding requirement that every pre-existing test
remain green cannot be met without changing an unowned test or lying about the
new register-map version: `tb_axi_lite_regs.sv:233` requires VERSION
`32'h0001_0004`, while contract section 3 requires VERSION
`32'h0001_0005`. Per contract section 8, I stopped instead of coding around
this contradiction. The final unchanged regression result is therefore 21/22.

## Production files changed

- `systolic-array-8x8/rtl/axi_lite_regs.sv`
  - Register-map v5 header and VERSION field.
  - W_ADDR `0x028`, W_DATA `0x02C`, 13-bit wrapping auto-increment.
  - BUSY write rejection with sticky ERROR[3].
  - Register-sourced weight-write pulse and level IRQ output.
- `systolic-array-8x8/rtl/accel_top.sv`
  - Minimal mux between legacy external and register-sourced weight writes.
  - New `irq` output; legacy ports remain present.
- `systolic-array-8x8/rtl/accel_axis.sv`
  - Named 32-bit AXI4-Lite and 64-bit AXI4-Stream shell.
  - External weight-write port tied off, input TKEEP ignored, output TKEEP FF.
- `systolic-array-8x8/rtl/accel_axis_wrapper.v`
  - Plain Verilog-2001 module-reference wrapper with AXI, AXIS, clock, reset,
    and interrupt interface attributes.
- `systolic-array-8x8/tb/tb_axis_shell.sv`
  - Port-only, self-checking shell test using the existing pure-Python conv1
    golden vectors.
- `systolic-array-8x8/vivado/check_synth_axis.tcl`
  - Wrapper synthesis top, shell sources, 100 MHz `aclk` OOC constraint, and
    unchanged +1.0 ns timing gate.
- `LANE-RAPOR-S6.md`

No existing testbench, `sim/run_tests.py`, `filelist.f`, generator, or contract
file was edited. No git command was run.

## Focused simulation

Command:

```text
cd systolic-array-8x8
python sim/run_tests.py tb_axis_shell -v
```

Real output lines:

```text
  tb_axis_shell  PASS
      | PASS tb_axis_shell: v5 weight MMIO, 2x conv bit-exact, AXIS stalls/TKEEP/TLAST, irq
1/1 passed
```

The test checks VERSION `0x0001_0005`; eight 75-byte banks loaded through
W_ADDR/W_DATA with auto-increment and bank changes; two 28x28 real convolution
passes against `gen_conv1_vectors.py`; a rejected BUSY-time weight write with
unchanged address and unchanged arithmetic result; IRQ disabled/enabled/DONE
W1C behavior; all-one TKEEP; final-beat-only TLAST; stable output under
backpressure; and LFSR pacing on both streams.

## Final full regression

Command (run once at the end, unchanged sources/tests):

```text
cd systolic-array-8x8
python sim/run_tests.py
```

Real output lines:

```text
  tb_accel_top            PASS
  tb_act_buffer           PASS
  tb_axi_lite_regs        FAIL
      | FAIL tb_axi_lite_regs: VERSION mismatch
      | FAIL tb_axi_lite_regs: 1 errors
  tb_axis_shell           PASS
  tb_compute_engine       PASS
  tb_conv1_top            PASS
  tb_fc_layer             PASS
  tb_layer_ctrl           PASS
  tb_lenet_e2e            PASS
  tb_pe_os                PASS
  tb_pool2x2              PASS
  tb_requant_array        PASS
  tb_requant_unit_num     PASS
  tb_requant_unit_timing  PASS
  tb_sys_bp               PASS
  tb_sys_chain            PASS
  tb_sys_faults           PASS
  tb_sys_ovf              PASS
  tb_v3_e2e               PASS
  tb_weight_feeder        PASS
  tb_weight_feeder_init   PASS
  tb_window_gen           PASS

21/22 passed
```

Contradicting unchanged test source:

```text
tb/tb_axi_lite_regs.sv:233:
check(value == 32'h0001_0004, "VERSION mismatch");
```

## Vivado synthesis

The first literal invocation stopped before reading the design with:

```text
ERROR: [Common 17-356] Failed to install all user apps.
ERROR: [Common 17-39] 'load_features' failed due to earlier errors.
```

Vivado was rerun with its local user-data cache disabled, keeping journal/log
under `sim/synth_axis_scratch`:

```text
$env:XILINX_LOCAL_USER_DATA = 'no'
& "C:\Vivado\2025.1\Vivado\bin\vivado.bat" -mode batch -source vivado/check_synth_axis.tcl -journal "sim/synth_axis_scratch/vivado_final.jou" -log "sim/synth_axis_scratch/vivado_final.log"
```

Real output lines:

```text
Synthesis finished with 0 errors, 0 critical warnings and 56 warnings.
AXIS_SYNTH: WNS=1.437 ns LUT=8663 FF=6495 BRAM=48 DSP=88
PASS: accel_axis_wrapper synthesis margin
```

Comparison with the supplied base: WNS changed from +1.593 ns to +1.437 ns
(-0.156 ns); RAMB36 remains 48; DSP remains 88. Base LUT/FF numbers were not
supplied, so no LUT/FF delta is claimed.

## Mutation results

Each mutant was a scratch copy of `axi_lite_regs.sv`; production RTL was not
mutated. Each was compiled with the normal RTL plus `tb_axis_shell.sv` in its
own XSim build directory.

| Mutant | Test | Real first failure line | Result |
|---|---|---|---|
| Remove W_ADDR auto-increment | `tb_axis_shell` | `AXIS-SHELL-FAIL: auto-increment bank 0 W_ADDR=00000000` | Killed |
| Remove BUSY guard from W_DATA write | `tb_axis_shell` | `AXIS-SHELL-FAIL: busy W_DATA advanced W_ADDR to 0000004b` | Killed |
| Remove IRQ_EN gating (`irq = DONE`) | `tb_axis_shell` | `AXIS-SHELL-FAIL: irq asserted while IRQ_EN=0` | Killed |

No mutant survived. Scratch mutation trees were created only under
`systolic-array-8x8/sim/mutations` and `sim/mutbuild_*`; sandbox policy refused
their recursive cleanup, so they remain explicitly as non-production scratch
artifacts and must not be committed.

## Unmeasured / objections

- Objection: contract section 3 and acceptance item 1 contradict the unowned
  assertion in `tb_axi_lite_regs.sv:233`. Resolution requires orchestrator
  ownership: update that one expected VERSION value to v5, or explicitly
  authorize a different compatibility contract. I did neither.
- Vivado synthesis validates that the wrapper attributes parse and the wrapper
  is synthesizable. I did not instantiate it interactively in an IP Integrator
  block design, so graphical interface grouping is not separately measured.
- The OOC timing report warns that `HD.CLK_SRC` is unset for `aclk`; this is the
  usual OOC clock-location warning and does not invalidate the measured +1.437
  ns synthesis slack.

## One-line additions left to the orchestrator

```text
tb/tb_axi_lite_regs.sv: VERSION expectation 32'h0001_0004 -> 32'h0001_0005 (required to resolve the binding contradiction).
filelist.f: append rtl/accel_axis.sv and rtl/accel_axis_wrapper.v if the integration flow consumes this static file list.
VECTOR_GENERATORS: no entry required; tb_axis_shell reuses gen_conv1_vectors.py / c1_y.mem.
sim/run_tests.py: no entry required; its *.sv discovery already includes accel_axis.sv and tb_axis_shell.sv.
```
## Orchestrator decision and VERSION regression closure

The orchestrator accepted the objection: the contract was wrong and explicitly
authorized exactly one existing-test change, in `tb/tb_axi_lite_regs.sv`:

```text
32'h0001_0004 -> 32'h0001_0005
```

No other line in that file was changed.

The literal requested command was attempted first:

```text
python sim/run_tests.py tb_axi_lite_regs tb_axis_shell
```

It could not reopen a retained simulator log in `sim/build`:

```text
CRITICAL WARNING: [Common 17-183] Failed to open handle xvlog.log. Please check access permission of directory 'C:\grad-wt\s6\systolic-array-8x8\sim\build'. You should restart the application from a writable working directory.
FAIL: compilation failed
```

The same unmodified runner and requested test selection were then run with only
its generated BUILD directory redirected to fresh writable scratch space:

```text
python -c "import sys; from pathlib import Path; import sim.run_tests as r; r.BUILD=Path('sim/build_s6_version_retry').resolve(); sys.argv=['sim/run_tests.py','tb_axi_lite_regs','tb_axis_shell']; raise SystemExit(r.main())"
```

Real output:

```text
[xvlog] compiling 37 file(s)

  tb_axi_lite_regs  PASS
  tb_axis_shell     PASS

2/2 passed
```

The previously reported VERSION contradiction is therefore resolved by the
orchestrator-authorized test expectation update.

Sandbox note: this text could not be appended directly to
`C:\grad-wt\s6\LANE-RAPOR-S6.md` because the current writable root is
`C:\grad-wt\s6\systolic-array-8x8`; the filesystem policy rejected writing to
its parent directory.
