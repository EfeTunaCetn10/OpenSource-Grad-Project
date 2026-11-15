#!/usr/bin/env python3
"""Generate the FC-flatten and AXI byte-lane diagnostic programs."""
from __future__ import annotations

import json
from pathlib import Path

from netprog import emit_program

VECTORS = Path(__file__).resolve().parent.parent / "sim" / "vectors"
M0 = 1 << 16
SHIFT = 16


def layer(name: str, kind: str, c_in: int, weights: list[list[int]]) -> dict:
    c_out = len(weights)
    return {
        "name": name, "kind": kind, "c_in": c_in, "c_out": c_out,
        "kh": 1, "kw": 1, "pad": 0, "pool": False,
        "weights": weights, "bias_q": [0] * c_out,
        "m0": [M0] * c_out, "n": [SHIFT] * c_out, "relu": [0] * c_out,
    }


def write_meta(name: str, meta: dict) -> None:
    words = [0x4E504D31, len(meta["logits"]), meta["class_count"]]
    for item, pred in zip(meta["logits"], meta["expected_argmax"], strict=True):
        words.extend((item["offset"], item["nbeats"], item["count"], pred))
    (VECTORS / f"{name}_meta.mem").write_text(
        "".join(f"{word & 0xFFFFFFFF:08X}\n" for word in words),
        encoding="ascii", newline="\n")


def emit_fc_order() -> None:
    h, w, channels = 2, 2, 16
    identity = [[int(oc == ci) for ci in range(channels)] for oc in range(channels)]
    encoded = []
    for field in range(8):
        row = []
        for k in range(h * w * channels):
            hh, rem = divmod(k, w * channels)
            ww, cc = divmod(rem, channels)
            codes = (k + 1, hh + 1, ww + 1, cc + 1,
                     cc // 8 + 1, (k & 7) + 1, (k // 8) + 1, 1)
            row.append(codes[field])
        encoded.append(row)
    model = {
        "name": "fc1_order_onehot", "input": {"h": h, "w": w, "c": channels},
        "layers": [layer("store", "conv", channels, identity),
                   layer("fc", "fc", h * w * channels, encoded)],
    }
    points = ((0, 0, 0), (0, 1, 8), (1, 0, 15), (1, 1, 9))
    images = []
    for ph, pw, pc in points:
        image = [[[0 for _ in range(channels)] for _ in range(w)] for _ in range(h)]
        image[ph][pw][pc] = 1
        images.append(image)
    result = emit_program(model, images, VECTORS, "diag_fc1_order")
    write_meta("diag_fc1_order", result["meta"])
    (VECTORS / "diag_fc1_order_model.json").write_text(
        json.dumps(model, indent=2) + "\n", encoding="utf-8", newline="\n")


def emit_axis_lane() -> None:
    h, w, channels = 2, 4, 8
    identity = [[int(oc == ci) for ci in range(channels)] for oc in range(channels)]
    model = {
        "name": "axis_coordinate_lanes", "input": {"h": h, "w": w, "c": channels},
        "layers": [layer("identity", "conv", channels, identity)],
    }
    image = [[[64 * hh + 8 * ww + cc for cc in range(channels)]
              for ww in range(w)] for hh in range(h)]
    result = emit_program(model, [image], VECTORS, "diag_axis_lane")
    write_meta("diag_axis_lane", result["meta"])
    (VECTORS / "diag_axis_lane_model.json").write_text(
        json.dumps(model, indent=2) + "\n", encoding="utf-8", newline="\n")


def main() -> None:
    VECTORS.mkdir(parents=True, exist_ok=True)
    emit_fc_order()
    emit_axis_lane()
    print("PASS gen_prog_diag_vectors: FC HWC one-hot C=16; AXIS coordinate lanes")


if __name__ == "__main__":
    main()
