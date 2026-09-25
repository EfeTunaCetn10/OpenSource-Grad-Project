# PYNQ-Z2 CNN Accelerator

A graduation project developing an INT8 CNN accelerator for the PYNQ-Z2 FPGA
platform. The target workload is 10-class insect image classification using a
62,006-parameter LeNet variant with 32×32 RGB inputs and batch-size-one hardware
inference. The project combines FP32 model development, candidate post-training
quantization, Python integer references, and planned RTL/FPGA verification.

## Current status — September 25, 2026

The latest verified development push is
[`af03e9c` on `feat/int8-ptq`](https://github.com/EfeTunaCetn10/OpenSource-Grad-Project/tree/af03e9c).
The implementation below is on that branch; **it has not yet been merged into
main**, whose implementation baseline is `8f2767f`. This documentation update
summarizes both branches without merging development code.

| Area | Evidence and status |
|---|---|
| Data and FP32 model | Capture-day-based split; checkpoint selected by validation accuracy, not test performance |
| Selected FP32 results | 55.41% validation accuracy; 51.54% test accuracy and 36.45% test macro recall |
| Calibration | Deterministic train-only selection: 10 classes × 100 images, seed 42; no random augmentation |
| Candidate PTQ | Activation statistics, per-output-channel weight statistics, candidate scales and INT8 weights |
| Integer references | Independent Linear, Conv2d, MaxPool, Flatten and requantization; synthetic single-layer MAC+bias+requant composition |
| Model preparation | Verified checkpoint/qparams/weight artifact → five in-memory candidate layer packages, 236 output channels |
| Verification | Latest recorded Python suite: **496 passed**; real artifact preparation smoke check passed; no new test run for this documentation update |
| Remaining | Complete integer network execution, accuracy/clipping assessment, RTL comparison and FPGA deployment |

These are software milestones, not evidence of a finished accelerator. RTL/FPGA
bit-exact agreement, hardware performance and resource utilization have not been
established by this work. Class performance remains uneven, including two classes
with zero test recall in the selected FP32 evaluation.

## Architecture and numerical scope

The network uses two valid 5×5 convolutions (3→6→16 channels), ReLU and 2×2 max
pooling, followed by Linear layers 400→120→84→10. Final logits have no ReLU.
It is a LeNet variant, not the original tanh/average-pooling network.

ADR-003 specifies symmetric signed INT8 weights/activations, per-output-channel
weight scales, INT32 accumulators/bias, and signed 50-bit requantization
intermediates. The current **experimental** float quantizer uses [-127,127],
absmax/127 and half-up rounding. Bias rounding and multiplier selection remain
candidate software policies. Requantization retains its separate contracted
output saturation: [0,127] with ReLU, [-128,127] otherwise.

The Python reference currently supports n=1…49. n=0 and n=50…63 require explicit
resolution with the RTL team; software exceptions do not define hardware
failure behavior. Quantization boundaries and MAC+bias overflow handling also
need agreement before final integration/export.

## Reports and navigation

- [Project abstract and current-version report](docs/PROJECT_STATUS_REPORT.md)
- [FP32 selection and evaluation](cnn_pipeline/docs/accuracy_improvement/README.md)
- [Latest candidate model preparation](https://github.com/EfeTunaCetn10/OpenSource-Grad-Project/blob/af03e9c/cnn_pipeline/docs/candidate_integer_model/README.md)
- [Latest multiplier analysis](https://github.com/EfeTunaCetn10/OpenSource-Grad-Project/blob/af03e9c/cnn_pipeline/docs/multiplier_analysis/README.md)
- [Architecture decisions and roadmap](Kontratlar/)

## Getting started

Follow the [CNN pipeline guide](cnn_pipeline/README.md) for the existing FP32
workflow. To inspect the PTQ/integer components, use `feat/int8-ptq`; its component
READMEs describe the supported interfaces and limitations. The development test
suite can be run from the repository root in the configured Python environment:

```bash
python -m pytest -c cnn_pipeline/pytest.ini -q cnn_pipeline/tests
```

Raw images, trained checkpoints, calibration outputs and candidate artifacts are
local and excluded from Git. Synthetic tests do not require the real dataset;
real artifact preparation requires the recorded local files and valid provenance.
No hardware weight-bank export or complete integer inference is provided yet.
