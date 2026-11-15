"""Padded tile-major INT8 2x2 stride-2 max pooling."""

from __future__ import annotations


def pool2x2(x: list[int], h: int, w: int, c: int) -> list[int]:
    """Pool each eight-channel tile in HWC order, including padding lanes."""
    if h <= 0 or w <= 0 or h % 2 or w % 2 or c <= 0:
        raise ValueError("h and w must be positive and even; c must be positive")
    padded_c = ((c + 7) // 8) * 8
    if len(x) != h * w * padded_c:
        raise ValueError("input length does not match padded tile-major shape")
    if any(v < -128 or v > 127 for v in x):
        raise ValueError("input values must be INT8")
    out: list[int] = []
    for tile in range(padded_c // 8):
        base = tile * h * w * 8
        for row in range(0, h, 2):
            for col in range(0, w, 2):
                for lane in range(8):
                    out.append(max(
                        x[base + ((row + dr) * w + col + dc) * 8 + lane]
                        for dr in range(2) for dc in range(2)
                    ))
    return out
