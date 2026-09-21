# CNN Training and Evaluation Pipeline

PyTorch tools for training and evaluating a LeNet-style CNN for the PYNQ-Z2
accelerator project. The pipeline covers MNIST validation, capture-day-based
insect dataset preparation, RGB normalization, and FP32 training.

## Model and baseline

```text
RGB 3×32×32
→ Conv(3→6, 5×5) → ReLU → MaxPool(2×2)
→ Conv(6→16, 5×5) → ReLU → MaxPool(2×2)
→ Flatten(400)
→ Linear(400→120) → ReLU
→ Linear(120→84) → ReLU
→ Linear(84→10)
```

This ReLU/max-pool variant differs from the original LeNet-5. The insect
baseline uses 10 dataset labels, which do not necessarily represent 10 distinct
biological species.

| Metric | FP32 baseline |
|---|---:|
| Best validation accuracy | 50.90% |
| Test accuracy | 50.31% |
| Test macro recall | 34.79% |

Results include weak performance on several classes. Read the
[full evaluation](docs/fp32_baseline/README.md) before interpreting the overall
accuracy. INT8 quantization and integer golden-reference export are the next
development stages.

## Environment

Run the following from the repository root. Python 3.10 or 3.11 is recommended.

```bash
cd cnn_pipeline
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
pip install -r requirements.txt
```

All remaining commands run from `cnn_pipeline/` with the environment active.

## Prepare the insect dataset

Place `Insect_Detect_classification_v2.zip` in `data/source/`. The preparation
script validates the expected archive checksum, selects 10 labels, and keeps
capture days together across train, validation, and test sets.

```bash
python prepare_insect_detect.py \
  --archive data/source/Insect_Detect_classification_v2.zip \
  --output-dir data/insects \
  --seed 42

python compute_stats.py \
  --train-dir data/insects/train \
  --output data/insects/stats.json \
  --workers 0
```

The prepared subset has 7,297 training, 1,774 validation, and 1,624 test images.
Normalization coefficients are calculated only from training images. See the
[preparation guide](docs/insect_detect_preparation.md) for selection criteria,
class counts, grouping limitations, and reproducibility details.

`prepare_insects.py` is a separate generic random-image splitter for independent
images stored in class folders. It should not be used for this repeated-capture
dataset.

## Train and evaluate

Start with a short training/validation run:

```bash
python train.py --dataset insects \
  --data-dir data/insects --stats data/insects/stats.json \
  --output-dir outputs/smoke_3epochs \
  --epochs 3 --batch-size 128 --workers 0 --skip-test
```

For the 30-epoch baseline and final test evaluation:

```bash
OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 python train.py \
  --dataset insects --data-dir data/insects \
  --stats data/insects/stats.json \
  --output-dir outputs/fp32_30epochs \
  --epochs 30 --batch-size 128 --workers 0 --seed 42
```

Use a new output directory for each run. The dataset name is appended to it;
the script refuses to overwrite an existing nonempty result directory. Use
`--skip-test` for preliminary experiments and reserve test evaluation for the
selected model.

Training produces:

- `best.pt`: weights selected by validation accuracy, plus model configuration,
  class names, normalization coefficients, and seed.
- `history.json`: loss, accuracy, and learning rate for each epoch.
- `test_metrics.json`: test loss, accuracy, macro recall, and confusion matrix
  when test evaluation is enabled.

## MNIST reference

MNIST provides a separate one-channel reference for checking the training pipeline.

```bash
python train.py --dataset mnist --epochs 1 \
  --limit-train 2048 --limit-eval 512 \
  --output-dir outputs/mnist_smoke --skip-test

python train.py --dataset mnist --epochs 10 --batch-size 128 \
  --output-dir outputs/mnist_baseline
```

## Tests and reports

```bash
python -m pytest -q
```

- [Dataset preparation and normalization](docs/insect_detect_preparation.md)
- [Three-epoch training check](docs/insect_detect_smoke_training.md)
- [FP32 evaluation and checkpoint manifest](docs/fp32_baseline/README.md)
- [Validation error analysis and next experiment](docs/validation_review/README.md)

Raw datasets and checkpoint binaries remain local under `data/` and `outputs/`.
Small reports and checkpoint identities are tracked under `docs/`.
