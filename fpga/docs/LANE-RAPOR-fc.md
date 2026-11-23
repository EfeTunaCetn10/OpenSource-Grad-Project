# Lane F — FC drive path

## What landed

- `systolic-array-8x8/model/fc_ref.py` — generic 8-row FC reference, FC1 tile-major transform, and requant through `requant_ref.py`.
- `systolic-array-8x8/model/gen_fc_vectors.py` — deterministic 400-input, 120-output FC1 stimulus and golden vectors.
- `systolic-array-8x8/tb/tb_fc_layer.sv` — `conv1_top` FC1 replay over 15 output tiles, all INT32 and INT8 outputs checked, randomized output backpressure.
- `LANE-RAPOR-fc.md` — this report.

The FC1 transform was checked at `c=8,h=1,w=0 -> index 240`. The test uses `C_IN=400`, `KERN_H=KERN_W=1`, default `K_MAX=1024`, `cfg_k_len=400`, `cfg_active_rows=8`, and `cfg_tile_idx=0..14`. Each bank uses addresses `tile_idx*400+k`, ending at 5999 within `W_DEPTH=8192`.

## Measured results

`python model/gen_fc_vectors.py`: `PASS gen_fc_vectors: 15 tiles, K=400, y=[-128,127]`.

`python sim/run_tests.py tb_fc_layer --keep`: `1/1 passed`.

`python sim/run_tests.py` (full suite, baseline was 13/13):

```text
  tb_accel_top            PASS
  tb_act_buffer           PASS
  tb_axi_lite_regs        PASS
  tb_compute_engine       PASS
  tb_conv1_top            PASS
  tb_fc_layer             PASS
  tb_layer_ctrl           PASS
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

Ran the compiled `tb_fc_layer_snap` with each test plusarg. XSim exits 0 after `$fatal`, so the checks inspected the actual `Fatal: FAIL` line and absence of PASS.

| Mutation | Result |
|---|---|
| `FC_MUTATE_Y`: flip expected output bit 0 | Caught at tile 0: got `d525007f3600ba17`, expected `d525007f3600ba16` |
| `FC_MUTATE_ACC`: flip expected INT32 accumulator bit 0 | Caught at tile 0 row 0: got `0000367e`, expected `0000367f` |
| `FC_MUTATE_INDEX`: compare output against next tile | Caught at tile 0: got `d525007f3600ba17`, expected `1caa007fe10ff7fb` |

## What I could not verify

- Trained weights and classifier accuracy were outside this synthetic, bit-exact FC1 test.
- The testbench verifies FC1 specifically; FC2 and FC3 RTL runs are left to the end-to-end lane.

## What the orchestrator must wire

- `systolic-array-8x8/sim/run_tests.py`: add `("gen_fc_vectors.py", "fc1_y.mem")` to `VECTOR_GENERATORS`. The `.mem` files are ignored artifacts, and without this entry a fresh checkout does not generate FC1 vectors before the regression. I did not edit this shared file.

## Contract disagreements

None. The corrected single-run K=400 contract matches the RTL and measured test results.
