# CompactCNN-v3 Conv1 RTL proof of concept

This is an isolated **candidate Conv1** gate, not a full v3 migration, model
promotion, new numerical contract, or board demonstration. The mathematical
oracle remains NCHW/CHW. Only this test fixture serializes its input as dense HWC
and output as channel tile → row → column → lane (lane 0 is the low byte).

## Scope and source changes

- `cnn_pipeline/export_v3_conv1_poc.py` reads and verifies the existing v3 PTQ
  manifest, artifact hashes, recorded source/input hashes, checkpoint identity,
  calibration identity, preprocessing and debug-image membership/hash. It uses
  the first saved validation image as a debug fixture, not an accuracy test.
  Existing `integer_mac`, `requant_tensor`, `wrap32_tensor` and `quantize_int8`
  supply the oracle. No calibration or parameter selection runs.
- `fpga/rtl/window_gen.sv` has two local fixes: represent the full output width
  in the remaining-column counter (32 previously truncated to zero), and wait
  only for real input rows at the bottom padded border. Out-of-image reads
  already generated zero; their numerical semantics are unchanged.
- `fpga/tb/tb_v3_conv1_poc.sv` drives existing `conv1_top`: 3×32×32 input,
  3×3 kernel, padding 1, K=27, 16 output channels. The **testbench** loads both
  channel tiles into the eight weight banks and runs channels 0–7 then 8–15,
  issuing a window restart and replaying the input between passes. Parameters
  remain stable until each pass drains. No `accel_top` or `layer_ctrl` changes.
- `fpga/tb/tb_v3_padding.sv` independently checks every window byte of an
  asymmetric signed RGB fixture, including all four corners, all four edges
  and the center. Its 8-wide output also covers power-of-two width handling.
- `fpga/vivado/check_synth_v3_conv1.tcl` synthesizes the actual parameterized
  `conv1_top` datapath out of context for xc7z020clg400-1 at 100 MHz. The outer
  two-pass testbench sequencer is not synthesizable hardware being claimed here.
- `cnn_pipeline/tests/test_export_v3_conv1_poc.py` tests serialization, invalid
  byte rejection, manifest/hash rejection and overwrite refusal.

## Vector provenance and formats

Artifacts are isolated under
`cnn_pipeline/outputs/model_v3_compact_seed42_60epochs/insects/rtl_conv1_poc/`.
The exporter refuses an existing output directory. It preserves the original
`ptq/` artifacts and frozen-v1 canonical vectors.

The source checkpoint is seed 42, epoch 52, SHA256
`09d17b5b8a77b5850645c9bb575c0cf12aaf8a9720ffe0677e1fc527016468f6`.
`manifest.json` records all source/artifact/sample identities, scales, bias,
M0/n, shapes, transport orders and hashes of every exported vector file.

| Files | Meaning |
|---|---|
| `frame.mem` | 384 dense-HWC 64-bit input beats |
| `input_chw.mem`, `weights_oihw.mem` | Canonical logical tensors |
| `wbank0.mem` … `wbank7.mem` | 54 signed bytes each; address = tile×27 + ci×9 + kh×3 + kw |
| `bias_q.mem`, `M0.mem`, `n.mem` | 16 existing channel parameters, in channel order |
| `t0_acc.mem`, `t1_acc.mem` | Pre-bias INT32, spatial position then lane |
| `t0_biased.mem`, `t1_biased.mem` | Bias-added INT32 in the same order |
| `t0_y.mem`, `t1_y.mem` | 1,024 eight-lane INT8 beats each |

The integration scoreboard compares the engine/requant seam, the actual
requantizer bias-adder value on its acceptance handshake, and final output.
Each pattern covers **16,384 MAC values, 16,384 bias-added values, and 16,384
final INT8 values**, with no tolerance. It checks lane mask, column/last
metadata, beat counts, completion, status errors and stalled output stability.
Patterns are deterministic LFSR stalls plus periodic four-cycle output stalls;
both also use deterministic input gaps. There are 128 spatial compute tiles
per channel pass, 256 per complete Conv1, and 2,048 output beats per pattern.
No dropped/duplicate/extra beats or bottom-row deadlock are allowed.

## Commands

Run from repository root. The output directory below already exists; do not
rerun export into it. Use a separate new directory for intentional re-export.

