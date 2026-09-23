"""Deterministic train-only calibration input preparation; no model evaluation/PTQ."""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import datetime
import hashlib
import io
import json
import math
from pathlib import Path
import platform
import random

import PIL
import torch
import torchvision
from torch.utils.data import DataLoader, Subset
from torchvision.datasets import ImageFolder
from torchvision.datasets.folder import pil_loader

from data import build_insect_eval_transform

REPO_ROOT = Path(__file__).resolve().parents[1]


def json_bytes(value: dict | list) -> bytes:
    """Canonical UTF-8 serialization used for both writing and hashing."""
    return (json.dumps(value, sort_keys=True, indent=2, ensure_ascii=False,
                       allow_nan=False) + "\n").encode("utf-8")


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def relative_path(path: Path, root: Path) -> str:
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError as exc:
        raise ValueError(f"Path must be inside repository root {root}: {path}") from exc


def load_checkpoint(path: Path) -> tuple[dict, str]:
    raw = path.read_bytes()
    checkpoint = torch.load(io.BytesIO(raw), map_location="cpu", weights_only=True)
    return checkpoint, hashlib.sha256(raw).hexdigest()


def validate_metadata(checkpoint: dict) -> tuple[list[str], list[float], list[float]]:
    if (checkpoint.get("model_name") != "LeNet5ReLUMaxPool"
            or checkpoint.get("input_channels") != 3
            or checkpoint.get("image_size") != [32, 32]):
        raise ValueError("Expected LeNet5ReLUMaxPool checkpoint with RGB 32x32 input")
    classes = checkpoint.get("class_names")
    if (not isinstance(classes, list) or len(classes) < 2
            or not all(isinstance(c, str) and c for c in classes)
            or len(set(classes)) != len(classes)):
        raise ValueError("Checkpoint class_names must be unique nonempty class names")
    try:
        mean = [float(v) for v in checkpoint["mean"]]
        std = [float(v) for v in checkpoint["std"]]
    except (KeyError, TypeError, ValueError) as exc:
        raise ValueError("Checkpoint must contain numeric RGB mean/std") from exc
    if (len(mean) != 3 or len(std) != 3
            or not all(math.isfinite(v) for v in mean + std)
            or not all(v > 0 for v in std)):
        raise ValueError("Checkpoint RGB mean/std must be finite; std must be positive")
    return classes, mean, std


def read_split_manifest(data_dir: Path, dataset: ImageFolder) -> tuple[dict, dict, list[str]]:
    """Validate membership metadata without opening validation/test images."""
    path = data_dir / "split_manifest.json"
    inventory = [{"destination": Path(p).relative_to(data_dir).as_posix(), "label": y}
                 for p, y in dataset.samples]
    identity = {"name": "train", "train_inventory_sha256":
                hashlib.sha256(json_bytes(inventory)).hexdigest()}
    if not path.exists():
        return {}, identity, ["No split_manifest.json: membership is based on train/ only; "
                              "capture days unavailable, no filename inference used."]
    raw = path.read_bytes()
    payload = json.loads(raw)
    if payload.get("class_to_idx") != dataset.class_to_idx:
        raise ValueError("Split manifest class_to_idx does not match ImageFolder")
    records = {}
    for item in payload["samples"]:
        destination = item["destination"]
        if destination in records:
            raise ValueError(f"Duplicate split manifest destination: {destination}")
        records[destination] = item
    expected = {i["destination"] for i in inventory}
    declared = {p for p, r in records.items() if r["split"] == "train"}
    if expected != declared:
        raise ValueError("Split manifest train membership differs from ImageFolder")
    for item in inventory:
        record = records[item["destination"]]
        if record["class"] != dataset.classes[item["label"]]:
            raise ValueError(f"Split manifest class mismatch: {item['destination']}")
    identity["manifest_sha256"] = hashlib.sha256(raw).hexdigest()
    return records, identity, [payload["limitation"]] if payload.get("limitation") else []


def reliable_day(record: dict) -> str | None:
    """Use explicit dated, hash-bound metadata; never parse an image filename."""
    day, digest = record.get("day"), record.get("sha256")
    if not isinstance(day, str) or len(day) != 8:
        return None
    if (not isinstance(digest, str) or len(digest) != 64
            or any(c not in "0123456789abcdef" for c in digest)):
        return None
    try:
        datetime.strptime(day, "%Y%m%d")
    except ValueError:
        return None
    return day


