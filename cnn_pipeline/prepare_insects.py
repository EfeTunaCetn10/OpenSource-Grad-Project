from __future__ import annotations

import argparse
import json
import random
import shutil
from pathlib import Path


IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".bmp", ".webp"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Create reproducible insect dataset splits")
    parser.add_argument("--input-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--train-ratio", type=float, default=0.70)
    parser.add_argument("--val-ratio", type=float, default=0.15)
    parser.add_argument("--seed", type=int, default=42)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if not args.input_dir.is_dir():
        raise FileNotFoundError(args.input_dir)
    test_ratio = 1.0 - args.train_ratio - args.val_ratio
    if min(args.train_ratio, args.val_ratio, test_ratio) <= 0:
        raise ValueError("train, validation, and test ratios must all be positive")
    if args.output_dir.exists() and any(args.output_dir.iterdir()):
        raise FileExistsError(f"output directory must be empty: {args.output_dir}")

    rng = random.Random(args.seed)
    manifest: dict[str, object] = {
        "seed": args.seed,
        "ratios": {"train": args.train_ratio, "val": args.val_ratio, "test": test_ratio},
        "classes": {},
    }
    class_dirs = sorted(path for path in args.input_dir.iterdir() if path.is_dir())
    if len(class_dirs) < 2:
        raise ValueError("at least two class folders are required")

    for class_dir in class_dirs:
        images = sorted(
            path for path in class_dir.rglob("*") if path.is_file() and path.suffix.lower() in IMAGE_SUFFIXES
        )
        if len(images) < 7:
            raise ValueError(f"class {class_dir.name!r} needs at least 7 images")
        rng.shuffle(images)
        train_end = max(1, int(len(images) * args.train_ratio))
        val_end = train_end + max(1, int(len(images) * args.val_ratio))
        val_end = min(val_end, len(images) - 1)
        split_images = {
            "train": images[:train_end],
            "val": images[train_end:val_end],
            "test": images[val_end:],
        }
        manifest["classes"][class_dir.name] = {
            split: len(paths) for split, paths in split_images.items()
        }
        for split, paths in split_images.items():
            destination = args.output_dir / split / class_dir.name
            destination.mkdir(parents=True, exist_ok=True)
            for index, source in enumerate(paths):
                target = destination / f"{index:06d}_{source.name}"
                shutil.copy2(source, target)

    manifest_path = args.output_dir / "split_manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()

