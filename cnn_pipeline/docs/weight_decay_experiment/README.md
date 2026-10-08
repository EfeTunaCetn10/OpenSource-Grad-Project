# Stronger AdamW regularization — seed 42, 2026-10-06

Result: **do not promote**. Weight decay 1e-3 did not improve validation accuracy,
macro recall or the train–validation gap. Candidate v1 remains selected and frozen.
No test evaluation, PTQ, integer parameter generation or vector export occurred.

## Controlled configuration

Only training hyperparameter change: AdamW weight_decay 1e-4 → 1e-3.
Same RGB LeNet, split, normalization, resize/flip/ColorJitter, AdamW LR 0.001,
batch 128, cosine schedule, 60 epochs, seed 42, workers 0 and CPU/thread settings.
Checkpoint selection is maximum validation accuracy, retaining the first tie.
[Run configuration](run_config.json) is retained separately for versioning.
Training/model source hashes match the baseline. The data.py hash differs because
identical evaluation transforms were extracted into a shared helper after the
baseline run; inspection confirmed no preprocessing or augmentation change.

Exact command, from `cnn_pipeline/`:

```bash
PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 /home/cgj/anaconda3/envs/pynq-cnn/bin/python -B -u train.py --dataset insects --data-dir data/insects --stats data/insects/stats.json --output-dir outputs/resize_cosine_wd1e3_seed42_60epochs --epochs 60 --batch-size 128 --learning-rate 0.001 --weight-decay 0.001 --workers 0 --seed 42 --train-resize --scheduler cosine --skip-test
```

Existing directories must not be reused. Local output:
`cnn_pipeline/outputs/resize_cosine_wd1e3_seed42_60epochs/insects/`.

## Validation comparison

| Metric | Frozen baseline | Weight decay 1e-3 |
|---|---:|---:|
| Best epoch | 51.0000 | 60.0000 |
| Train accuracy (%) | 70.5358 | 71.5911 |
| Train loss | 0.8474 | 0.8243 |
| Validation accuracy (%) | 55.4115 | 55.3551 |
| Validation loss | 1.3351 | 1.3507 |
| Train–validation gap (pp) | 15.1243 | 16.2359 |
| Macro recall (%) | 40.3275 | 39.7441 |

Accuracy change: **−0.0564 pp**, 982 versus 983 correct out of 1,774. Macro
recall change: **−0.5834 pp**. Training metrics are online augmented-batch
measurements, not clean fixed-checkpoint train evaluation.

| Class | Baseline recall % | New recall % | Change pp |
|---|---:|---:|---:|
| bee | 57.98 | 56.38 | -1.60 |
| beetle | 2.35 | 3.53 | +1.18 |
| beetle_cocci | 56.67 | 58.33 | +1.67 |
| bug | 24.49 | 22.45 | -2.04 |
| fly | 68.59 | 68.95 | +0.36 |
| fly_sarco | 3.28 | 3.28 | +0.00 |
| fly_small | 58.08 | 58.08 | +0.00 |
| hfly_episyr | 84.92 | 85.81 | +0.89 |
| hfly_eupeo | 29.27 | 28.86 | -0.41 |
| hfly_sphaero | 17.65 | 11.76 | -5.88 |

## Confusion matrix

Rows are true labels, columns predictions; order:
`bee, beetle, beetle_cocci, bug, fly, fly_sarco, fly_small, hfly_episyr, hfly_eupeo, hfly_sphaero`.

```text
106   4   0   1  17   0  33  11  13   3
 22   3   0   0  15   0  30   6   9   0
  1  12  70  11  11   0   2   7   6   0
  0  15  14  11   1   0   0   4   4   0
  8   0   0   2 191   0  71   1   4   0
  2   0   0   0  46   2   8   0   3   0
  7   1   0   0  43   0 133  32  11   2
 12   4   1   1   4   0   6 387  27   9
 19   1   3   6  20   0  21 100  71   5
  0   1   0   0   0   0   2  56   1   8
```

## Decision and verification

Beetle improves by one correct example (2→3); fly_sarco stays at 2;
hfly_eupeo loses one (72→71); hfly_sphaero loses four (12→8). The gap widens,
so this run does not support stronger regularization as the solution. Best epoch
is the final epoch, but that alone does not justify extending training or changing
the fixed comparison budget. This is one seed, not proof of universal inferiority.
A second-seed confirmation is not prioritized: there is no clear gain to confirm.
Do not proceed to PTQ or promote this checkpoint on current evidence.

The saved checkpoint was reloaded and evaluated on validation only using the
shared transform and existing evaluate_with_macro_recall helper. Accuracy and
loss reproduce the selected history row; matrix support totals 1,774. Existing
86 output/provenance files matched their pre-run SHA256 hashes afterward.
No code or tests changed; no regression suite was needed or run. No Git writes.

Created local files: best.pt, history.json, run_config.json,
validation_metrics.json and comparison.json (all in the new output directory).
The latter records configuration differences and the frozen-source hash inventory.
This documentation directory contains README.md, run_config.json and
validation_metrics.json; no existing reports were edited.

Checkpoint SHA256: `3074593fe20249f46c7e5a96d45f71224d90ed2ac74c497d642d8e89b4751b7b`.
