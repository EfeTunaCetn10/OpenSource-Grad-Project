# Remove ColorJitter — controlled seed-42 experiment

Decision: **do not promote; no PTQ**. Candidate v1 remains frozen.
The only changed training behavior is removal of ColorJitter. Full-image resize,
horizontal flip, architecture, split, normalization, AdamW, LR 0.001, weight decay
1e-4, smoothing 0, batch 128, cosine schedule, 60 epochs, seed 42 and CPU settings
remain unchanged. Checkpoint selection is highest validation accuracy, first tie.
Removing jitter changes random-number consumption and therefore later flip draws;
the flip probability is unchanged. This is not a paired augmentation-stream test.
The opt-out defaults off, preserving existing loader/training behavior.

## Command and output

From `cnn_pipeline/`:

```bash
PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 /home/cgj/anaconda3/envs/pynq-cnn/bin/python -B -u train.py --dataset insects --data-dir data/insects --stats data/insects/stats.json --output-dir outputs/resize_cosine_nojitter_seed42_60epochs --epochs 60 --batch-size 128 --learning-rate 0.001 --weight-decay 0.0001 --label-smoothing 0 --workers 0 --seed 42 --train-resize --no-color-jitter --scheduler cosine --skip-test
```

Output: `cnn_pipeline/outputs/resize_cosine_nojitter_seed42_60epochs/insects/`.
All 60 epochs completed. The selected checkpoint was reloaded and independently
evaluated on all 1,774 validation images with ordinary unsmoothed cross-entropy.
No test-split evaluation, quantization or golden/vector regeneration occurred.

## Comparison

| Metric | Baseline | WD 1e-3 | Smoothing .05 | No ColorJitter |
|---|---:|---:|---:|---:|
| Best epoch | 51.0000 | 60.0000 | 50.0000 | 46.0000 |
| Train accuracy % | 70.5358 | 71.5911 | 71.2759 | 68.4939 |
| Train loss | 0.8474 | 0.8243 | 1.0233 | 0.8888 |
| Validation accuracy % | 55.4115 | 55.3551 | 55.5242 | 54.3405 |
| Validation loss | 1.3351 | 1.3507 | 1.3124 | 1.4006 |
| Gap pp | 15.1243 | 16.2359 | 15.7516 | 14.1534 |
| Macro recall % | 40.3275 | 39.7441 | 39.5734 | 39.6734 |

Smoothing training loss is not comparable to ordinary CE. Train metrics are
online augmented-batch measurements, not clean fixed-checkpoint evaluation.

| Class | Baseline % | WD % | Smoothing % | No jitter % | Δ baseline pp |
|---|---:|---:|---:|---:|---:|
| bee | 57.98 | 56.38 | 53.72 | 64.36 | 6.38 |
| beetle | 2.35 | 3.53 | 2.35 | 2.35 | 0.00 |
| beetle_cocci | 56.67 | 58.33 | 55.83 | 50.83 | -5.83 |
| bug | 24.49 | 22.45 | 22.45 | 16.33 | -8.16 |
| fly | 68.59 | 68.95 | 71.48 | 77.62 | 9.03 |
| fly_sarco | 3.28 | 3.28 | 3.28 | 9.84 | 6.56 |
| fly_small | 58.08 | 58.08 | 55.02 | 46.72 | -11.35 |
| hfly_episyr | 84.92 | 85.81 | 88.03 | 80.04 | -4.88 |
| hfly_eupeo | 29.27 | 28.86 | 28.86 | 28.05 | -1.22 |
| hfly_sphaero | 17.65 | 11.76 | 14.71 | 20.59 | 2.94 |

## Confusion matrix

Rows=true, columns=predicted; order: `bee, beetle, beetle_cocci, bug, fly, fly_sarco, fly_small, hfly_episyr, hfly_eupeo, hfly_sphaero`.

```text
121   2   0   0  21   0  21  13   8   2
 27   2   0   0  17   0  30   2   6   1
  0   9  61  15  17   0   1   6  11   0
  0   6  21   8   3   1   0   4   6   0
  8   0   0   2 215   1  45   2   3   1
  2   0   0   0  48   6   4   0   1   0
 12   2   0   0  62   1 107  26  18   1
 21   0   2   0   5   0   9 361  46   7
 24   4   1  22  22   1  17  81  69   5
  1   0   0   0   0   0   2  51   0  14
```

## Interpretation

964 correct vs baseline 983: −1.0710 pp accuracy. Macro recall declines
0.6541 pp. Beetle stays 2/85; fly_sarco improves 2→6/61; hfly_eupeo falls
72→69/246; hfly_sphaero improves 12→14/68. These small-class gains do not offset
losses elsewhere, especially fly_small and hfly_episyr. The selected-epoch gap is
smaller but both train and validation accuracy are lower; that is not evidence
of an overall quality improvement. Epoch 60 reaches 72.55% train but only 53.61%
validation, consistent with remaining generalization limitations.

A seed-123 repeat is not prioritized for promotion: both primary accuracy and
macro recall are worse than v1. A repeat could study the class trade-off, but this
single seed does not establish general inferiority or justify PTQ. Keep ColorJitter
in the frozen selected recipe; do not replace any selected-model record.

## Verification and files

Focused checks: **2 passed** (new no-jitter test plus existing resize test).
Full regression: **562 passed**. The fixture verifies only jitter is removed,
remaining transform settings and evaluation output are unchanged, and normalized
color values are preserved without jitter. Commands from repository root:

```bash
PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 /home/cgj/anaconda3/envs/pynq-cnn/bin/python -B -m pytest -c cnn_pipeline/pytest.ini -q -p no:cacheprovider cnn_pipeline/tests/test_no_color_jitter.py cnn_pipeline/tests/test_insect_resize.py
PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 /home/cgj/anaconda3/envs/pynq-cnn/bin/python -B -m pytest -c cnn_pipeline/pytest.ini -q -p no:cacheprovider cnn_pipeline/tests
```

Reloaded metrics match history; confusion support totals 1,774. All 164
inventoried existing output/documentation/data-provenance files retain their
pre-run hashes. No Git writes. `git diff --check` passed.

Modified this task: data.py, train.py (which already contained the prior smoothing
change). Added tests/test_no_color_jitter.py and this directory's README.md,
run_config.json, validation_metrics.json. New local output files: best.pt,
history.json, run_config.json, validation_metrics.json, comparison.json.
Prior experiment docs, tests, artifacts and unrelated untracked files untouched.

Checkpoint SHA256: `9695060b86a42b7253d1c6227b201f9fedd82a7b2475f3613fb1d1a9fd56f178`.
