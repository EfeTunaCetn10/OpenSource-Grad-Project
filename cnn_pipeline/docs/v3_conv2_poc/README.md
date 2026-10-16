# CompactCNN-v3 Conv2 / Cin=16 tile-major feasibility gate

Current source note: the fixed Conv2 module is now a compatibility wrapper over
`tile_major_repack.sv`. The [Conv3/shared-repacker gate](../v3_conv3_poc/README.md)
records its current implementation and repeated Conv2 checks. The measurements
below remain the original Conv2-gate record; its vectors/reports are unchanged.

This is a bounded candidate Conv2 POC, not v3 promotion or full-network
integration. It consumes the documented physical layout `[c_tile][H][W][8]`
and preserves existing integer arithmetic. Pool1 is generated in software from
one real saved validation image and the existing v3 PTQ parameters. No training,
calibration, PTQ parameter selection, or accuracy evaluation is performed.

## Chosen architecture

`v3_conv2_repack` is a **local full-frame repacking adapter**, fixed to Cin=16,
H=W=16. It stores 512 input beats (4 KiB) in tile-major order, waits until both
channel planes arrive, then feeds the unchanged line-buffer/window path in dense
HWC order. It does not change the external activation-storage contract.

- Physical word address: `channel_tile * 256 + h * 16 + w`.
- Lane within the word: `c % 8`; lane 0 is the low byte.
- Internal dense beat index: `(h * 16 + w) * 2 + channel_tile`.
- Read address: `{dense_index[0], dense_index[8:1]}`.
- Thus c=7 is lane 7 at word `pixel`, and c=8 is lane 0 at word `256+pixel`.
  Simply setting the external physical stride to 16 would not implement this.

A synchronous RAM read plus a held output register supports backpressure. The
adapter checks input last-beat placement, exposes a sticky error flag, and
requires a complete fresh input replay after restart. Memory is not cleared on
restart; every location is overwritten before another drain begins.

`v3_conv2_poc_top` wraps this adapter and the existing `conv1_top`, parameterized
for K=144, input 16×16×16, 3×3 kernel, stride 1 and padding 1. All existing
line-buffer, window, MAC, weight-feeder, controller and requantizer sources are
unchanged by this gate. The testbench drives three output-channel passes,
restarts the source and replays the input: channels 0–7, 8–15 and 16–23.

This is a local architectural addition (one staging buffer and read-order
adapter), not a replacement of the accelerator architecture. Costs include
4 KiB storage, full-frame load latency and reloading the same input for each
output tile. It is deliberately not optimized or presented as a final shared
activation-memory/replay design.

## Oracle and vectors

`cnn_pipeline/export_v3_conv2_poc.py` reuses the Conv1 exporter's provenance
checks, then reads Conv2 parameters from the same verified qparams/weight files.
It calls the existing integer MAC/requant helpers for Conv1, the independent
`integer_maxpool2d_ref` for Pool1, then the existing Conv2 oracle. No new arithmetic
or parameter-selection algorithm is introduced. The mathematical tensor order
remains NCHW/CHW; serialization is separate.

Generated files are isolated under:
`cnn_pipeline/outputs/model_v3_compact_seed42_60epochs/insects/rtl_conv2_poc/`.
Export refuses an existing directory.

| File | Contents |
|---|---|
| `frame.mem` | 512 tile-major 64-bit Pool1 beats |
| `pool1_chw.mem` | 4,096 logical INT8 input values |
| `weights_oihw.mem` | 24×16×3×3 existing INT8 weights |
| `wbank0.mem` … `wbank7.mem` | 432 bytes each; address = output_tile×144 + ci×9 + kh×3 + kw |
| `bias_q.mem`, `M0.mem`, `n.mem` | 24 existing per-channel parameters |
| `t0/1/2_acc.mem` | Pre-bias INT32 values, spatial position then output lane |
| `t0/1/2_biased.mem` | Bias-added INT32 in the same order |
| `t0/1/2_y.mem` | 256 output beats per tile, lane zero low byte |
| `manifest.json` | Source/sample/artifact hashes, scales, parameters, shapes and layout |

The checkpoint remains seed 42, epoch 52, SHA256
`09d17b5b8a77b5850645c9bb575c0cf12aaf8a9720ffe0677e1fc527016468f6`.
The debug image is the first saved validation sample, not a new calibration
selection. Pool preserves the Conv1 output scale used as Conv2's input scale.

## Verification scope

`tb_v3_conv2_reader` generates two different asymmetric signed tensors. It
checks all 512 dense repacked beats and all 36,864 padded window bytes per
pattern against independent coordinate calculations. This includes 4,608
window-byte checks specifically at c=7/8, all four corners, all four edges,
center positions and the transition between input planes. The second replay
changes the data, detecting stale memory. Both periodic and deterministic LFSR
output stalls are exercised, with input gaps and stable-under-stall assertions.

`tb_v3_conv2_poc` checks **6,144 final INT8 values, 6,144 MAC values and 6,144
actual bias-adder values per pattern** against the real artifact-derived oracle.
Both deterministic stall patterns cover all three output tiles, 768 output beats
and 96 spatial compute tiles per full Conv2. Counts, masks, output columns,
last markers, completion, error flags and output stability are checked. The
final padded row must complete, with no tolerance, dropped/duplicate/extra
outputs or ordering mismatch.

