#!/usr/bin/env python3
"""faz4 lane C system smoke vectors (scratch, not committed).

Python chain for v3 conv1 -> conv2 -> conv3 with synthetic deterministic
weights/params.  Primitives are copied from
C:/codex-ctx/2026-11-05/arsiv/probe/runtime_geometry_ref.py (requant_ref,
the conv reduction order k = ci*kh*kw + ky*kw + kx, pool2x2 max).

  L1: 48x48x3  (s_* stream, c_phys 3)  conv3x3 p1 -> 16 ch (2 tiles), pool -> 24x24x16
  L2: 24x24x16 (act_buffer, c_phys 16) conv3x3 p1 -> 24 ch (3 tiles), pool -> 12x12x24
  L3: 12x12x24 (act_buffer, c_phys 24) conv3x3 p1 -> 32 ch (4 tiles), no pool -> m_*

Outputs (hex, one value per line) in scratch/smoke/vec/.
"""

from __future__ import annotations

import math
import random
from pathlib import Path

OUT = Path(__file__).resolve().parent / "vec"
ROWS = 8
W_BASES = {"l1": 0, "l2": 64, "l3": 512}


def wrap32(v: int) -> int:
    v &= 0xFFFFFFFF
    return v - (1 << 32) if v & 0x80000000 else v


def requant_ref(acc: int, m0: int, n: int, relu: bool) -> int:
    half = 0 if n == 0 else 1 << (n - 1)
    raw = (acc * m0 + half) >> n
    return max(0 if relu else -128, min(127, raw))


def conv(x, h, w, c_in, weights, kh=3, kw=3, pad=1):
    """x[h][w][c] -> acc[oh][ow][oc]; reduction order of window_gen."""
    oh_n, ow_n = h + 2 * pad - kh + 1, w + 2 * pad - kw + 1
    out = []
    for oh in range(oh_n):
        row = []
        for ow in range(ow_n):
            accs = []
            for wo in weights:
                acc = 0
                for ci in range(c_in):
                    for ky in range(kh):
                        ih = oh - pad + ky
                        if not 0 <= ih < h:
                            continue
                        for kx in range(kw):
                            iw = ow - pad + kx
                            if 0 <= iw < w:
                                acc = wrap32(acc + x[ih][iw][ci] * wo[ci * kh * kw + ky * kw + kx])
                accs.append(acc)
            row.append(accs)
        out.append(row)
    return out


def requant_layer(acc, params):
    bias, m0, shift, relu = params
    return [[[requant_ref(wrap32(a + bias[c]), m0[c], shift[c], relu[c])
              for c, a in enumerate(px)] for px in row] for row in acc]


