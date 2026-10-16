#!/usr/bin/env python3
"""Generate the XSim $readmemh vectors for T_NUM_REQ_001.

The reference arithmetic remains in requant_ref.py. This file only chooses
coverage, applies the explicitly specified bias/bypass wrapper semantics, and
serializes signed values as fixed-width two's-complement hexadecimal words.
"""

from __future__ import annotations

from pathlib import Path
import sys

MODEL_DIR = Path(__file__).resolve().parent
PROJECT = MODEL_DIR.parent
VECTOR_DIR = PROJECT / "sim" / "vectors"
sys.path.insert(0, str(MODEL_DIR))

from requant_ref import (  # noqa: E402
    ACC_HI,
    ACC_LO,
    all_test_accs,
    requant_raw_ref,
    requant_ref,
)


def wrap32(value: int) -> int:
    value &= 0xFFFFFFFF
    return value - (1 << 32) if value & (1 << 31) else value


def signed_hex(value: int, width: int) -> str:
    """Fixed-width two's-complement encoding, suitable for $readmemh."""
    if value < -(1 << (width - 1)) or value >= (1 << (width - 1)):
        raise ValueError(f"{value} does not fit signed {width}-bit word")
    return f"{value & ((1 << width) - 1):0{(width + 3) // 4}X}"


def unsigned_hex(value: int, width: int) -> str:
    if value < 0 or value >= (1 << width):
        raise ValueError(f"{value} does not fit unsigned {width}-bit word")
    return f"{value:0{(width + 3) // 4}X}"


def clamp_with_sat(value: int, relu: bool) -> tuple[int, int]:
    lo = 0 if relu else -128
    y = max(lo, min(127, value))
    return y, int(y != value)


def make_vector(acc: int, m0: int, n: int, relu: bool, bias: int,
                bypass: bool, last: int) -> dict[str, int]:
    total = acc + bias
    a = wrap32(total)
    ovf = int(total < ACC_LO or total > ACC_HI)
    if bypass:
        raw = a
        y, _ = clamp_with_sat(a, relu)
        sat = 0
    else:
        raw = requant_raw_ref(a, m0, n)
        y, sat = clamp_with_sat(raw, relu)
        assert y == requant_ref(a, m0, n, relu)
    return {
        "acc": acc,
        "bias": bias,
        "m0": m0,
        "n": n,
        "relu": int(relu),
        "bypass": int(bypass),
        "k_last": 1,
        "last": last,
        "y": y,
        "raw": raw,
        "sat": sat,
        "ovf": ovf,
    }


def build_vectors() -> list[dict[str, int]]:
    vectors: list[dict[str, int]] = []
    channels = ((98765, 20), (131071, 31), (65537, 1))
    for channel_index, (m0, n) in enumerate(channels):
        accs = all_test_accs(m0, n, random_count=10000, seed=0)
        for relu in (False, True):
            for index, acc in enumerate(accs):
                vectors.append(make_vector(acc, m0, n, relu, 0, False,
                                           int((index + channel_index) % 7 == 0)))

    # The 64-bit offset edges are deliberately evaluated at accumulator
    # extremes, for both lower-bound choices.
    for n in (0, 49, 50, 63):
        for relu in (False, True):
            for acc in (ACC_LO, ACC_LO + 1, -1, 0, 1, ACC_HI - 1, ACC_HI):
                vectors.append(make_vector(acc, 131071, n, relu, 0, False, 0))

    # Bias is sampled in S0. These cases include both ordinary signed bias
    # and additions that wrap the signed INT32 accumulator.
    biases = (1, -1, 123456789, -123456789, 0x40000000,
              -0x40000000, ACC_HI, ACC_LO)
    bias_accs = (ACC_LO, ACC_LO + 1, -1000, 0, 1000, ACC_HI - 1, ACC_HI)
    for bias in biases:
        for acc in bias_accs:
            for relu in (False, True):
                vectors.append(make_vector(acc, 98765, 20, relu, bias, False, 1))

    # Bypass is a real sample path: raw is the sign-extended wrapped,
    # bias-added accumulator, while y/sat still use the selected clamp.
    for bias in (0, 1, -1, 0x40000000, -0x40000000, ACC_HI, ACC_LO):
        for acc in (ACC_LO, -1, 0, 1, ACC_HI):
            for relu in (False, True):
                vectors.append(make_vector(acc, 131071, 31, relu, bias, True, 1))

    # Directed pair for the bypass-status contract: both samples produce the
    # same bias-added a=2000, but only the quantized sample reports saturation.
    vectors.append(make_vector(2000, 131071, 20, False, 0, False, 1))
    vectors.append(make_vector(2000, 131071, 20, False, 0, True, 1))
    return vectors


def write_vectors(vectors: list[dict[str, int]]) -> None:
    VECTOR_DIR.mkdir(parents=True, exist_ok=True)
    fields = {
        "acc": lambda v: signed_hex(v["acc"], 32),
        "bias": lambda v: signed_hex(v["bias"], 32),
        "m0": lambda v: signed_hex(v["m0"], 18),
        "shift": lambda v: unsigned_hex(v["n"], 6),
        "relu": lambda v: unsigned_hex(v["relu"], 1),
        "bypass": lambda v: unsigned_hex(v["bypass"], 1),
        "k_last": lambda v: unsigned_hex(v["k_last"], 1),
        "last": lambda v: unsigned_hex(v["last"], 1),
        "y": lambda v: signed_hex(v["y"], 8),
        "raw": lambda v: signed_hex(v["raw"], 64),
        "sat": lambda v: unsigned_hex(v["sat"], 1),
        "ovf": lambda v: unsigned_hex(v["ovf"], 1),
    }
    for name, formatter in fields.items():
        (VECTOR_DIR / f"req_{name}.mem").write_text(
            "\n".join(formatter(vector) for vector in vectors) + "\n",
            encoding="ascii",
        )
    (VECTOR_DIR / "req_count.mem").write_text(
        f"{len(vectors):08X}\n", encoding="ascii"
    )


def self_check_writer() -> None:
    negative = -123456789
    encoded = signed_hex(negative, 32)
    round_trip = int(encoded, 16)
    if round_trip & (1 << 31):
        round_trip -= 1 << 32
    assert round_trip == negative, "negative $readmemh serialization did not round-trip"


if __name__ == "__main__":
    self_check_writer()
    vectors = build_vectors()
    write_vectors(vectors)
    print(f"wrote {len(vectors)} vectors to {VECTOR_DIR}")
