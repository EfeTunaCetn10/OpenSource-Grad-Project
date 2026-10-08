# Training-only label smoothing 0.05 — seed 42

Candidate v1 remains frozen. Result: a small overall accuracy gain, lower
unsmoothed validation loss, but worse macro recall and no target minority-class
improvement relative to baseline. Do not promote or proceed to PTQ on this evidence.

Only training setting changed: cross-entropy label_smoothing 0 → 0.05.
Validation retains ordinary unsmoothed cross-entropy. Weight decay is 1e-4,
not the preceding experiment's 1e-3. All other settings match the selected recipe.
The zero-default CLI option preserves existing behavior. Selection remains maximum
validation accuracy, first tie retained. The shared data transform refactor is
behavior-preserving; source hash differences are recorded in comparison.json.

## Exact command

From `cnn_pipeline/`, with a new output directory:

```bash
PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 /home/cgj/anaconda3/envs/pynq-cnn/bin/python -B -u train.py --dataset insects --data-dir data/insects --stats data/insects/stats.json --output-dir outputs/resize_cosine_ls005_seed42_60epochs --epochs 60 --batch-size 128 --learning-rate 0.001 --weight-decay 0.0001 --label-smoothing 0.05 --workers 0 --seed 42 --train-resize --scheduler cosine --skip-test
```

Local output: `cnn_pipeline/outputs/resize_cosine_ls005_seed42_60epochs/insects/`.
All 60 epochs completed; the epoch-50 checkpoint was independently reloaded and
evaluated on all 1,774 validation images. No test inference or tuning occurred.

## Comparison

| Metric | Frozen baseline | WD 1e-3 | Smoothing 0.05 |
|---|---:|---:|---:|
| Best epoch | 51.0000 | 60.0000 | 50.0000 |
| Train accuracy % | 70.5358 | 71.5911 | 71.2759 |
| Train loss | 0.8474 | 0.8243 | 1.0233 |
| Validation accuracy % | 55.4115 | 55.3551 | 55.5242 |
| Validation loss | 1.3351 | 1.3507 | 1.3124 |
| Train–validation gap pp | 15.1243 | 16.2359 | 15.7516 |
| Macro recall % | 40.3275 | 39.7441 | 39.5734 |

Smoothed training loss is a different objective and must not be compared directly
with the earlier unsmoothed training losses. Train accuracy is measured online on
augmented batches, not a clean fixed-checkpoint train evaluation.

| Class | Baseline recall % | WD recall % | Smoothing recall % | Δ vs baseline pp |
|---|---:|---:|---:|---:|
| bee | 57.98 | 56.38 | 53.72 | -4.26 |
| beetle | 2.35 | 3.53 | 2.35 | +0.00 |
| beetle_cocci | 56.67 | 58.33 | 55.83 | -0.83 |
| bug | 24.49 | 22.45 | 22.45 | -2.04 |
| fly | 68.59 | 68.95 | 71.48 | +2.89 |
| fly_sarco | 3.28 | 3.28 | 3.28 | +0.00 |
| fly_small | 58.08 | 58.08 | 55.02 | -3.06 |
| hfly_episyr | 84.92 | 85.81 | 88.03 | +3.10 |
| hfly_eupeo | 29.27 | 28.86 | 28.86 | -0.41 |
| hfly_sphaero | 17.65 | 11.76 | 14.71 | -2.94 |

## Confusion matrix

Rows=true, columns=predicted. Order: `bee, beetle, beetle_cocci, bug, fly, fly_sarco, fly_small, hfly_episyr, hfly_eupeo, hfly_sphaero`.

```text
101   2   0   1  18   1  31  13  18   3
 18   2   0   0  15   0  32   7  10   1
  1  10  67  13  13   0   1  10   5   0
  0  10  16  11   2   0   0   7   3   0
  8   0   0   1 198   2  62   2   4   0
  3   1   0   0  46   2   7   0   2   0
  8   1   0   1  43   0 126  35  13   2
  8   3   2   1   1   0   5 397  29   5
 13   3   3   6  17   0  19 109  71   5
  0   0   0   0   0   0   2  55   1  10
```

## Interpretation

985 correct vs baseline 983 and WD 982: +0.1127 pp and +0.1691 pp respectively.
Macro recall drops 0.7542 pp vs baseline and 0.1707 pp vs WD. Beetle and fly_sarco
remain 2 correct each; hfly_eupeo falls 72→71 and hfly_sphaero 12→10 vs baseline.
The latter improves over WD's 8, but not over v1. Gains concentrate in fly and
hfly_episyr, while bee and fly_small lose correct predictions. The accuracy gap
also widens relative to baseline; lower validation CE does not establish a better
balanced classifier or calibrated probabilities.

A seed-123 confirmation is optional if the tiny top-1/loss gain is worth studying,
but is not prioritized as a promotion step given the macro/minority regression.
One seed cannot establish robustness; no PTQ or candidate replacement recommended.

## Verification and inventory

Six focused tests passed; full suite **561 passed**. Tests independently calculate
the smoothed target loss, check unsmoothed validation and zero-default equivalence,
and reject invalid smoothing values. Commands from repository root:

```bash
PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 /home/cgj/anaconda3/envs/pynq-cnn/bin/python -B -m pytest -c cnn_pipeline/pytest.ini -q -p no:cacheprovider cnn_pipeline/tests/test_label_smoothing.py
PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 /home/cgj/anaconda3/envs/pynq-cnn/bin/python -B -m pytest -c cnn_pipeline/pytest.ini -q -p no:cacheprovider cnn_pipeline/tests
```

Reloaded validation accuracy/loss matches history and matrix totals 1,774.
All 156 inventoried pre-existing output/documentation/data-provenance files retained
their SHA256 values. No frozen checkpoint/qparams/golden/vector/report was changed.
No Git write, test-split evaluation, quantization or vector generation occurred.

Modified: train.py. Added: tests/test_label_smoothing.py and this documentation
folder's README.md, run_config.json and validation_metrics.json. New local run:
best.pt, history.json, run_config.json, validation_metrics.json, comparison.json.
Previous weight-decay documentation and unrelated untracked files were untouched.

Checkpoint SHA256: `a278233885b53dc6ad95cbab0db448e9e942c76ab4d6d058402ba5a3c48f534f`.