## Exact commands

From repository root (output already exists; do not overwrite it):

```sh
PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=2 /home/cgj/anaconda3/envs/pynq-cnn/bin/python -B cnn_pipeline/export_v3_conv2_poc.py --ptq-dir cnn_pipeline/outputs/model_v3_compact_seed42_60epochs/insects/ptq --output-dir cnn_pipeline/outputs/model_v3_compact_seed42_60epochs/insects/rtl_conv2_poc

PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=2 /home/cgj/anaconda3/envs/pynq-cnn/bin/python -B -m pytest -q -p no:cacheprovider cnn_pipeline/tests/test_export_v3_conv2_poc.py cnn_pipeline/tests/test_export_v3_conv1_poc.py cnn_pipeline/tests/test_experimental_v3_ptq.py cnn_pipeline/tests/test_integer_tensor_ops_ref.py

VIVADO_BIN=/home/cgj/Desktop/AMD/2025.2/Vivado/bin PYTHONDONTWRITEBYTECODE=1 /home/cgj/anaconda3/envs/pynq-cnn/bin/python -B -c 'import sys; sys.path.insert(0,"fpga/sim"); import run_tests; run_tests.BUILD=run_tests.PROJECT/"sim"/"build_v3_conv2"; sys.exit(run_tests.main())' tb_v3_conv2_reader tb_v3_conv2_poc --keep --verbose

VIVADO_BIN=/home/cgj/Desktop/AMD/2025.2/Vivado/bin PYTHONDONTWRITEBYTECODE=1 /home/cgj/anaconda3/envs/pynq-cnn/bin/python -B -c 'import sys; sys.path.insert(0,"fpga/sim"); import run_tests; run_tests.BUILD=run_tests.PROJECT/"sim"/"build_v3_conv2"; sys.exit(run_tests.main())' --keep

git diff --check
```

Synthesis command, from `/tmp/v3_conv2_synthesis_work`:

```sh
/home/cgj/Desktop/AMD/2025.2/Vivado/bin/vivado -mode batch -source /home/cgj/Desktop/OpenSource-Grad-Project/fpga/vivado/check_synth_v3_conv2.tcl -tclargs /home/cgj/Desktop/OpenSource-Grad-Project/cnn_pipeline/outputs/model_v3_compact_seed42_60epochs/insects/rtl_conv2_poc/synthesis
```

## Remaining gates

Conv3's Cin=24, 8×8 tensor has **three** input planes. The fixed two-plane
bit-permutation adapter here must not be silently reused for that geometry. A
separate three-plane mapping/generalization and real Conv3 oracle gate remain.
This proof does not provide shared activation-buffer lifecycle, automatic
output-channel/full-network sequencing, RTL pooling, FC execution, AXI DMA,
board execution or full-network RTL equivalence. Do not promote v3 on this
single-layer result or change contracts on its behalf.

## Measured result — 2026-10-16

**PASS for this bounded Conv2 feasibility gate.** On Vivado/XSim 2025.2:

- Focused RTL: **2/2 passed**.
- Full RTL regression: **17/17 passed**, including all 15 pre-existing tests.
- Relevant Python exporter/oracle/pooling tests: **139 passed**.
- Both stall patterns matched all 6,144 final outputs, all MAC values and all
  bias-added values across channels 0–7, 8–15 and 16–23. No missing/extra beats,
  incorrect ordering, rejected valid replay, error flags or deadlock occurred.
- Directed reader checks passed every spatial region and the c=7/8 boundary,
  with a changed second input fixture to check reload behavior.
- `git diff --check` passed. No pre-existing source or artifact was changed in
  this gate; the earlier Conv1 window fixes and unrelated local changes remain
  exactly as found. Frozen v1, contracts, PTQ and previous POC outputs remain
  unchanged. No Git writes were performed.

| OOC post-synthesis resource / timing | Measured value |
|---|---:|
| Part / target clock | xc7z020clg400-1 / 100 MHz |
| Total LUTs | 5,144 |
| Logic LUTs / LUTRAM / SRL | 4,886 / 206 / 52 |
| FFs | 4,052 |
| DSPs | 80 |
| RAMB36 / RAMB18 | 17 / 0 |
| Setup WNS | +0.897 ns |

The adapter's 512×64 memory is actually inferred as one RAMB36; the existing
weight banks account for the other 16. Raw LUT primitive count (6,082) is not
the device LUT utilization; use `utilization.rpt` for the 5,144 total.

This is synthesis of the adapter plus exercised datapath, **not** the testbench's
three-pass scheduler. It is not place-and-route or board timing. Clock-only OOC
constraints report zero unconstrained internal endpoints but no input/output
delays (571 input and 172 output ports). There is no external interface timing
closure claim.

The artifact directory contains `synthesis/` reports and `verification/` logs,
source hashes, preservation checks and machine-readable `results.json`. Temporary
simulation build files are removed after retaining the evidence. The next
bounded gate can address Conv3's three-plane reader geometry and real Conv3
outputs; v3 remains experimental and unpromoted.
