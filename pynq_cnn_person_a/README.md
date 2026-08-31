# PYNQ-Z2 CNN Accelerator — Person A Training Pipeline

This project combines Week 3 and Week 4 of the Person A plan:

1. Train and verify LeNet-5 on MNIST.
2. Prepare a custom insect image dataset.
3. Calculate separate RGB normalization coefficients for each channel.
4. Train the same 32x32 CNN pipeline on insect images.

The floating-point model in this repository is the training baseline. INT8
quantization and golden-reference export should be added only after this model
and dataset pipeline are stable.

## 1. Environment

Python 3.10 or 3.11 is recommended.

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
pip install -r requirements.txt
```

If your NVIDIA/CUDA setup requires a specific PyTorch build, install PyTorch
using the command generated at https://pytorch.org/get-started/locally/ first,
then install the remaining requirements.

## 2. Week 3: MNIST smoke test

Run a short test first:

```bash
python train.py --dataset mnist --epochs 1 --limit-train 2048 --limit-eval 512
```

Then run the actual baseline:

```bash
python train.py --dataset mnist --epochs 10 --batch-size 128
```

Expected output files are written under `outputs/mnist/`:

- `best.pt`: best validation checkpoint
- `history.json`: epoch-by-epoch metrics
- `test_metrics.json`: final test accuracy and macro recall

The exact original LeNet-5 used tanh/average pooling and slightly different
output semantics. This implementation uses the commonly deployed ReLU/max-pool
variant because it is simpler to train and later map to integer hardware. We
still call it `LeNet5` in the code, but this distinction must be documented in
the project report.

## 3. Week 4: insect dataset

### Required raw layout

Put images into one folder per class:

```text
data/insects_raw/
  beetle/
    image_001.jpg
    image_002.jpg
  butterfly/
    image_001.jpg
  grasshopper/
    image_001.jpg
```

Do not mix object-detection annotations with this pipeline. This project starts
with image classification: one image has one class label.

### Create deterministic train/validation/test splits

```bash
python prepare_insects.py \
  --input-dir data/insects_raw \
  --output-dir data/insects \
  --train-ratio 0.70 \
  --val-ratio 0.15 \
  --seed 42
```

The command copies images; it does not alter the raw dataset. Each class must
contain at least 7 images, although substantially more is recommended.

### Calculate channel-wise RGB statistics

Only the training split is used, preventing validation/test leakage:

```bash
python compute_stats.py --train-dir data/insects/train --output data/insects/stats.json
```

### Train the RGB model

```bash
python train.py \
  --dataset insects \
  --data-dir data/insects \
  --stats data/insects/stats.json \
  --epochs 30 \
  --batch-size 128 \
  --learning-rate 0.001
```

Results are written under `outputs/insects/`. The checkpoint includes the class
names, RGB mean/std values, image size, and model configuration.

## 4. Verification checklist

- [ ] MNIST one-epoch smoke test completes.
- [ ] MNIST training accuracy and validation accuracy both improve.
- [ ] `prepare_insects.py` reports the expected class and image counts.
- [ ] No original raw images are modified.
- [ ] `stats.json` contains three mean and three standard-deviation values.
- [ ] Insect train/validation curves improve without a large persistent gap.
- [ ] Test set is evaluated only after selecting the best validation checkpoint.
- [ ] `best.pt`, `history.json`, and `test_metrics.json` are committed or archived.

## 5. Dataset decision gate

Before downloading a large dataset, agree with the advisor on:

- Is the task classification or detection?
- Which insect classes matter to the project?
- Is academic-only licensing acceptable?
- What is the minimum number of usable images per class?
- Is 32x32 resolution truly fixed by the accelerator interface?

IP102 is a strong research benchmark but is not an easy starter dataset: it has
102 classes, more than 75,000 images, and a long-tailed distribution. A sensible
first prototype is a documented 5-10 class subset with balanced train/validation/
test splits. Keep the original IP102 split if the final report claims direct
comparison with published IP102 results.

