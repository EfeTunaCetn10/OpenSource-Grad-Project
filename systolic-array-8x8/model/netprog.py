#!/usr/bin/env python3
"""Pack a frozen INT8 CNN model and emit the accelerator text program."""
from __future__ import annotations

import argparse
import copy
import importlib.util
import json
import sys
import tempfile
from pathlib import Path

from v3_ref import ROWS, argmax_first, conv, flatten_hwc, pack_word, pool2x2, requant_layer, tile_major_words

ROOT = Path(__file__).resolve().parent.parent
COMMON = ROOT / "sw" / "common"
if str(COMMON) not in sys.path:
    sys.path.insert(0, str(COMMON))
try:
    import accel_regs as R
except ModuleNotFoundError as exc:
    raise SystemExit("run 'python model/gen_regmap.py' first") from exc


class ModelError(ValueError):
    """The model or image violates the frozen hardware envelope."""


def _integer(value, what: str, lo: int | None = None, hi: int | None = None) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ModelError(f"{what} must be an integer")
    if lo is not None and value < lo or hi is not None and value > hi:
        bound = f"[{lo}, {hi}]" if hi is not None else f">= {lo}"
        raise ModelError(f"{what}={value} outside {bound}")
    return value


def _array(layer: dict, key: str, rows: int, padded: int, lo: int, hi: int,
           pad_value: int) -> list[int]:
    value = layer.get(key)
    if not isinstance(value, list) or len(value) not in (rows, padded):
        raise ModelError(f"{layer.get('name', '?')}.{key} must have {rows} or {padded} entries")
    out = [_integer(v, f"{layer.get('name', '?')}.{key}[{i}]", lo, hi)
           for i, v in enumerate(value)]
    return out + [pad_value] * (padded - len(out))


