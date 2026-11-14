#!/usr/bin/env python3
"""Build the imported synthetic v3 fixture and emit netprog artifacts."""
from __future__ import annotations

import json
import random
from pathlib import Path

import gen_v3_e2e_vectors as gv3
from lenet_ref import lenet_fixture, lenet_forward
from netprog import emit_program

VECTORS = Path(__file__).resolve().parent.parent / "sim" / "vectors"


def write_tb_meta(name: str, meta: dict) -> None:
    """Write the small, fixed-order subset that the SV replay TB consumes."""
    words = [0x4E504D31, len(meta["logits"]), meta["class_count"]]
    for item, pred in zip(meta["logits"], meta["expected_argmax"], strict=True):
        words.extend((item["offset"], item["nbeats"], item["count"], pred))
    (VECTORS / f"{name}_meta.mem").write_text(
        "".join(f"{word & 0xFFFFFFFF:08X}\n" for word in words),
        encoding="ascii", newline="\n")


def build_v3_model_and_images() -> tuple[dict, list, list[dict]]:
    """Use the authority generator's constructors; do not duplicate its fixture."""
    rng = random.Random(20261109)
    candidates = [gv3.candidate_image(k) for k in range(16)]
    net = gv3.build_net(rng, candidates[0])
    images, seen = [], set()
    for image in candidates:
        outs, logits = gv3.run_net(net, image)
        pred = gv3.argmax_first(logits)
        if pred not in seen and len(images) < gv3.NIMG and gv3.healthy(outs, logits):
            seen.add(pred)
            images.append(image)
    if len(images) < 2:
        raise RuntimeError("authority fixture did not produce its required distinct predictions")
    layers = []
    for index, layer in enumerate(net):
        layers.append({
            "name": ({"c": "conv", "f": "fc"}[layer["tag"][0]] + layer["tag"][1:]),
            "kind": layer["kind"], "c_in": layer["c_in"], "c_out": layer["c_out"],
            "kh": layer["kh"], "kw": layer["kw"], "pad": layer["pad"],
            "pool": layer["pool"], "weights": layer["weights"],
            "bias_q": layer["bias"], "m0": layer["m0"], "n": layer["shift"],
            "relu": layer["relu"],
        })
    model = {"name": "v3_48_synth", "input": {"h": 48, "w": 48, "c": 3},
             "layers": layers}
    return model, images, net


def _repeat_lane_params(config: dict, count: int) -> dict:
    return {key: [int(config[key][channel % 8]) for channel in range(count)]
            for key in ("bias_q", "m0", "shift_n", "relu")}


def build_lenet_model_and_image() -> tuple[dict, list, list[int]]:
    """Convert the imported physical FC1 order to contract HWC order."""
    fixture = lenet_fixture()
    image = [[[fixture["image"][(row * 32 + column) * 3 + channel]
               for channel in range(3)] for column in range(32)] for row in range(32)]
    fc1_weights = []
    for output_channel in range(120):
        physical = fixture["w_fc1"][output_channel * 400:(output_channel + 1) * 400]
        dense = [0] * 400
        for row in range(5):
            for column in range(5):
                for channel in range(16):
                    contract_k = (row * 5 + column) * 16 + channel
                    physical_k = (((channel // 8) * 5 + row) * 5 + column) * 8 + channel % 8
                    dense[contract_k] = physical[physical_k]
        fc1_weights.append(dense)

    layer_specs = [
        ("conv1", "conv", 3, 6, 5, 5, fixture["w_conv1"], True),
        ("conv2", "conv", 6, 16, 5, 5, fixture["w_conv2"], True),
        ("fc1", "fc", 400, 120, 1, 1, fc1_weights, False),
        ("fc2", "fc", 120, 84, 1, 1,
         [fixture["w_fc2"][index * 120:(index + 1) * 120] for index in range(84)], False),
        ("fc3", "fc", 84, 10, 1, 1,
         [fixture["w_fc3"][index * 84:(index + 1) * 84] for index in range(10)], False),
    ]
    layers = []
    for name, kind, c_in, c_out, kh, kw, weights, pool in layer_specs:
        params = _repeat_lane_params(fixture[f"cfg_{name}"], c_out)
        layers.append({
            "name": name, "kind": kind, "c_in": c_in, "c_out": c_out,
            "kh": kh, "kw": kw, "pad": 0, "pool": pool, "weights": weights,
            "bias_q": params["bias_q"], "m0": params["m0"],
            "n": params["shift_n"], "relu": params["relu"],
        })
    model = {"name": "lenet_synth", "input": {"h": 32, "w": 32, "c": 3},
             "layers": layers}
    return model, [image], lenet_forward(fixture)["logits"]


def main() -> None:
    VECTORS.mkdir(parents=True, exist_ok=True)
    model, images, _ = build_v3_model_and_images()
    model_path = VECTORS / "np_v3_model.json"
    model_path.write_text(json.dumps(model, separators=(",", ":")) + "\n",
                          encoding="utf-8", newline="\n")
    v3_result = emit_program(model, images, VECTORS, "np_v3")
    write_tb_meta("np_v3", v3_result["meta"])
    lenet_model, lenet_images, lenet_logits = build_lenet_model_and_image()
    (VECTORS / "np_lenet_model.json").write_text(
        json.dumps(lenet_model, separators=(",", ":")) + "\n", encoding="utf-8", newline="\n")
    lenet_result = emit_program(lenet_model, lenet_images, VECTORS, "np_lenet")
    write_tb_meta("np_lenet", lenet_result["meta"])
    if lenet_result["logits"][0] != lenet_logits:
        raise AssertionError("contract-order LeNet logits differ from lenet_ref")
    print(f"PASS gen_netprog_vectors: v3 {len(images)} images; LeNet 1 image, logits bit-exact")


if __name__ == "__main__":
    main()
