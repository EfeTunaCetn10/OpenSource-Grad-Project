# PYNQ-Z2 CNN Accelerator

An FPGA-based deep learning accelerator project targeting PYNQ-Z2. The project
uses a compact LeNet-style network for 32×32 RGB insect image classification,
with INT8 inference and an integer golden reference planned for hardware verification.

## Current progress

- **Data preparation:** a 10-label Insect Detect subset, split by capture day.
- **FP32 training:** 50.31% test accuracy and 34.79% macro recall.
- **INT8 quantization and golden reference:** planned; not yet implemented.

The FP32 results are an initial baseline. Performance varies substantially
across classes, including two classes with zero test recall. See the
[evaluation report](cnn_pipeline/docs/fp32_baseline/README.md) for details.

## Repository structure

| Directory | Contents |
|---|---|
| [`cnn_pipeline/`](cnn_pipeline/) | Dataset preparation, PyTorch training, tests, and evaluation reports |
| [`Kontratlar/`](Kontratlar/) | Architecture decisions, hardware interfaces, and project roadmap |

## Getting started

Follow the [CNN pipeline guide](cnn_pipeline/README.md) to set up the Python
environment, prepare the dataset, and train the model.

The model uses two 5×5 convolution layers, ReLU activations, 2×2 max pooling,
and three fully connected layers. It is a LeNet variant rather than the
original tanh/average-pooling architecture. Hardware inference targets batch
size 1; training uses larger batches.

Raw images and trained checkpoints are stored locally and excluded from Git.
Evaluation reports and checkpoint hashes are versioned in the repository.