@dataclass
class CalibrationBundle:
    loader: DataLoader
    manifest: dict


def build_calibration_loader(checkpoint_path: Path, data_dir: Path,
                             samples_per_class: int = 100, seed: int = 42,
                             batch_size: int = 32, *,
                             repo_root: Path = REPO_ROOT) -> CalibrationBundle:
    if samples_per_class <= 0 or batch_size <= 0:
        raise ValueError("samples_per_class and batch_size must be positive")
    checkpoint_path, data_dir = checkpoint_path.resolve(), data_dir.resolve()
    checkpoint, checkpoint_hash = load_checkpoint(checkpoint_path)
    classes, mean, std = validate_metadata(checkpoint)
    train_dir = data_dir / "train"
    if not train_dir.is_dir() or train_dir.is_symlink():
        raise ValueError(f"Expected a real train/ directory: {train_dir}")
    transform = build_insect_eval_transform(mean, std)
    # Explicit PIL loader guarantees RGB independently of torchvision's global backend.
    dataset = ImageFolder(train_dir, transform=transform, loader=pil_loader)
    if dataset.classes != classes:
        raise ValueError(f"ImageFolder class order {dataset.classes} differs from "
                         f"checkpoint class order {classes}")
    for path, _ in dataset.samples:
        if not Path(path).resolve().is_relative_to(train_dir):
            raise ValueError(f"Image escapes train/ (possibly a symlink): {path}")
        relative_path(Path(path), repo_root)
    records, split_identity, limitations = read_split_manifest(data_dir, dataset)
    split_identity["data_dir"] = relative_path(data_dir, repo_root)
    if records:
        split_identity["manifest_path"] = relative_path(data_dir / "split_manifest.json", repo_root)
    rng = random.Random(seed)
    selected, strategies = [], {}
    for label, name in enumerate(classes):
        candidates = [i for i, (_, y) in enumerate(dataset.samples) if y == label]
        if len(candidates) < samples_per_class:
            raise ValueError(f"Class {name}: requested {samples_per_class} train images, "
                             f"only {len(candidates)} available")
        by_day = defaultdict(list)
        for i in candidates:
            destination = Path(dataset.samples[i][0]).relative_to(data_dir).as_posix()
            by_day[reliable_day(records.get(destination, {}))].append(i)
        if None in by_day:
            strategies[name] = "seeded_random_without_replacement"
            limitations.append(f"{name}: incomplete reliable capture-day metadata; "
                               "class-wide random fallback, no filename inference.")
            selected.extend(rng.sample(candidates, samples_per_class))
        else:
            strategies[name] = "seeded_capture_day_round_robin_without_replacement"
            days = sorted(by_day)
            rng.shuffle(days)
            for day in days:
                rng.shuffle(by_day[day])
            chosen = []
            while len(chosen) < samples_per_class:
                for day in days:
                    if by_day[day]:
                        chosen.append(by_day[day].pop())
                        if len(chosen) == samples_per_class:
                            break
            selected.extend(chosen)
    rng.shuffle(selected)
    samples = []
    for i in selected:
        path, label = dataset.samples[i]
        path = Path(path)
        record = records.get(path.relative_to(data_dir).as_posix(), {})
        digest = sha256(path)
        if record.get("sha256") is not None and record["sha256"] != digest:
            raise ValueError(f"Image SHA256 differs from split manifest: {path}")
        samples.append({"path": relative_path(path, repo_root), "class": classes[label],
                        "label": label, "sha256": digest,
                        "capture_day": reliable_day(record)})
    resize = transform.transforms[0]
    manifest = {
        "schema_version": 1,
        "checkpoint": {"path": relative_path(checkpoint_path, repo_root), "sha256": checkpoint_hash},
        "split": split_identity,
        "selection": {"seed": seed, "samples_per_class": samples_per_class,
                      "count": len(samples), "strategy_by_class": strategies,
                      "order": "seeded shuffle after class selection; loader shuffle=False",
                      "status": "experimental starting configuration, not an ADR decision"},
        "class_names": classes,
        "preprocessing": {"color": "RGB", "resize": list(resize.size),
                          "interpolation": resize.interpolation.value,
                          "antialias": resize.antialias, "to_tensor_range": [0, 1],
                          "mean": mean, "std": std, "dtype": "float32", "layout": "NCHW",
                          "random_augmentation": False},
        "versions": {"python": platform.python_version(), "torch": torch.__version__,
                     "torchvision": torchvision.__version__, "pillow": PIL.__version__},
        "source_sha256": {p.name: sha256(p) for p in
                          (Path(__file__), Path(__file__).with_name("data.py"))},
        "limitations": limitations,
        "samples": samples,
    }
    loader = DataLoader(Subset(dataset, selected), batch_size=batch_size, shuffle=False,
                        num_workers=0, drop_last=False,
                        generator=torch.Generator().manual_seed(seed))
    return CalibrationBundle(loader, manifest)


