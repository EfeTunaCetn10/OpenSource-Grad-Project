"""Prepare the verified Insect Detect v2 archive without splitting capture days.

Uses only Python's standard library. The original generic random-image splitter
is intentionally separate: its assumptions do not fit this capture dataset.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from datetime import datetime
import hashlib
import json
from pathlib import Path, PurePosixPath
import random
import re
import zipfile

EXPECTED_MD5 = "0d54a626b7e9958de8278ad93373f89d"
SPLITS = ("train", "val", "test")
RATIOS = (0.70, 0.15, 0.15)


def capture_day(name: str) -> str:
    # Both original crops and older *_jpg.rf.* exports retain this timestamp.
    match = re.fullmatch(r"(\d{8})_\d{2}-\d{2}-\d{2}[.-]\d+_.+\.jpg", name)
    if not match:
        raise ValueError(f"Unrecognized capture filename: {name}")
    datetime.strptime(match[1], "%Y%m%d")
    return match[1]


def select_classes(day_counts: dict[str, Counter]) -> list[str]:
    return sorted(
        label for label, counts in day_counts.items()
        if not label.startswith("none_") and label != "other"
        and sum(counts.values()) >= 300 and len(counts) >= 20
        and max(counts.values()) / sum(counts.values()) <= 0.5
    )


def make_groups(samples: list[dict]) -> dict[str, list[dict]]:
    """Keep days together; identical bytes also join their days into one group."""
    parent = {s["day"]: s["day"] for s in samples}

    def root(day: str) -> str:
        while parent[day] != day:
            parent[day] = parent[parent[day]]
            day = parent[day]
        return day

    seen: dict[str, str] = {}
    for sample in samples:
        previous = seen.setdefault(sample["sha256"], sample["day"])
        a, b = sorted((root(previous), root(sample["day"])))
        parent[b] = a
    groups: dict[str, list[dict]] = defaultdict(list)
    for sample in samples:
        groups[root(sample["day"])].append(sample)
    return dict(sorted(groups.items()))


def assign_groups(groups: dict[str, list[dict]], classes: list[str], seed: int,
                  trials: int = 4000) -> dict[str, str]:
    """Choose a day-group allocation using class counts only, never model scores."""
    if len(groups) < 3:
        raise ValueError("Need at least three independent groups")
    totals = Counter(s["class"] for group in groups.values() for s in group)
    counts = {key: Counter(s["class"] for s in group) for key, group in groups.items()}
    keys = sorted(groups)
    train_end = min(len(keys) - 2, max(1, int(len(keys) * RATIOS[0])))
    val_end = min(len(keys) - 1, train_end + max(1, int(len(keys) * RATIOS[1])))
    rng = random.Random(seed)
    best, best_score = None, float("inf")
    for _ in range(trials):
        rng.shuffle(keys)
        chunks = (keys[:train_end], keys[train_end:val_end], keys[val_end:])
        split_counts = []
        for chunk in chunks:
            count = Counter()
            for key in chunk:
                count.update(counts[key])
            split_counts.append(count)
        if any(count[c] == 0 for count in split_counts for c in classes):
            continue
        score = sum((count[c] / totals[c] - ratio) ** 2
                    for count, ratio in zip(split_counts, RATIOS) for c in classes)
        if score < best_score:
            best_score = score
            best = {key: split for split, chunk in zip(SPLITS, chunks) for key in chunk}
    if best is None:
        raise ValueError("No split with every class present; review capture groups")
    return best


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()
    if args.output_dir.exists():
        raise FileExistsError(f"Refusing to overwrite: {args.output_dir}")
    archive_bytes = args.archive.read_bytes()
    if hashlib.md5(archive_bytes).hexdigest() != EXPECTED_MD5:
        raise ValueError("Archive MD5 differs from the expected Insect Detect v2 file")
    with zipfile.ZipFile(args.archive) as archive:
        if archive.testzip() is not None:
            raise ValueError("Corrupt ZIP member")
        counts: dict[str, Counter] = defaultdict(Counter)
        entries = []
        for name in sorted(archive.namelist()):
            path = PurePosixPath(name)
            if len(path.parts) != 2 or path.is_absolute() or ".." in path.parts:
                raise ValueError(f"Unexpected archive path: {name}")
            day = capture_day(path.name)
            counts[path.parts[0]][day] += 1
            entries.append((name, path.parts[0], day))
        classes = select_classes(counts)
        if len(classes) != 10:
            raise ValueError(f"Expected exactly 10 selected classes, got {classes}")
        samples = [dict(source=name, **{"class": label}, day=day,
                        sha256=hashlib.sha256(archive.read(name)).hexdigest())
                   for name, label, day in entries if label in classes]
        groups = make_groups(samples)
        assignments = assign_groups(groups, classes, args.seed)
        for key, group in groups.items():
            for sample in group:
                sample["group"] = key
                sample["split"] = assignments[key]
                sample["destination"] = f'{sample["split"]}/{sample["source"]}'
        manifest = {
            "archive": args.archive.name,
            "archive_md5": EXPECTED_MD5,
            "archive_sha256": hashlib.sha256(archive_bytes).hexdigest(),
            "seed": args.seed, "search_trials": 4000,
            "target_ratios": dict(zip(SPLITS, RATIOS)),
            "grouping": "global capture day; days linked by identical file SHA256 are merged",
            "limitation": "Capture day is a proxy, not a verified individual-insect ID. Near-duplicates across days remain possible.",
            "selection_rule": "Exclude none_* and other; images >= 300; days >= 20; largest day share <= 0.5",
            "class_to_idx": {label: i for i, label in enumerate(classes)},
            "source_class_summary": {
                label: {"images": sum(c.values()), "days": len(c),
                        "largest_day_images": max(c.values()), "selected": label in classes}
                for label, c in sorted(counts.items())
            },
            "classes": {label: {split: sum(s["class"] == label and s["split"] == split
                                          for s in samples) for split in SPLITS}
                        for label in classes},
            "groups": {key: {"split": assignments[key],
                              "days": sorted({s["day"] for s in group})}
                       for key, group in groups.items()},
            "samples": samples,
        }
        # All planning and source validation happens before materialization.
        args.output_dir.mkdir(parents=True)
        for sample in samples:
            target = args.output_dir / sample["destination"]
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(archive.read(sample["source"]))
        (args.output_dir / "split_manifest.json").write_text(
            json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest["classes"], indent=2))
    print(f"Prepared {len(samples)} images in {len(groups)} capture groups")


if __name__ == "__main__":
    main()
