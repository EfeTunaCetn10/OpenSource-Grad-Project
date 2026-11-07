#!/usr/bin/env python3
"""Vectors for tb_v3_e2e: the full frozen v3 network through accel_top.

  conv1 3->16 3x3 p1 (48x48, s_*) ReLU + pool -> 24x24x16
  conv2 16->24 + pool -> 12x12x24      conv3 24->32 (no pool) -> 12x12x32
  conv4 32->32 + pool -> 6x6x32        conv5 32->32 + pool -> 3x3x32
  fc1 288->64 (1x1, c_phys 288, k=(h*3+w)*32+c) ReLU    fc2 64->10 (signed, no ReLU)

Weights and requant params are synthetic and deterministic (fixed-seed random.Random).
The per-channel shift is calibrated from image 0's accumulator spread so activations
land around 20..45 instead of collapsing or saturating; every image is checked against
the same range rules.  conv2..conv5 use ReLU on even channels only, so signed
activations also travel through the chain.  Writes sim/vectors/v3e_*.mem.
"""

from __future__ import annotations

import math
import random
from pathlib import Path

from v3_ref import (ROWS, argmax_first, conv, flatten_hwc, pack_word, pool2x2,
                    requant_layer, tile_major_words)

VECTORS = Path(__file__).resolve().parent.parent / "sim" / "vectors"
NIMG = 3   # images kept: distinct predicted classes, first found
CLASSES = 10
# tag, kind, c_in, kh, kw, pad, c_out, pool, relu_mode (all/mix/none)
LAYERS = [
    ("c1", "conv", 3, 3, 3, 1, 16, True, "all"),
    ("c2", "conv", 16, 3, 3, 1, 24, True, "mix"),
    ("c3", "conv", 24, 3, 3, 1, 32, False, "mix"),
    ("c4", "conv", 32, 3, 3, 1, 32, True, "mix"),
    ("c5", "conv", 32, 3, 3, 1, 32, True, "mix"),
    ("f1", "fc", 288, 1, 1, 0, 64, False, "all"),
    ("f2", "fc", 64, 1, 1, 0, CLASSES, False, "none"),
]


def write(name, vals, bits):
    mask, width = (1 << bits) - 1, (bits + 3) // 4
    (VECTORS / name).write_text("".join(f"{v & mask:0{width}X}\n" for v in vals), encoding="ascii")


