#!/usr/bin/env python3
"""Deterministic pool vectors: one 64-bit pixel beat per line, lane 0 low."""

from __future__ import annotations

import random
from pathlib import Path

from pool_ref import pool2x2

PROJECT = Path(__file__).resolve().parent.parent
VECTOR_DIR = PROJECT / "sim" / "vectors"


def pack_le(lanes: list[int]) -> str:
    if len(lanes) != 8 or any(v < -128 or v > 127 for v in lanes):
        raise ValueError("beat must have eight INT8 lanes")
    return f"{sum((v & 255) << (8 * i) for i, v in enumerate(lanes)):016X}"


def write(name: str, values: list[int]) -> None:
    path = VECTOR_DIR / name
    lines = [pack_le(values[i:i + 8]) for i in range(0, len(values), 8)]
    path.write_text("\n".join(lines) + "\n", encoding="ascii")
    print(f"  {name}: {len(lines)} beats")


def fixture(h: int, w: int, c: int, seed: int) -> list[int]:
    rng = random.Random(seed)
    tiles = (c + 7) // 8
    x = [rng.randint(-128, 127) for _ in range(tiles * h * w * 8)]
    for tile in range(tiles):
        for dr in range(2):
            for dc in range(2):
                p = (tile * h * w + dr * w + dc) * 8
                x[p + ((dr * 2 + dc) % 8)] = 127
                x[p + ((dr * 2 + dc + 4) % 8)] = -128
    return x


def main() -> None:
    VECTOR_DIR.mkdir(parents=True, exist_ok=True)
    for tag, h, w, c, seed in (("p1", 28, 28, 6, 20261009),
                               ("p2", 10, 10, 16, 20261010)):
        x = fixture(h, w, c, seed)
        y = pool2x2(x, h, w, c)
        print(f"{tag}: {h}x{w}x{c} -> {h//2}x{w//2}x{c}")
        write(f"{tag}_frame.mem", x)
        write(f"{tag}_y.mem", y)


if __name__ == "__main__":
    main()