def load_model(source: str | Path | dict) -> dict:
    """Load JSON and validate/derive all layer mapping values."""
    raw = copy.deepcopy(source if isinstance(source, dict)
                        else json.loads(Path(source).read_text(encoding="utf-8")))
    if not isinstance(raw, dict) or not isinstance(raw.get("name"), str):
        raise ModelError("model needs a string name")
    inp = raw.get("input")
    if not isinstance(inp, dict):
        raise ModelError("model needs input geometry")
    h = _integer(inp.get("h"), "input.h", 1, 48)
    w = _integer(inp.get("w"), "input.w", 1, 48)
    c = _integer(inp.get("c"), "input.c", 1)
    if not isinstance(raw.get("layers"), list) or not raw["layers"]:
        raise ModelError("model needs at least one layer")

    base = 0
    prev_tiles = None
    derived = []
    names = set()
    for li, layer in enumerate(raw["layers"]):
        if not isinstance(layer, dict) or not isinstance(layer.get("name"), str):
            raise ModelError(f"layer {li} needs a string name")
        name = layer["name"]
        if name in names:
            raise ModelError(f"duplicate layer name {name}")
        names.add(name)
        kind = layer.get("kind")
        if kind not in ("conv", "fc"):
            raise ModelError(f"{name}.kind must be conv or fc")
        c_in = _integer(layer.get("c_in"), f"{name}.c_in", 1)
        c_out = _integer(layer.get("c_out"), f"{name}.c_out", 1)
        kh = _integer(layer.get("kh", 1), f"{name}.kh", 1, 5)
        kw = _integer(layer.get("kw", 1), f"{name}.kw", 1, 5)
        pad = _integer(layer.get("pad", 0), f"{name}.pad", 0, 2)
        pool = layer.get("pool", False)
        if not isinstance(pool, bool):
            raise ModelError(f"{name}.pool must be boolean")
        if kind == "fc":
            if (kh, kw, pad, pool) != (1, 1, 0, False):
                raise ModelError(f"{name}: FC requires kh=kw=1, pad=0, pool=false")
            logical_in = h * w * c
            out_h = out_w = 1
        else:
            logical_in = c
            out_h, out_w = h + 2 * pad - kh + 1, w + 2 * pad - kw + 1
            if out_h <= 0 or out_w <= 0 or pad >= kh or pad >= kw:
                raise ModelError(f"{name}: invalid convolution geometry")
        if c_in != logical_in:
            raise ModelError(f"{name}.c_in={c_in}, expected {logical_in}")
        if c_in > 0x1FF or c_out > 0x7F8:
            raise ModelError(f"{name}: channel count is not representable")
        k_len = c_in * kh * kw
        if k_len > 1024:
            raise ModelError(f"{name}: K={k_len} exceeds 1024")
        tiles = (c_out + ROWS - 1) // ROWS
        if tiles > 255:
            raise ModelError(f"{name}: tile count exceeds 255")
        padded = tiles * ROWS
        c_phys = c_in if li == 0 else ROWS * prev_tiles * (h * w if kind == "fc" else 1)
        if c_phys > 0x1FF:
            raise ModelError(f"{name}: c_phys={c_phys} is not representable")

        weights = layer.get("weights")
        if not isinstance(weights, list) or len(weights) not in (c_out, padded):
            raise ModelError(f"{name}.weights must have {c_out} or {padded} rows")
        packed_weights = []
        for oc, row in enumerate(weights):
            if not isinstance(row, list) or len(row) != k_len:
                raise ModelError(f"{name}.weights[{oc}] must have K={k_len} entries")
            packed_weights.append([_integer(v, f"{name}.weights[{oc}][{k}]", -128, 127)
                                   for k, v in enumerate(row)])
        packed_weights += [[0] * k_len for _ in range(padded - len(packed_weights))]
        bias = _array(layer, "bias_q", c_out, padded, -(1 << 31), (1 << 31) - 1, 0)
        m0 = _array(layer, "m0", c_out, padded, 1 << 16, (1 << 17) - 1, 1 << 16)
        shift = _array(layer, "n", c_out, padded, 0, 63, 1)
        relu = _array(layer, "relu", c_out, padded, 0, 1, 0)
        end = base + tiles * k_len
        if end > 8192:
            raise ModelError(f"{name}: weight bank overflow ({end} > 8192 bytes)")
        stored_h, stored_w = ((out_h // 2, out_w // 2) if pool else (out_h, out_w))
        if pool and (out_h % 2 or out_w % 2):
            raise ModelError(f"{name}: pooling requires even output geometry")
        if tiles * stored_h * stored_w > 4608:
            raise ModelError(f"{name}: act_buffer envelope exceeded")
        derived.append({
            "name": name, "kind": kind, "c_in": c_in, "c_out": c_out,
            "kh": kh, "kw": kw, "pad": pad, "pool": pool,
            "out_h": out_h, "out_w": out_w, "stored_h": stored_h, "stored_w": stored_w,
            "tiles": tiles, "last_rows": c_out % ROWS, "c_phys": c_phys,
            "k_len": k_len, "w_base": base, "src_sel": int(li != 0),
            "dst_sel": int(li == len(raw["layers"]) - 1), "weights": packed_weights,
            "bias_q": bias, "m0": m0, "n": shift, "relu": relu,
        })
        base = end
        h, w, c = stored_h, stored_w, c_out
        prev_tiles = tiles
    raw["_layers"] = derived
    raw["_weight_end"] = base
    return raw


def pack_model(model: str | Path | dict) -> dict:
    model = load_model(model)
    banks = [[0] * 8192 for _ in range(ROWS)]
    for layer in model["_layers"]:
        for oc, row in enumerate(layer["weights"]):
            tile, bank = divmod(oc, ROWS)
            addr = layer["w_base"] + tile * layer["k_len"]
            banks[bank][addr:addr + layer["k_len"]] = [v & 0xFF for v in row]
    return {"model": model, "banks": banks, "layers": model["_layers"],
            "weight_end": model["_weight_end"]}


def forward(packed: dict, image: list) -> list[int]:
    """Integer golden forward; arithmetic is exclusively v3_ref primitives."""
    inp = packed["model"]["input"]
    if not isinstance(image, list) or len(image) != inp["h"]:
        raise ModelError("image height mismatch")
    x = []
    for iy, row in enumerate(image):
        if not isinstance(row, list) or len(row) != inp["w"]:
            raise ModelError(f"image row {iy} width mismatch")
        xr = []
        for ix, px in enumerate(row):
            if not isinstance(px, list) or len(px) != inp["c"]:
                raise ModelError(f"image pixel ({iy},{ix}) channel mismatch")
            xr.append([_integer(v, f"image[{iy}][{ix}]", -128, 127) for v in px])
        x.append(xr)
    for layer in packed["layers"]:
        if layer["kind"] == "fc":
            x = [[flatten_hwc(x)]]
        acc = conv(x, len(x), len(x[0]), layer["c_in"], layer["weights"][:layer["c_out"]],
                   layer["kh"], layer["kw"], layer["pad"])
        x = requant_layer(acc, layer["bias_q"], layer["m0"], layer["n"], layer["relu"])
        if layer["pool"]:
            x = pool2x2(x)
    return flatten_hwc(x)


def _field(reg: str, **values: int) -> int:
    word = 0
    for name, value in values.items():
        lsb = getattr(R, f"{reg}_{name}_LSB")
        width = getattr(R, f"{reg}_{name}_WIDTH")
        if value < 0 or value >= 1 << width:
            raise ModelError(f"{reg}.{name}={value} does not fit {width} bits")
        word |= value << lsb
    return word


def config_words(layer: dict, tile: int) -> list[tuple[int, int]]:
    words = [
        (R.LAYER_CFG, _field("LAYER_CFG", C_IN=layer["c_in"], KH=layer["kh"],
                            KW=layer["kw"], STRIDE=1, PAD=layer["pad"],
                            OUT_H=layer["out_h"], OUT_W=layer["out_w"])),
        (R.LAYER_CFG2, _field("LAYER_CFG2", C_PHYS=layer["c_phys"])),
        (R.W_BASE, _field("W_BASE", ADDR=layer["w_base"])),
        (R.TILE_CFG, _field("TILE_CFG", TILE_IDX=tile, TILE_COUNT=layer["tiles"],
                           BYPASS=0, PARAM_SRC=0, LAST_ROWS=layer["last_rows"])),
        (R.DP_CFG, _field("DP_CFG", SRC_SEL=layer["src_sel"], POOL_EN=int(layer["pool"]),
                         DST_SEL=layer["dst_sel"])),
    ]
    for bank in range(ROWS):
        channel = tile * ROWS + bank
        words.extend([
            (getattr(R, f"BIAS_Q{bank}"), layer["bias_q"][channel] & 0xFFFFFFFF),
            (getattr(R, f"M0_{bank}"), layer["m0"][channel]),
            (getattr(R, f"SHIFT_RELU{bank}"), _field(f"SHIFT_RELU{bank}",
                                                     SHIFT=layer["n"][channel],
                                                     RELU=layer["relu"][channel])),
        ])
    return words


def _write_mem(path: Path, values: list[int], bits: int) -> None:
    mask, width = (1 << bits) - 1, bits // 4
    path.write_text("".join(f"{v & mask:0{width}X}\n" for v in values), encoding="ascii", newline="\n")


def emit_program(model: str | Path | dict, images: list, out_dir: str | Path, name: str) -> dict:
    packed = pack_model(model)
    if not isinstance(images, list) or not images:
        raise ModelError("images JSON must be a non-empty list of HWC images")
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    in_words, exp_words, logits_all, preds = [], [], [], []
    image_input_offsets = []
    logit_offsets = []
    for image in images:
        flat = [v for row in image for px in row for v in px]
        if len(flat) % ROWS:
            raise ModelError("input frame byte count must be a multiple of 8")
        # forward also performs the complete HWC shape/range validation.
        logits = forward(packed, image)
        image_input_offsets.append(len(in_words))
        in_words.extend(pack_word(flat[i:i + ROWS]) for i in range(0, len(flat), ROWS))
        logit_offsets.append(len(exp_words))
        exp_words.extend(pack_word(logits[i:i + ROWS]) for i in range(0, len(logits), ROWS))
        logits_all.append(logits)
        preds.append(argmax_first(logits))

    lines = ["# netprog v1 / register map v5",
             f"R {R.VERSION:03X} FFFF {R.REGMAP_VERSION:04X}", "# weights"]
    for bank in range(ROWS):
        lines.append(f"W {R.W_ADDR:03X} {(bank << R.W_ADDR_BANK_LSB):08X}")
        lines.extend(f"W {R.W_DATA:03X} {byte:02X}" for byte in packed["banks"][bank][:packed["weight_end"]])
    frame_beats = len(in_words) // len(images)
    for image_idx in range(len(images)):
        lines.append(f"# image {image_idx}")
        for li, layer in enumerate(packed["layers"]):
            for tile in range(layer["tiles"]):
                lines.append(f"# pass {layer['name']} tile {tile}")
                lines.extend(f"W {addr:03X} {value:08X}" for addr, value in config_words(layer, tile))
                lines.append(f"W {R.COMMIT:03X} 00000001")
                if layer["src_sel"] == 0:
                    lines.append(f"S {image_input_offsets[image_idx]:X} {frame_beats:X}")
                if layer["dst_sel"]:
                    lines.append(f"M {logit_offsets[image_idx] + tile:X} 1")
                lines.append(f"W {R.CONTROL:03X} {_field('CONTROL', START=1):08X}")
                lines.append(f"P {R.STATUS:03X} {_field('STATUS', DONE=1):08X} {_field('STATUS', DONE=1):08X}")
                clean_mask = _field("STATUS", ERROR=1, ABORTED=1)
                lines.append(f"R {R.STATUS:03X} {clean_mask:08X} 00000000")
                lines.append(f"W {R.STATUS:03X} {_field('STATUS', DONE=1):08X}")
                lines.append("J")
            if li != len(packed["layers"]) - 1:
                lines.append(f"W {R.CONTROL:03X} {_field('CONTROL', LAYER_SWAP=1):08X}")
    lines += [f"R {R.ERROR:03X} 000000FF 00000000",
              f"R {R.ERR_DETAIL:03X} 0000FFFF 00000000"]
    (out / f"{name}.prog").write_text("\n".join(lines) + "\n", encoding="ascii", newline="\n")
    _write_mem(out / f"{name}_in.mem", in_words, 64)
    _write_mem(out / f"{name}_exp.mem", exp_words, 64)
    meta = {
        "name": name, "class_count": packed["layers"][-1]["c_out"],
        "expected_argmax": preds,
        "logits": [{"image": i, "offset": logit_offsets[i],
                    "nbeats": packed["layers"][-1]["tiles"], "count": len(logits_all[i])}
                   for i in range(len(images))],
        "lane_order": "logit[c] is byte lane c%8 of beat offset+c//8; lane 0 is bits 7:0",
        "input": {"layout": "HWC INT8", "frame_beats": frame_beats,
                  "offsets": image_input_offsets},
        "weight_bytes_per_bank": packed["weight_end"],
    }
    (out / f"{name}_meta.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8", newline="\n")
    return {"packed": packed, "logits": logits_all, "meta": meta,
            "program": out / f"{name}.prog"}


def _read_mem(path: Path) -> list[int]:
    return [int(line, 16) for line in path.read_text(encoding="ascii").splitlines() if line.strip()]


def selftest() -> None:
    import gen_v3_e2e_vectors as gv3
    from gen_netprog_vectors import build_v3_model_and_images

    sentinel = gv3.VECTORS / "v3e_img0_pred.mem"
    if not sentinel.exists():
        gv3.main()
    model, images, authority_net = build_v3_model_and_images()
    with tempfile.TemporaryDirectory(prefix="netprog-selftest-") as td:
        result = emit_program(model, images, td, "np_v3")
        packed = result["packed"]
        for bank in range(ROWS):
            expected = _read_mem(gv3.VECTORS / f"v3e_wbank{bank}.mem")
            if packed["banks"][bank] != expected:
                raise AssertionError(f"weight bank {bank} differs")
        for layer, auth in zip(packed["layers"], authority_net):
            if layer["w_base"] != auth["w_base"]:
                raise AssertionError(f"{layer['name']} w_base differs")
            tag = auth["tag"]
            refs = {key: _read_mem(gv3.VECTORS / f"v3e_{tag}_{suffix}.mem")
                    for key, suffix in (("bias_q", "bias"), ("m0", "m0"), ("n", "shift"), ("relu", "relu"))}
            for key in refs:
                actual = ([value & 0xFFFFFFFF for value in layer[key]]
                          if key == "bias_q" else layer[key])
                if actual != refs[key][:len(actual)]:
                    raise AssertionError(f"{tag} {key} params differ")
        exp = _read_mem(Path(td) / "np_v3_exp.mem")
        for i, logits in enumerate(result["logits"]):
            auth_logits = gv3.run_net(authority_net, images[i])[1]
            if logits != auth_logits:
                raise AssertionError(f"image {i} logits differ")
            words = [pack_word(auth_logits[j:j + ROWS]) for j in range(0, len(auth_logits), ROWS)]
            off = result["meta"]["logits"][i]["offset"]
            if exp[off:off + len(words)] != words:
                raise AssertionError(f"image {i} expected words differ")
            pred = _read_mem(gv3.VECTORS / f"v3e_img{i}_pred.mem")[0]
            if result["meta"]["expected_argmax"][i] != pred:
                raise AssertionError(f"image {i} argmax differs")

        # Independently reconstruct tb_v3_e2e.configure's 5+24 words, then
        # compare each COMMIT-delimited configuration in the emitted program.
        expected_passes = []
        for _image in images:
            geom_h, geom_w = model["input"]["h"], model["input"]["w"]
            previous_tiles = None
            for layer_index, authority in enumerate(authority_net):
                out_h = (1 if authority["kind"] == "fc" else
                         geom_h + 2 * authority["pad"] - authority["kh"] + 1)
                out_w = (1 if authority["kind"] == "fc" else
                         geom_w + 2 * authority["pad"] - authority["kw"] + 1)
                tiles = (authority["c_out"] + ROWS - 1) // ROWS
                c_phys = (authority["c_in"] if layer_index == 0 else
                          ROWS * previous_tiles * (geom_h * geom_w
                                                   if authority["kind"] == "fc" else 1))
                for tile in range(tiles):
                    cfg = [
                        (R.LAYER_CFG, authority["c_in"] | authority["kh"] << 9 |
                         authority["kw"] << 12 | 1 << 15 | authority["pad"] << 17 |
                         out_h << 19 | out_w << 25),
                        (R.LAYER_CFG2, c_phys), (R.W_BASE, authority["w_base"]),
                        (R.TILE_CFG, tile | tiles << 8 | (authority["c_out"] % ROWS) << 18),
                        (R.DP_CFG, int(layer_index != 0) | int(authority["pool"]) << 1 |
                         int(layer_index == len(authority_net) - 1) << 2),
                    ]
                    for bank in range(ROWS):
                        ch = tile * ROWS + bank
                        cfg += [(getattr(R, f"BIAS_Q{bank}"), authority["bias"][ch] & 0xFFFFFFFF),
                                (getattr(R, f"M0_{bank}"), authority["m0"][ch]),
                                (getattr(R, f"SHIFT_RELU{bank}"), authority["shift"][ch] |
                                 authority["relu"][ch] << 8)]
                    expected_passes.append(cfg)
                geom_h, geom_w = ((out_h // 2, out_w // 2)
                                  if authority["pool"] else (out_h, out_w))
                previous_tiles = tiles
        actual_passes, pending = [], []
        for line in Path(result["program"]).read_text(encoding="ascii").splitlines():
            parts = line.split()
            if not parts or parts[0] == "#":
                continue
            if parts[0] == "W" and int(parts[1], 16) == R.COMMIT:
                actual_passes.append(pending)
                pending = []
            elif parts[0] == "W" and int(parts[1], 16) in {
                    R.LAYER_CFG, R.LAYER_CFG2, R.W_BASE, R.TILE_CFG, R.DP_CFG,
                    *(getattr(R, f"BIAS_Q{i}") for i in range(ROWS)),
                    *(getattr(R, f"M0_{i}") for i in range(ROWS)),
                    *(getattr(R, f"SHIFT_RELU{i}") for i in range(ROWS))}:
                pending.append((int(parts[1], 16), int(parts[2], 16)))
        if actual_passes != expected_passes:
            raise AssertionError("configure words differ from tb_v3_e2e.configure")
        if len(actual_passes) != 27 * len(images):
            raise AssertionError(f"pass count {len(actual_passes)} differs")

        bad_m0 = copy.deepcopy(model)
        bad_m0["layers"][0]["m0"][0] = (1 << 17)
        huge_k = {"name": "bad_k", "input": {"h": 1, "w": 1, "c": 200}, "layers": [{
            "name": "c", "kind": "conv", "c_in": 200, "c_out": 1, "kh": 3, "kw": 3,
            "pad": 1, "pool": False, "weights": [[0] * 1800], "bias_q": [0],
            "m0": [1 << 16], "n": [1], "relu": [0]}]}
        overflow = copy.deepcopy(model)
        last = overflow["layers"][-1]
        add = 320 - last["c_out"]
        last["c_out"] = 320
        last["weights"] += [[0] * last["c_in"] for _ in range(add)]
        for key, value in (("bias_q", 0), ("m0", 1 << 16), ("n", 1), ("relu", 0)):
            last[key] += [value] * add
        for label, mutant in (("M0 out of range", bad_m0), ("K > 1024", huge_k),
                              ("bank overflow", overflow)):
            try:
                pack_model(mutant)
            except ModelError:
                pass
            else:
                raise AssertionError(f"negative case accepted: {label}")
    print(f"PASS netprog selftest: 8 banks, 7 layers, {27 * len(images)} passes, "
          f"{len(images)} images, 3 negative cases")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("model", nargs="?")
    parser.add_argument("--images")
    parser.add_argument("--out")
    parser.add_argument("--name")
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args()
    if args.selftest:
        selftest()
        return 0
    if not all((args.model, args.images, args.out, args.name)):
        parser.error("model, --images, --out, and --name are required")
    images = json.loads(Path(args.images).read_text(encoding="utf-8"))
    emit_program(args.model, images, args.out, args.name)
    print(f"PASS netprog emitted {args.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
