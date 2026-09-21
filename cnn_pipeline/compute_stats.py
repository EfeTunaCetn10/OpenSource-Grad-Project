from __future__ import annotations

import argparse
import json
from pathlib import Path

import torch
from torch.utils.data import DataLoader
from torchvision import datasets, transforms


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Calculate 32x32 training-set RGB statistics")
    parser.add_argument("--train-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--batch-size", type=int, default=256)
    parser.add_argument("--workers", type=int, default=2)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    transform = transforms.Compose([transforms.Resize((32, 32)), transforms.ToTensor()])
    dataset = datasets.ImageFolder(args.train_dir, transform=transform)
    if not dataset.samples:
        raise ValueError("training dataset is empty")
    loader = DataLoader(dataset, batch_size=args.batch_size, num_workers=args.workers)

    channel_sum = torch.zeros(3, dtype=torch.float64)
    channel_sq_sum = torch.zeros(3, dtype=torch.float64)
    pixel_count = 0
    for images, _ in loader:
        images = images.to(torch.float64)
        channel_sum += images.sum(dim=(0, 2, 3))
        channel_sq_sum += (images * images).sum(dim=(0, 2, 3))
        pixel_count += images.shape[0] * images.shape[2] * images.shape[3]

    mean = channel_sum / pixel_count
    variance = channel_sq_sum / pixel_count - mean.square()
    std = variance.clamp_min(0).sqrt()
    payload = {
        "mean": mean.tolist(),
        "std": std.tolist(),
        "image_size": [32, 32],
        "images": len(dataset),
        "source_split": "train",
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    print(json.dumps(payload, indent=2))


if __name__ == "__main__":
    main()