def pool(x):
    h, w = len(x), len(x[0])
    return [[[max(x[2 * r + dr][2 * c + dc][ch] for dr in range(2) for dc in range(2))
              for ch in range(len(x[0][0]))] for c in range(w // 2)] for r in range(h // 2)]


def word(vals):
    return sum((v & 0xFF) << (8 * i) for i, v in enumerate(vals))


def write(name, vals, bits):
    mask, width = (1 << bits) - 1, (bits + 3) // 4
    (OUT / name).write_text("".join(f"{v & mask:0{width}X}\n" for v in vals), encoding="ascii")


def tile_plane_words(y, t):
    """Raster words of output tile t (lane r = channel 8t+r)."""
    return [word(px[8 * t:8 * t + 8]) for row in y for px in row]


def main() -> None:
    OUT.mkdir(exist_ok=True)
    rng = random.Random(20261106)
    h1 = 48
    x1 = [[[rng.randint(-128, 127) for _ in range(3)] for _ in range(h1)] for _ in range(h1)]
    frame = [v for row in x1 for px in row for v in px]
    write("l1_frame.mem", [word(frame[i:i + 8]) for i in range(0, len(frame), 8)], 64)

    banks = [[0] * 2048 for _ in range(ROWS)]
    layers = (("l1", 3, 16, True), ("l2", 16, 24, True), ("l3", 24, 32, False))
    x, h = x1, h1
    for tag, c_in, c_out, do_pool in layers:
        k_len = c_in * 9
        weights = [[rng.randint(-128, 127) for _ in range(k_len)] for _ in range(c_out)]
        bias = [rng.randint(-6000, 6000) for _ in range(c_out)]
        m0 = [rng.randrange((1 << 16) + 1, (1 << 17) - 1) for _ in range(c_out)]
        shift = [26 + (c % 3) for c in range(c_out)]
        relu = [int(c % 4 == 3) for c in range(c_out)]
        for oc in range(c_out):
            t, r = divmod(oc, ROWS)
            base = W_BASES[tag] + t * k_len
            banks[r][base:base + k_len] = weights[oc]
        write(f"{tag}_bias.mem", bias, 32)
        write(f"{tag}_m0.mem", m0, 18)
        write(f"{tag}_shift.mem", shift, 6)
        write(f"{tag}_relu.mem", relu, 1)
        y = requant_layer(conv(x, h, h, c_in, weights), (bias, m0, shift, relu))
        if do_pool:
            y = pool(y)
        tiles = c_out // ROWS
        words = [w for t in range(tiles) for w in tile_plane_words(y, t)]
        write(f"{tag}_y.mem", words, 64)   # tile-major: what act_buffer stores
        flat = [v for row in y for px in row for v in px]
        print(f"{tag}: {h}x{h}x{c_in} -> {len(y)}x{len(y[0])}x{c_out} tiles={tiles} "
              f"words={len(words)} y=[{min(flat)},{max(flat)}] "
              f"zeros={flat.count(0)} sat={flat.count(127) + flat.count(-128)}")
        x, h = y, len(y)
    for r in range(ROWS):
        write(f"wbank{r}.mem", banks[r], 8)


def gen_chain(name, rng, x, h, layers):
    """Pure-Python chain for the S5/S6 smokes.  layers: (tag, kind, c_in, kh,
    kw, pad, c_out, do_pool, w_base).  Writes weights (all 8 banks, W_BASE
    offsets), per-layer params, the stored tile-major result and the s_*
    frame.  Weights/params of the unused output rows of the last tile are
    junk on purpose (the lane mask must zero them).  M0 in [65536,131071];
    the shift per channel is calibrated from the layer's own accumulator
    spread so outputs land around +-20..45 and do not saturate."""
    banks = [[0] * 8192 for _ in range(ROWS)]
    frame = [v for row in x for px in row for v in px]
    write(f"{name}_frame.mem", [word(frame[i:i + 8]) for i in range(0, len(frame), 8)], 64)
    for ti, (tag, kind, c_in, kh, kw, pad, c_out, do_pool, w_base) in enumerate(layers):
        if kind == "fc":
            flat = [v for row in x for px in row for v in px]   # (h, w, c) order
            assert len(flat) == c_in, (tag, len(flat), c_in)
            x, h = [[flat]], 1
        k_len = c_in * kh * kw
        tiles = (c_out + ROWS - 1) // ROWS
        weights = [[rng.randint(-100, 100) for _ in range(k_len)] for _ in range(tiles * ROWS)]
        for oc in range(tiles * ROWS):
            t, r = divmod(oc, ROWS)
            base = w_base + t * k_len
            banks[r][base:base + k_len] = weights[oc]
        assert w_base + tiles * k_len <= 8192
        acc = conv(x, h, h, c_in, weights[:c_out], kh, kw, pad)
        flat_acc = [a for row in acc for px in row for a in px]
        mean = sum(flat_acc) / len(flat_acc)
        std = max(1.0, (sum((a - mean) ** 2 for a in flat_acc) / len(flat_acc)) ** 0.5)
        last = ti == len(layers) - 1
        nch = tiles * ROWS
        bias = [rng.randint(-int(std // 2), int(std // 2)) for _ in range(nch)]
        m0 = [rng.randrange(1 << 16, 1 << 17) for _ in range(nch)]
        target = [20 + 8 * (c % 4) for c in range(nch)]
        shift = [max(1, round(math.log2(std * m0[c] / target[c]))) for c in range(nch)]
        relu = [0 if last else int(c % 4 == 3) for c in range(nch)]
        write(f"{name}_{tag}_bias.mem", bias, 32)
        write(f"{name}_{tag}_m0.mem", m0, 18)
        write(f"{name}_{tag}_shift.mem", shift, 6)
        write(f"{name}_{tag}_relu.mem", relu, 1)
        y = requant_layer(acc, (bias, m0, shift, relu))
        if do_pool:
            y = pool(y)
        words = [w for t in range(tiles) for w in tile_plane_words(y, t)]
        write(f"{name}_{tag}_y.mem", words, 64)
        vals = [v for row in y for px in row for v in px]
        sat = vals.count(127) + vals.count(-128)
        print(f"{name} {tag}: {len(y)}x{len(y[0])}x{c_out} tiles={tiles} words={len(words)} "
              f"acc_std={std:.0f} y=[{min(vals)},{max(vals)}] zeros={vals.count(0)}/{len(vals)} "
              f"sat={sat}")
        assert vals.count(0) < 0.7 * len(vals) and sat < 0.1 * len(vals), tag
        x, h = y, len(y)
    for r in range(ROWS):
        write(f"{name}_wbank{r}.mem", banks[r], 8)


def gen_s56() -> None:
    # S5: LeNet-5 INT8 chain.  conv1 5x5 c_in3 -> 6 (lanes 6,7 padded/zero),
    # conv2 5x5 c_in6 (c_phys 8) -> 16, fc1 400 -> 120 (h,w,c flatten), fc2
    # 120 -> 84, fc3 84 -> 10.
    rng = random.Random(20261107)
    x = [[[rng.randint(-128, 127) for _ in range(3)] for _ in range(32)] for _ in range(32)]
    gen_chain("s5", rng, x, 32, [
        ("c1", "conv", 3, 5, 5, 0, 6, True, 0),
        ("c2", "conv", 6, 5, 5, 0, 16, True, 75),
        ("f1", "fc", 400, 1, 1, 0, 120, False, 375),
        ("f2", "fc", 120, 1, 1, 0, 84, False, 6375),
        ("f3", "fc", 84, 1, 1, 0, 10, False, 7695),
    ])
    # S6: v3 tail.  conv4 12x12x32 -> 32 (pool), conv5 6x6 -> 32 (pool),
    # fc1 288 -> 64 (h,w,c), fc2 64 -> 10.
    rng = random.Random(20261108)
    x = [[[rng.randint(-128, 127) for _ in range(32)] for _ in range(12)] for _ in range(12)]
    gen_chain("s6", rng, x, 12, [
        ("c4", "conv", 32, 3, 3, 1, 32, True, 0),
        ("c5", "conv", 32, 3, 3, 1, 32, True, 1152),
        ("f1", "fc", 288, 1, 1, 0, 64, False, 2304),
        ("f2", "fc", 64, 1, 1, 0, 10, False, 4608),
    ])


if __name__ == "__main__":
    main()
    gen_s56()
