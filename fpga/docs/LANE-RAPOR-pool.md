# Lane P: max pooling

## What landed

- `systolic-array-8x8/rtl/pool2x2.sv`: streaming signed INT8 2x2 stride-2 pool, eight lanes per beat, padded tile-major order, input and output backpressure.
- `systolic-array-8x8/model/pool_ref.py`: frozen `pool2x2(x, h, w, c)` API.
- `systolic-array-8x8/model/gen_pool_vectors.py`: deterministic Pool1 and Pool2 input/output vectors.
- `systolic-array-8x8/tb/tb_pool2x2.sv`: checks both geometries, randomized input gaps and output stalls, hold stability, output order, and final beat.
- `LANE-RAPOR-pool.md`: this report.

## Measured results

Focused: `python sim/run_tests.py tb_pool2x2 --keep` printed `tb_pool2x2 PASS`, `1/1 passed`.

Full suite: `python sim/run_tests.py` printed:

```text
  tb_accel_top            PASS
  tb_act_buffer           PASS
  tb_axi_lite_regs        PASS
  tb_compute_engine       PASS
  tb_conv1_top            PASS
  tb_layer_ctrl           PASS
  tb_pe_os                PASS
  tb_pool2x2              PASS
  tb_requant_array        PASS
  tb_requant_unit_num     PASS
  tb_requant_unit_timing  PASS
  tb_weight_feeder        PASS
  tb_weight_feeder_init   PASS
  tb_window_gen           PASS

14/14 passed
```

Baseline was 13/13; the new pool test makes it 14/14.

## Mutation results

XSim snapshot built by the focused run, invoked with `-testplusarg MUTANT<n> -onerror quit`:

| Mutation | Result |
|---|---|
| 1: expected output shifted by one beat | FAIL at Pool2 beat 0, no PASS line |
| 2: expected lane 0 sign bit flipped | FAIL at Pool2 beat 0, no PASS line |
| 3: expected lanes 0 and 1 swapped | FAIL at Pool2 beat 1, no PASS line |

XSim returned process exit code 0 for these deliberate `$fatal` mismatches; the FAIL lines and absence of a PASS line are the reliable checks, as the seam contract requires.

## What I could not verify

- Synthesis and timing were not run; the seam specifies simulation only.
- The pool was verified as a standalone block. Full-network RTL integration awaits the other lanes.
- Commit could not be created: `git add` failed with `Unable to create 'C:/grad-rtl/.git/worktrees/pool/index.lock': Permission denied`. Git worktree metadata is outside the writable root. The five assigned files remain untracked in this worktree.

## What the orchestrator must wire

- `systolic-array-8x8/sim/run_tests.py`: add `("gen_pool_vectors.py", "p1_y.mem")` to `VECTOR_GENERATORS`, so a fresh checkout produces the ignored pool vectors before the test runs.
- `systolic-array-8x8/filelist.f`: add `rtl/pool2x2.sv` for a synthesis project that uses this file list. The simulation runner already discovers it.
- `systolic-array-8x8/rtl/line_buffer.sv`: consider changing `K_H_VALUE` from a `RING_W`-wide constant to an integer or `$clog2(K_H+1)`-wide constant. At `K_H=2`, the current one-bit value truncates 2 to zero and makes ring read addresses unknown. This module uses `K_H=3` as a workaround, with only two rows live at a time.

## Contract disagreements

None. The verified `line_buffer` fits the beat and addressed-read interface, so it is reused. Its `K_H=2` parameter case is defective, requiring the three-slot ring above.
