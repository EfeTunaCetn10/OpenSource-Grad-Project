# Project abstract and current-version report

Report date: September 25, 2026. Development snapshot: `af03e9c` on
`feat/int8-ptq`. Main implementation baseline: `8f2767f`.

## Abstract

This graduation project targets a resource-conscious INT8 convolutional neural
network accelerator on the PYNQ-Z2 platform for 10-class insect recognition.
A compact, 62,006-parameter LeNet variant accepts 32×32 RGB images and provides a
fixed topology for coordinated machine-learning and hardware development. The
software workflow has progressed from FP32 training and validation-based model
selection to deterministic calibration, candidate post-training quantization,
and independently tested integer arithmetic components. A verified preparation
stage now assembles native-order INT8 weights, candidate INT32 biases and
per-channel requantization parameters for all five computational layers in
memory. The latest recorded Python suite contains 496 passing tests, and local
artifact preparation covers all 236 output channels. These results establish a
software foundation for the intended accelerator; they do not yet demonstrate
end-to-end integer classification, RTL equivalence or FPGA execution. The final
project is intended to connect this foundation to RTL verification and measured
FPGA deployment after numerical interface decisions are closed.

## What the latest pushes added

The development branch adds deterministic train-only calibration and auditable
FP32 activation/weight statistics. It produces candidate INT8 scales and weights,
then develops independent integer requantization, bias-free Linear and Conv2d,
and MaxPool/CHW Flatten references. Subsequent commits add candidate bias
quantization, multiplier analysis, a reusable M0/n interface, and single-layer
MAC+bias+requant composition. Commit `af03e9c` completes the current milestone:
verified, in-memory parameter preparation, without running the network.

The selected FP32 checkpoint uses seed 42 and epoch 51. Validation accuracy is
55.41%; the subsequent test evaluation is 51.54% accuracy and 36.45% macro recall.
Selection used validation results only. Two classes had zero test recall, so the
model's readiness cannot be inferred from aggregate accuracy alone.

Checkpoint SHA256:
`9983f9d32e755f2821337a8e0c6c144a71069fd36e2da8b5235840251af1947e`.

## Prepared parameter structure

| Layer | Native weight shape | Bias/M0/n length each | ReLU |
|---|---|---|---|
| Conv1 / features.0 | [6,3,5,5] | 6 | True |
| Conv2 / features.3 | [16,6,5,5] | 16 | True |
| FC1 / classifier.1 | [120,400] | 120 | True |
| FC2 / classifier.3 | [84,120] | 84 | True |
| FC3 / classifier.5 | [10,84] | 10 | False |

Preparation verifies recorded source hashes, checkpoint identity, tensor shapes,
dtypes and channel order. It reuses existing bias/multiplier algorithms and
returns independent CPU tensors and Python integer lists. No register dump,
weight-bank layout, .coe/.bin export or inference result is produced.

For the existing candidate scales, all 236 multipliers have valid approximate
pairs with n=25…29. None is exactly equal to its computed binary64 multiplier.
Maximum absolute error is 1.476305×10⁻⁸; maximum relative error is
7.235404×10⁻⁶ (approximately 0.000724%). No boundary anomaly occurred. These are
parameter approximation measurements, not classification accuracy measurements.

## Evidence and limits

The latest recorded test run is **496 passed**, including 22 tests added for
candidate model preparation. Synthetic cases cover hand-computed arithmetic,
signed rounding, saturation, overflow rejection, shape/type checks, channel
order, provenance failure and input preservation. A separate local preparation
smoke check passed for five layers/236 channels. This report does not represent
a new test, training, calibration or inference run.

Python reference correctness does not establish Python↔RTL↔FPGA bit-exact
agreement. No verified RTL completion status or measured FPGA latency,
throughput, power or utilization is claimed here.

## Remaining work toward the final project

1. Agree the remaining numerical interface details: candidate bias/multiplier
   policies, quantization boundaries, unsupported shifts and accumulator overflow.
2. Compose and test complete integer network execution using the existing
   primitives and prepared parameters; assess clipping and accuracy without
   using the test split for model selection.
3. Validate shared numerical cases against RTL, then perform system integration.
4. Implement and verify ADR-011-compatible banked weight export and hardware
   parameter handling when the interfaces are ready.
5. Deploy on PYNQ-Z2 and measure accuracy, latency/throughput and resource usage;
   document reproducibility and limitations in the final project report.

Some RTL/unit-test development can proceed in parallel, but export and final
integration depend on agreed interfaces. The accepted ADR-003 requantization
rounding/clamp rules should not be confused with still-experimental float bias
rounding or M0 selection. n=0 and n=50…63 remain unresolved for the hardware
path; current Python rejection is a diagnostic boundary.

## Source records

- [Selected model record](../cnn_pipeline/docs/accuracy_improvement/selected_model.json)
- [FP32 evaluation report](../cnn_pipeline/docs/accuracy_improvement/README.md)
- [Candidate model preparation at af03e9c](https://github.com/EfeTunaCetn10/OpenSource-Grad-Project/blob/af03e9c/cnn_pipeline/docs/candidate_integer_model/README.md)
- [Multiplier analysis at af03e9c](https://github.com/EfeTunaCetn10/OpenSource-Grad-Project/blob/af03e9c/cnn_pipeline/docs/multiplier_analysis/README.md)
- [ADR-003](../Kontratlar/ADR-003%20INT8%20Fixed-Point%20Formatı.md)
- [ADR-011](../Kontratlar/ADR-011%20Ağırlık%20Bellek%20Adresleme.md)

Feature links are pinned to the verified development commit so this main-branch
report does not rely on implementation paths that have not yet been merged.
