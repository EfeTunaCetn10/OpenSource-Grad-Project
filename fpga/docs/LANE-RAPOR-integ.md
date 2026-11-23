# Lane I integration report

## What landed

- `systolic-array-8x8/tb/tb_lenet_e2e.sv`: replaced both pooling stand-ins with `pool2x2` RTL instances for 28×28×6 and 10×10×16. The sequencer streams captured padded tile-major convolution outputs, including Conv2's two sequential tiles. It applies randomized output backpressure, checks stall stability and `m_last`, and compares every pooled byte with the existing golden vectors.
- `LANE-RAPOR-integ.md`: this report.

All seven activation boundaries are now RTL-produced: Conv1, Pool1, Conv2, Pool2, FC1, FC2, and FC3. The testbench still models the PS sequencer, intermediate activation storage, and final argmax. Python models supply the deterministic fixture and golden vectors.

## Measured results

`python sim/run_tests.py tb_lenet_e2e`: **1/1 passed**. This run regenerated missing vectors. A later verbose targeted run printed:

```text
PASS conv1 RTL boundary: 4704 logical outputs across 1 tile(s)
PASS pool1 RTL boundary: 1568 padded bytes across 1 tile(s)
PASS conv2 RTL boundary: 1600 logical outputs across 2 tile(s)
PASS pool2 RTL boundary: 400 padded bytes across 2 tile(s)
PASS fc1 RTL boundary: 120 logical outputs across 15 tile(s)
PASS fc2 RTL boundary: 84 logical outputs across 11 tile(s)
PASS fc3 RTL boundary: 10 logical outputs across 2 tile(s)
PASS tb_lenet_e2e: all 7 boundaries, predicted=2
```

Full-suite `python sim/run_tests.py` result, compared with the measured 16/16 starting state:

```text
  tb_accel_top            PASS
  tb_act_buffer           PASS
  tb_axi_lite_regs        PASS
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
  tb_weight_feeder        PASS
  tb_weight_feeder_init   PASS
  tb_window_gen           PASS

16/16 passed
```

## Mutation results

Not required for Lane I; no mutation run was made.

## What I could not verify

- Trained-weight inference accuracy: this regression uses deterministic synthetic weights and vectors.
- Board-level PS, DMA, and activation-buffer integration: the Kademe 1 testbench supplies sequencing and intermediate storage.

## What the orchestrator must wire

Nothing in a restricted hot file. The testbench instantiates the existing pool RTL without RTL, model, runner, filelist, or ADR changes.

## Contract disagreements

- Section 7's lane split and section 8's 13/13 baseline describe an earlier state. All three lanes were already merged and the measured starting state was 16/16, as stated in the Lane I assignment.
- Section 0's commit instruction is superseded by the Lane I assignment; changes remain uncommitted for the orchestrator.