def check_batches(bundle: CalibrationBundle) -> dict:
    """Read selected inputs only; check channel-wise normalized RGB bounds."""
    prep = bundle.manifest["preprocessing"]
    mean, std = torch.tensor(prep["mean"]), torch.tensor(prep["std"])
    lower, upper = (-mean / std).view(1, 3, 1, 1), ((1 - mean) / std).view(1, 3, 1, 1)
    count, batches = 0, 0
    minimum, maximum = math.inf, -math.inf
    for images, labels in bundle.loader:
        if images.dtype != torch.float32 or images.ndim != 4 or images.shape[1:] != (3, 32, 32):
            raise ValueError("Expected float32 batch [N,3,32,32]")
        if not torch.isfinite(images).all():
            raise ValueError("Non-finite calibration input")
        if ((images < lower - 1e-5) | (images > upper + 1e-5)).any():
            raise ValueError("Calibration input outside normalized RGB [0,1] bounds")
        expected = [s["label"] for s in bundle.manifest["samples"][count:count + len(images)]]
        if labels.tolist() != expected:
            raise ValueError("Batch labels differ from manifest order")
        count += len(images)
        batches += 1
        minimum, maximum = min(minimum, images.min().item()), max(maximum, images.max().item())
    if count != bundle.manifest["selection"]["count"]:
        raise ValueError("Loaded sample count differs from selection manifest")
    return {"samples_checked": count, "batches_checked": batches,
            "batch_size": bundle.loader.batch_size, "shape": "[N,3,32,32]",
            "dtype": "float32", "observed_min": minimum, "observed_max": maximum}


def write_outputs(bundle: CalibrationBundle, checks: dict, output_dir: Path) -> dict:
    """Create a fresh output directory; never overwrite a previous run."""
    raw = json_bytes(bundle.manifest)
    summary = {
        "selection_manifest": "selection_manifest.json",
        "selection_manifest_sha256": hashlib.sha256(raw).hexdigest(),
        "checks": checks,
        "class_counts": dict(Counter(s["class"] for s in bundle.manifest["samples"])),
        "capture_days_per_class": {c: len({s["capture_day"] for s in bundle.manifest["samples"]
                                          if s["class"] == c and s["capture_day"] is not None})
                                   for c in bundle.manifest["class_names"]},
        "limitations": bundle.manifest["limitations"],
    }
    output_dir.mkdir(parents=True, exist_ok=False)
    (output_dir / "selection_manifest.json").write_bytes(raw)
    (output_dir / "summary.json").write_bytes(json_bytes(summary))
    return summary


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", required=True, type=Path)
    parser.add_argument("--data-dir", required=True, type=Path)
    parser.add_argument("--samples-per-class", type=int, default=100)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--batch-size", type=int, default=32)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    if args.output_dir.exists():
        parser.error(f"Refusing to overwrite output directory: {args.output_dir}")
    if args.output_dir.resolve().is_relative_to(args.data_dir.resolve()):
        parser.error("output-dir must be outside data-dir")
    bundle = build_calibration_loader(args.checkpoint, args.data_dir, args.samples_per_class,
                                      args.seed, args.batch_size)
    summary = write_outputs(bundle, check_batches(bundle), args.output_dir)
    print(f"Checked {summary['checks']['samples_checked']} train images; "
          f"{summary['checks']['batches_checked']} batches. Output: {args.output_dir}")
    print(f"Selection manifest SHA256: {summary['selection_manifest_sha256']}")
    print(f"Limitations: {len(summary['limitations'])}; see summary.json")


if __name__ == "__main__":
    main()
