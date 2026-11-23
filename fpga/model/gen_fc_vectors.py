#!/usr/bin/env python3
"""Generate deterministic FC1 XSim vectors in sim/vectors/fc1_*.mem."""

from __future__ import annotations

import random
from pathlib import Path

from fc_ref import fc1_tile_major, fc_accumulators, fc_layer, tile_major_index

ROOT = Path(__file__).resolve().parent.parent
VECTORS = ROOT / "sim" / "vectors"
K = 400
OUT = 120
ROWS = 8
TILES = 15


def write_mem(name: str, values: list[int], bits: int) -> None:
    width = (bits + 3) // 4
    mask = (1 << bits) - 1
    (VECTORS / name).write_text(
        "".join(f"{value & mask:0{width}X}\n" for value in values),
        encoding="ascii",
    )


def packed_bytes(values: list[int]) -> int:
    return sum((v & 255) << (8 * i) for i, v in enumerate(values))


def main() -> None:
    assert tile_major_index(8, 1, 0) == 240
    rng = random.Random(20261009)
    dense_x = [rng.randint(-128, 127) for _ in range(K)]
    dense_w = [rng.randint(-128, 127) for _ in range(OUT * K)]
    x = fc1_tile_major(dense_x)
    w = fc1_tile_major(dense_w, OUT)
    assert x[240] == dense_x[8 * 25 + 5]
    assert all(w[o*K + 240] == dense_w[o*K + 8*25 + 5] for o in range(OUT))

    bias = [rng.randint(-5000, 5000) for _ in range(ROWS)]
    m0 = [rng.randrange((1 << 16) + 1, (1 << 17) - 1, 2)
          for _ in range(ROWS)]
    shift = [26 + (r % 2) for r in range(ROWS)]
    relu = [int(r in (2, 5)) for r in range(ROWS)]
    acc = fc_accumulators(x, w, K, OUT)
    y = fc_layer(x, w, bias, m0, shift, [bool(v) for v in relu], K, OUT)
    assert min(y) <= -100 and max(y) >= 100, (min(y), max(y))

    VECTORS.mkdir(parents=True, exist_ok=True)
    write_mem("fc1_dims.mem", [K, OUT, TILES, 50], 32)
    write_mem("fc1_frame.mem", [packed_bytes(x[i:i+8])
                                  for i in range(0, K, 8)], 64)
    for r in range(ROWS):
        write_mem(f"fc1_wbank{r}.mem",
                  [w[(a // K * ROWS + r)*K + a % K]
                   for a in range(TILES * K)], 8)
    write_mem("fc1_bias.mem", bias, 32)
    write_mem("fc1_m0.mem", m0, 18)
    write_mem("fc1_shift.mem", shift, 6)
    write_mem("fc1_relu.mem", relu, 1)
    write_mem("fc1_acc.mem", acc, 32)
    write_mem("fc1_y.mem", [packed_bytes(y[i:i+8])
                            for i in range(0, OUT, ROWS)], 64)
    print(f"PASS gen_fc_vectors: {TILES} tiles, K={K}, y=[{min(y)},{max(y)}]")


if __name__ == "__main__":
    main()
