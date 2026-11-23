# Lane E report — 2026-10-09

## What landed

- `systolic-array-8x8/model/lenet_ref.py` — deterministic full-network fixture and seven layer outputs; frozen pool/FC imports with marked local stand-ins.
- `systolic-array-8x8/model/gen_lenet_vectors.py` — serializes all input, weight, config, boundary, and class vectors.
- `systolic-array-8x8/tb/tb_lenet_e2e.sv` — PS-role sequencer using `conv1_top` for Conv1, two Conv2 tiles, and all FC tiles; captures padded tile-major intermediates, compares every boundary, then checks argmax.
- `LANE-RAPOR-e2e.md` — this report.

## Measured results

`python model/gen_lenet_vectors.py`: `PASS gen_lenet_vectors stand-ins predicted 2`. This is a synthetic fixture, not trained-model accuracy. The Python Pool1/Pool2 and FC1/FC2/FC3 reference values came from the marked stand-ins. Conv1 values came from the existing `conv1_ref.py`; Conv2 uses its own generalized convolution loop with `engine_ref.wrap32` and `requant_ref.requant_ref`. FC1's dense-to-physical weight transform asserts the ADR-018 example `c=8,h=1,w=0 -> 240`.

The focused XSim run before the FC1 weight-order refinement printed PASS at all seven boundaries: Conv1 RTL 4704 outputs; Pool1 stand-in 1568 padded bytes; Conv2 RTL 1600 outputs over two tiles; Pool2 stand-in 400 bytes; FC1 RTL 120; FC2 RTL 84; FC3 RTL 10. The final full suite below was rerun after the refinement against regenerated vectors. Thus Conv1, Conv2, FC1, FC2, and FC3 exercised real `conv1_top` RTL, but the FC golden numbers were produced by the local FC reference stand-in. Both pooling stages exercised testbench stand-ins, not pool RTL.

Final `python sim/run_tests.py` output (baseline 13/13, now 14/14):

```text
[xvlog] compiling 27 file(s)

  tb_accel_top            PASS
  tb_act_buffer           PASS
  tb_axi_lite_regs        PASS
  tb_compute_engine       PASS
  tb_conv1_top            PASS
  tb_layer_ctrl           PASS
  tb_lenet_e2e            PASS
  tb_pe_os                PASS
  tb_requant_array        PASS
  tb_requant_unit_num     PASS
  tb_requant_unit_timing  PASS
  tb_weight_feeder        PASS
  tb_weight_feeder_init   PASS
  tb_window_gen           PASS

14/14 passed
```

## Mutation results

Not required for Lane E; not run.

## What I could not verify

- `pool2x2` RTL and the real `pool_ref.py`/`fc_ref.py` were absent in this worktree. The model import guard selected local stand-ins, and the TB used stand-in pooling over captured RTL outputs. Their integration behavior remains unverified.
- End-to-end classification accuracy with trained weights was not measured; all weights are deterministic synthetic INT8 values.
- A clean checkout cannot run `tb_lenet_e2e` through `sim/run_tests.py` alone until the vector generator is registered in that runner; this lane invoked it explicitly first.
- Commit could not be created in this sandbox: `git add` was denied while creating `C:/grad-rtl/.git/worktrees/e2e/index.lock` outside the writable root. The four owned files remain untracked in this worktree.

## What the orchestrator must wire

- In `systolic-array-8x8/sim/run_tests.py`, add `("gen_lenet_vectors.py", "lenet_pred.mem")` to `VECTOR_GENERATORS` so a clean checkout generates these ignored vectors before simulation. I did not edit this hot file.
- After Lane P lands, replace both marked stand-in pooling tasks in `systolic-array-8x8/tb/tb_lenet_e2e.sv` with a `pool2x2` RTL driver using the actual Lane P port interface. Feed the captured padded tile-major Conv1/Conv2 arrays through that driver and keep the existing per-byte boundary comparisons. Regenerate vectors using the merged real `pool_ref.py` and `fc_ref.py`, then rerun the full suite. No existing RTL or `filelist.f` change is needed for this lane.

## Contract disagreements

- Section 1 says new files are auto-discovered; this is true for `tb/*.sv`, but `sim/run_tests.py` has a fixed `VECTOR_GENERATORS` list. The new generator needs the explicit hot-file entry above.
