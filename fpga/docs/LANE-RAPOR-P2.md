# LANE-RAPOR-P2 -- full frozen v3 network through accel_top (R2)

Branch `lane/p2-v3e2e`, worktree `C:\grad-wt\p2`, base `faz5-test` @ 8820c73. No RTL changed.

## Files

| File | Change |
| --- | --- |
| `systolic-array-8x8/tb/tb_v3_e2e.sv` | NEW. PS-style driver, 2 images, 7 layers. |
| `systolic-array-8x8/model/gen_v3_e2e_vectors.py` | NEW. Golden, pure Python, writes `sim/vectors/v3e_*.mem`. |
| `systolic-array-8x8/model/v3_ref.py` | NEW. Helpers (conv, pool, requant via `requant_ref`, packing, argmax). |
| `systolic-array-8x8/sim/run_tests.py` | One line added to `VECTOR_GENERATORS` (orchestrator merges). |

Regression line (insert after the `gen_fc_vectors.py` entry, before the "must stay LAST" lenet entry):

    ("gen_v3_e2e_vectors.py", "v3e_img0_pred.mem"),

## Network and driving

conv1 3->16 (s_*, c_phys 3, re-sent per tile, 2 tiles, pool) -> conv2 16->24 (3 tiles, pool) -> conv3 24->32 (4 tiles) -> conv4 32->32 (4 tiles, pool) -> conv5 32->32 (4 tiles, pool) -> fc1 288->64 (1x1, c_phys 288, k=(h*3+w)*32+c, 8 tiles, ReLU) -> fc2 64->10 (2 tiles, last_rows 2, no ReLU, m_*). Output sizes 24x24, 12x12, 12x12, 6x6, 3x3, 1x1.

Per tile: LAYER_CFG, c_phys (LAYER_CFG2), W_BASE, TILE_CFG, DP_CFG, 24 param words, COMMIT, START, poll STATUS until DONE, W1C DONE; LAYER_SWAP after each layer. After each layer ERROR and ERR_DETAIL are read (must be 0), and STATUS must be DONE without ERROR/ABORTED on every pass. Weights loaded once via w_wr_* while idle, W_BASE c1 0, c2 54, c3 486, c4 1350, c5 2502, f1 3654, f2 5958, end 6086 bytes per bank. s_valid/m_ready paced by LFSRs.

## Golden / weights

Weights uniform INT8 [-100,100], M0 in [65536,131071], bias in +-std/2, shift per channel calibrated from image 0's accumulator spread (target 20..44). ReLU: conv1 and fc1 all channels, conv2..conv5 even channels only (so signed activations travel through the chain), fc2 none. Junk weights/params in fc2 rows 10..15 (lane mask must zero them). Images: 16 deterministic structured candidates (noise on stripes/gradients/blocks); pure-noise images all gave class 9, so structured ones were used. Kept: the first candidates that pass the health rule (zeros < 75%, saturation < 10% per layer, spread logits) and have a new predicted class. Result: 2 images (classes 3 and 8); no third distinct class among the 16 candidates.

Ranges (generator output): img0 c1 [0,127] sat 20, c2 [-111,106], c3 [-128,121] sat 7, c4 [-113,117], c5 [-42,127] sat 6, f1 [0,75] zeros 31/64, logits [28,29,-6,73,6,17,25,-50,51,20] pred 3. img1 c1 [0,127] sat 10, f1 zeros 31/64, logits [26,26,-4,44,7,16,13,-40,45,18] pred 8 (margin 1).

## Result

    tb_v3_e2e PASS
    img0: predicted class 3 (expected 3), logits[pred]=73
    img1: predicted class 8 (expected 8), logits[pred]=45
    PASS tb_v3_e2e: 2 images, 54 passes, 4696 act_buffer words + logits bit-exact, FRAME_COUNT=54

Boundaries compared per image: act_buffer after conv1 (1152 words), conv2 (432), conv3 (576), conv4 (144), conv5 (36), fc1 (8) = 2348 words word-by-word (2 x 2348 = 4696), plus both m_* logit beats (m_last position and beat count) and the argmax class computed in the TB from the m_* bytes (first index on ties) vs the golden class. Passed on the first run; no RTL or test defect found.

Regression: `python sim/run_tests.py` -> `17/17 passed` (4m35s total). Smoke not re-run (no RTL change).

Wall time of tb_v3_e2e: 90 s XSim run (23.7 ms simulated, 2.37M cycles), 1m43s incl. compile/elab; generator about 13 s (it runs 16 candidate images through the Python net).

## Mutations (scratch copies, not committed, copies removed)

1. RTL: `requant_unit.sv` half-ULP rounding offset forced to 0 -> FAIL at img0 c1 bank (1148 of 1152 words differ), later layers also.
2. Reference: `flatten_hwc` in `v3_ref.py` changed to channel-major (c,h,w) for the fc1 input -> `FAIL tb_v3_e2e: errors=11`.

## Open questions

- Only 2 distinct classes were found; a third image with a new class would need a larger candidate search (change `range(16)`).
- img1 argmax margin is 1 (45 vs 44): fine for a bit-exact compare, weak as a "class" statement.
- Synthetic weights, not the real trained v3 model; relu pattern for conv2..5 (even channels) is my choice, the brief only fixed conv1 and fc1.
- conv1 accumulation of all-channel structured images can saturate; the health rule skips such candidates.
