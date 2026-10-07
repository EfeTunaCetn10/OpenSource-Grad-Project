#!/usr/bin/env python3
"""Generate the XSim $readmemh vectors for the conv1 end-to-end test.

The arithmetic lives in conv1_ref.py (which itself only composes window_ref,
engine_ref and requant_ref).  This file only serializes: fixed-width
two's-complement hexadecimal, one word per line, uppercase, matching the
existing req_*.mem convention.

Byte packing follows the ADR-006 / workbook rule: lane 0 is the LOW byte of a
64-bit word, so the byte sequence [01,02,...,08] is written as the text word
0807060504030201.  Writing it MSB-first would transpose every activation lane
and silently produce a wrong convolution with no error flag.

Output (sim/vectors/):
    c1_dims.mem        6 words: OUT_H, OUT_W, C_OUT, K_LEN, TILES, OUT_BEATS
    c1_frame.mem       384 x 64-bit dense-HWC input frame beats
    c1_wbank<r>.mem    8 files, K_LEN x INT8, bank r = output channel r (ADR-011)
    c1_cfg_*.mem       per-lane requant configuration (bias_q, m0, shift_n, relu)
    c1_tile_cols.mem   TILES x active_cols, the geometry the sequencer must drive
    c1_acc.mem         OUT_BEATS*8 x INT32 expected accumulators, lane-major
    c1_y.mem           OUT_BEATS x 64-bit expected INT8 results, lane 0 = low byte
"""

from __future__ import annotations

from pathlib import Path
import sys

MODEL_DIR = Path(__file__).resolve().parent
PROJECT = MODEL_DIR.parent
VECTOR_DIR = PROJECT / "sim" / "vectors"
sys.path.insert(0, str(MODEL_DIR))

from conv1_ref import (  # noqa: E402
    C_IN,
    C_OUT,
    IN_H,
    IN_W,
    K_LEN,
    OUT_H,
    OUT_W,
    ROWS,
    TILES,
    random_fixture,
)


def signed_hex(value: int, width: int) -> str:
    if value < -(1 << (width - 1)) or value >= (1 << (width - 1)):
        raise ValueError(f"{value} does not fit signed {width}-bit word")
    return f"{value & ((1 << width) - 1):0{(width + 3) // 4}X}"


def unsigned_hex(value: int, width: int) -> str:
    if value < 0 or value >= (1 << width):
        raise ValueError(f"{value} does not fit unsigned {width}-bit word")
    return f"{value:0{(width + 3) // 4}X}"


def pack_le(lanes: list[int]) -> str:
    """Eight signed bytes -> one 64-bit word, lane 0 in the low byte."""
    if len(lanes) != 8:
        raise ValueError("a packed beat must carry exactly eight lanes")
    word = 0
    for i, value in enumerate(lanes):
        if not -128 <= value <= 127:
            raise ValueError(f"{value} is not INT8")
        word |= (value & 0xFF) << (8 * i)
    return f"{word:016X}"


def write(name: str, lines: list[str]) -> None:
    path = VECTOR_DIR / name
    path.write_text("\n".join(lines) + "\n", encoding="ascii")
    print(f"  {name}: {len(lines)} words")


def main() -> int:
    VECTOR_DIR.mkdir(parents=True, exist_ok=True)
    fx = random_fixture()
    tiles = fx.tiles()

    out_beats = sum(t["active_cols"] for t in tiles)
    if out_beats != OUT_H * OUT_W:
        raise SystemExit(f"beat count {out_beats} != {OUT_H * OUT_W} positions")

    print(f"conv1 fixture: {IN_H}x{IN_W}x{C_IN} -> {OUT_H}x{OUT_W}x{C_OUT}, "
          f"K={K_LEN}, {TILES} tiles, {out_beats} output beats")

    write("c1_dims.mem", [unsigned_hex(v, 32) for v in
                          (OUT_H, OUT_W, C_OUT, K_LEN, TILES, out_beats)])

    frame = fx.frame
    if len(frame) % 8 != 0:
        raise SystemExit("frame length must be a whole number of 64-bit beats")
    write("c1_frame.mem", [pack_le(frame[i:i + 8])
                           for i in range(0, len(frame), 8)])

    banks = fx.weight_banks()
    for r in range(ROWS):
        write(f"c1_wbank{r}.mem", [signed_hex(v, 8) for v in banks[r]])

    write("c1_cfg_bias.mem", [signed_hex(v, 32) for v in fx.bias_q])
    write("c1_cfg_m0.mem", [unsigned_hex(v, 18) for v in fx.m0])
    write("c1_cfg_shift.mem", [unsigned_hex(v, 6) for v in fx.shift_n])
    write("c1_cfg_relu.mem", [unsigned_hex(int(v), 1) for v in fx.relu])

    write("c1_tile_cols.mem",
          [unsigned_hex(t["active_cols"], 8) for t in tiles])

    acc_lines: list[str] = []
    y_lines: list[str] = []
    for entry in tiles:
        for col in range(entry["active_cols"]):
            for lane in range(ROWS):
                acc_lines.append(signed_hex(entry["acc_by_col"][col][lane], 32))
            y_lines.append(pack_le(entry["y_by_col"][col]))
    write("c1_acc.mem", acc_lines)
    write("c1_y.mem", y_lines)

    # A vector set that encodes a transposed or mis-scaled datapath would still
    # load cleanly, so re-check the two properties that make it a real test.
    tensor = fx.output_tensor()
    if not (max(tensor) >= 100 and min(tensor) <= -100):
        raise SystemExit(f"output range too narrow: {min(tensor)}..{max(tensor)}")
    if len({t["active_cols"] for t in tiles}) < 2:
        raise SystemExit("fixture has no partial right-edge tile")
    print(f"output range {min(tensor)}..{max(tensor)}, "
          f"active_cols seen {sorted({t['active_cols'] for t in tiles})}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