def build_net(rng, x0):
    """Weights, params (calibrated on x0) and the W_BASE offsets."""
    net, x, h, base = [], x0, len(x0), 0
    for tag, kind, c_in, kh, kw, pad, c_out, do_pool, relu_mode in LAYERS:
        if kind == "fc":
            x, h = [[flatten_hwc(x)]], 1
            assert len(x[0][0]) == c_in
        k_len = c_in * kh * kw
        tiles = (c_out + ROWS - 1) // ROWS
        nch = tiles * ROWS
        # rows past c_out (last fc2 tile) hold junk on purpose: the lane mask must zero them
        weights = [[rng.randint(-100, 100) for _ in range(k_len)] for _ in range(nch)]
        acc = conv(x, h, len(x[0]), c_in, weights[:c_out], kh, kw, pad)
        flat = [a for row in acc for px in row for a in px]
        mean = sum(flat) / len(flat)
        std = max(1.0, (sum((a - mean) ** 2 for a in flat) / len(flat)) ** 0.5)
        bias = [rng.randint(-int(std // 2), int(std // 2)) for _ in range(nch)]
        m0 = [rng.randrange(1 << 16, 1 << 17) for _ in range(nch)]
        target = [20 + 8 * (c % 4) for c in range(nch)]
        shift = [max(1, round(math.log2(std * m0[c] / target[c]))) for c in range(nch)]
        relu = [{"all": 1, "none": 0, "mix": int(c % 2 == 0)}[relu_mode] for c in range(nch)]
        net.append(dict(tag=tag, kind=kind, c_in=c_in, kh=kh, kw=kw, pad=pad, c_out=c_out,
                        pool=do_pool, tiles=tiles, k_len=k_len, w_base=base, weights=weights,
                        bias=bias, m0=m0, shift=shift, relu=relu))
        base += tiles * k_len
        y = requant_layer(acc, bias, m0, shift, relu)
        x = pool2x2(y) if do_pool else y
        h = len(x)
    assert base <= 8192, base
    return net


def run_net(net, x0):
    """Per-layer (activation, tile-major words) and the logits."""
    outs, x, h = [], x0, len(x0)
    for L in net:
        if L["kind"] == "fc":
            x, h = [[flatten_hwc(x)]], 1
        acc = conv(x, h, len(x[0]), L["c_in"], L["weights"][:L["c_out"]], L["kh"], L["kw"], L["pad"])
        y = requant_layer(acc, L["bias"], L["m0"], L["shift"], L["relu"])
        x = pool2x2(y) if L["pool"] else y
        h = len(x)
        outs.append((x, tile_major_words(x, L["c_out"])))
    return outs, flatten_hwc(outs[-1][0])


def clip8(v):
    return max(-128, min(127, v))


def candidate_image(k):
    """Deterministic structured images: noise on top of a style-dependent low-frequency pattern."""
    rng = random.Random(7000 + k)
    style = k % 4
    ph = [rng.randint(0, 47) for _ in range(3)]
    def px(r, c, ch):
        if style == 0:
            base = 0
        elif style == 1:
            base = 90 if ((c + ph[ch]) // 6) % 2 else -90          # vertical stripes
        elif style == 2:
            base = (r * 5 - 120) if ch != 1 else (c * 5 - 120)     # gradients
        else:
            base = 100 if ((r // 12) + (c // 12) + ch) % 2 else -100  # blocks
        return clip8(base + rng.randint(-60, 60))
    return [[[px(r, c, ch) for ch in range(3)] for c in range(48)] for r in range(48)]


def healthy(outs, logits):
    """No layer collapses to zeros or saturates; the logits are spread."""
    for (y, _), L in zip(outs[:-1], LAYERS):
        vals = [v for row in y for px in row for v in px]
        sat = vals.count(127) + vals.count(-128)
        if vals.count(0) >= 0.75 * len(vals) or sat >= 0.1 * len(vals):
            return False
    return len(set(logits)) > 3 and max(logits) - min(logits) >= 10


def main() -> None:
    VECTORS.mkdir(parents=True, exist_ok=True)
    rng = random.Random(20261109)
    cands = [candidate_image(k) for k in range(16)]
    net = build_net(rng, cands[0])
    images, seen = [], set()
    for img in cands:   # first healthy candidates whose predicted classes are new
        outs, logits = run_net(net, img)
        pred = argmax_first(logits)
        if pred not in seen and len(images) < NIMG and healthy(outs, logits):
            seen.add(pred)
            images.append(img)

    banks = [[0] * 8192 for _ in range(ROWS)]
    for L in net:
        for oc in range(L["tiles"] * ROWS):
            t, r = divmod(oc, ROWS)
            b = L["w_base"] + t * L["k_len"]
            banks[r][b:b + L["k_len"]] = L["weights"][oc]
        tag = L["tag"]
        write(f"v3e_{tag}_bias.mem", L["bias"], 32)
        write(f"v3e_{tag}_m0.mem", L["m0"], 18)
        write(f"v3e_{tag}_shift.mem", L["shift"], 6)
        write(f"v3e_{tag}_relu.mem", L["relu"], 1)
        assert all(65536 <= m <= 131071 for m in L["m0"])
    for r in range(ROWS):
        write(f"v3e_wbank{r}.mem", banks[r], 8)
    print("W_BASE:", {L["tag"]: L["w_base"] for L in net},
          "end", net[-1]["w_base"] + net[-1]["tiles"] * net[-1]["k_len"])

    preds = []
    for i, img in enumerate(images):
        frame = [v for row in img for px in row for v in px]
        write(f"v3e_img{i}_frame.mem", [pack_word(frame[j:j + 8]) for j in range(0, len(frame), 8)], 64)
        outs, logits = run_net(net, img)
        for L, (y, words) in zip(net, outs):
            write(f"v3e_img{i}_{L['tag']}_y.mem", words, 64)
            vals = [v for row in y for px in row for v in px]
            sat = vals.count(127) + vals.count(-128)
            print(f"img{i} {L['tag']}: {len(y)}x{len(y[0])}x{L['c_out']} words={len(words)} "
                  f"y=[{min(vals)},{max(vals)}] zeros={vals.count(0)}/{len(vals)} sat={sat}")
        assert healthy(outs, logits), i
        pred = argmax_first(logits)
        write(f"v3e_img{i}_pred.mem", [pred], 8)
        preds.append(pred)
        print(f"img{i} logits={logits} pred={pred}")
    print("predicted classes:", preds, "distinct:", len(set(preds)))
    assert len(set(preds)) >= 2, "need at least two distinct predicted classes"


if __name__ == "__main__":
    main()