```sh
PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=2 /home/cgj/anaconda3/envs/pynq-cnn/bin/python -B cnn_pipeline/export_v3_conv1_poc.py --ptq-dir cnn_pipeline/outputs/model_v3_compact_seed42_60epochs/insects/ptq --output-dir cnn_pipeline/outputs/model_v3_compact_seed42_60epochs/insects/rtl_conv1_poc

PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=2 /home/cgj/anaconda3/envs/pynq-cnn/bin/python -B -m pytest -q -p no:cacheprovider cnn_pipeline/tests/test_export_v3_conv1_poc.py cnn_pipeline/tests/test_experimental_v3_ptq.py

VIVADO_BIN=/home/cgj/Desktop/AMD/2025.2/Vivado/bin PYTHONDONTWRITEBYTECODE=1 /home/cgj/anaconda3/envs/pynq-cnn/bin/python -B -c 'import sys; sys.path.insert(0,"fpga/sim"); import run_tests; run_tests.BUILD=run_tests.PROJECT/"sim"/"build_v3_2025"; sys.exit(run_tests.main())' tb_v3_padding tb_v3_conv1_poc --keep --verbose

VIVADO_BIN=/home/cgj/Desktop/AMD/2025.2/Vivado/bin PYTHONDONTWRITEBYTECODE=1 /home/cgj/anaconda3/envs/pynq-cnn/bin/python -B -c 'import sys; sys.path.insert(0,"fpga/sim"); import run_tests; run_tests.BUILD=run_tests.PROJECT/"sim"/"build_v3_2025"; sys.exit(run_tests.main())' --keep
```

The build override keeps Vivado versions separate without changing the existing
runner. It has the same directory depth, preserving the testbench's relative
vector paths. The existing runner generated its missing synthetic regression
fixtures under `fpga/sim/vectors/`; those are unrelated to frozen-v1 canonical
ML export artifacts and were not present before this task.

Synthesis was invoked from `/tmp/v3_conv1_synthesis_work`:

```sh
/home/cgj/Desktop/AMD/2025.2/Vivado/bin/vivado -mode batch -source /home/cgj/Desktop/OpenSource-Grad-Project/fpga/vivado/check_synth_v3_conv1.tcl -tclargs /home/cgj/Desktop/OpenSource-Grad-Project/cnn_pipeline/outputs/model_v3_compact_seed42_60epochs/insects/rtl_conv1_poc/synthesis
```

## Remaining scope

Passing Conv1 does **not** resolve Conv2/Conv3's Cin=16/24 tile-major input
reader. Dense physical stride cannot substitute for gathering across channel
planes. Activation-buffer capacity/lifecycle, channel-tile sequencing,
pooling, FC paths and full-network integration remain separate gates. No AXI
DMA, board execution, synthesis of a full v3 accelerator, or contract promotion
is part of this POC. The next gate is Cin>8 activation-reader / Conv2 feasibility.

## Measured result (2026-10-16)

**PASS for this Conv1 gate.** Vivado/XSim 2025.2 ran the focused tests **2/2**
and the full RTL regression **15/15** (13 existing + 2 new). Python tests passed
**85/85** (10 exporter guards + 75 existing v3 PTQ tests); they did not rerun PTQ.
Each stall pattern matched every one of the 16,384 logical outputs, MACs and
bias-added accumulators; both channel passes and the final padded row completed.
The directed window test matched 1,728 bytes per pattern across all nine regions.

| OOC post-synthesis measurement | Value |
|---|---:|
| Target device / clock | xc7z020clg400-1 / 100 MHz |
| Total LUTs (utilization report) | 4,998 |
| Logic LUTs / LUTRAM / SRL | 4,836 / 110 / 52 |
| FF | 4,032 |
| DSP | 80 |
| RAMB36 / RAMB18 | 16 / 0 |
| Setup WNS | +0.897 ns |

The raw LUT primitive cell count (5,979) is **not** the packed total LUT resource
count. Use `utilization.rpt`, not the raw primitive count, for device budgeting.
The synthesis summary labels the primitive count explicitly. Timing has no
unconstrained internal endpoints, but this OOC clock-only constraint intentionally
has no input/output delays (570 input and 172 output ports reported). No place
and route, external interface timing closure or board result is claimed.

Vivado 2026.1 compiled/elaborated the testbenches but could not obtain a simulator
license. The reported PASS results and synthesis measurements are from the
working installed 2025.2 toolchain. XSim needed execution outside the sandbox to
initialize; no packages or licenses were installed or changed.

Logs, source hashes, preservation checks and `results.json` are retained beside
the vectors under `verification/`; synthesis reports are under `synthesis/`.
The temporary 2025.2 simulation build is removed after preserving the logs.
The v1 candidate, previous PTQ files, contracts and all unrelated RTL are
unchanged. No Git write operation was performed.

The compute datapath is suitable for the tested v3 Conv1 case. Advance to a
separate **Cin>8 tile-major activation-reader / Conv2 feasibility gate**, without
automatically promoting v3 or treating these results as full-network equivalence.
