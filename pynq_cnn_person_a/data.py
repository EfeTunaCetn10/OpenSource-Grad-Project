from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence

import torch
from torch.utils.data import DataLoader, Dataset, Subset
from torchvision import datasets, transforms


@dataclass(frozen=True)
class DataBundle:
    train_loader: DataLoader
    val_loader: DataLoader
    test_loader: DataLoader
    input_channels: int
    class_names: list[str]
    mean: list[float]
    std: list[float]


def _limited(dataset: Dataset, limit: int | None) -> Dataset:
    if limit is None or limit >= len(dataset):
        return dataset
    if limit <= 0:
        raise ValueError("dataset limits must be positive")
    return Subset(dataset, range(limit))


def _loader(
    dataset: Dataset,
    batch_size: int,
    shuffle: bool,
    workers: int,
    pin_memory: bool,
) -> DataLoader:
    generator = torch.Generator().manual_seed(42)
    return DataLoader(
        dataset,
        batch_size=batch_size,
        shuffle=shuffle,
        num_workers=workers,
        pin_memory=pin_memory,
        persistent_workers=workers > 0,
        generator=generator,
    )


def _read_stats(path: Path) -> tuple[list[float], list[float]]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    mean = [float(value) for value in payload["mean"]]
    std = [float(value) for value in payload["std"]]
    if len(mean) != 3 or len(std) != 3:
        raise ValueError("RGB stats must contain exactly three mean and std values")
    if any(value <= 0 for value in std):
        raise ValueError("all standard deviations must be positive")
    return mean, std


def build_mnist_loaders(
    data_dir: Path,
    batch_size: int,
    workers: int,
    pin_memory: bool,
    limit_train: int | None = None,
    limit_eval: int | None = None,
) -> DataBundle:
    mean, std = [0.1307], [0.3081]
    transform = transforms.Compose(
        [transforms.Resize((32, 32)), transforms.ToTensor(), transforms.Normalize(mean, std)]
    )
    full_train = datasets.MNIST(data_dir, train=True, download=True, transform=transform)
    test = datasets.MNIST(data_dir, train=False, download=True, transform=transform)

    generator = torch.Generator().manual_seed(42)
    train, val = torch.utils.data.random_split(full_train, [55_000, 5_000], generator=generator)
    train = _limited(train, limit_train)
    val = _limited(val, limit_eval)
    test = _limited(test, limit_eval)

    return DataBundle(
        _loader(train, batch_size, True, workers, pin_memory),
        _loader(val, batch_size, False, workers, pin_memory),
        _loader(test, batch_size, False, workers, pin_memory),
        1,
        [str(index) for index in range(10)],
        mean,
        std,
    )


def build_insect_loaders(
    data_dir: Path,
    stats_path: Path,
    batch_size: int,
    workers: int,
    pin_memory: bool,
    limit_train: int | None = None,
    limit_eval: int | None = None,
) -> DataBundle:
    for split in ("train", "val", "test"):
        if not (data_dir / split).is_dir():
            raise FileNotFoundError(f"missing dataset split: {data_dir / split}")

    mean, std = _read_stats(stats_path)
    train_transform = transforms.Compose(
        [
            transforms.RandomResizedCrop(32, scale=(0.80, 1.0)),
            transforms.RandomHorizontalFlip(),
            transforms.ColorJitter(brightness=0.15, contrast=0.15, saturation=0.10),
            transforms.ToTensor(),
            transforms.Normalize(mean, std),
        ]
    )
    eval_transform = transforms.Compose(
        [transforms.Resize((32, 32)), transforms.ToTensor(), transforms.Normalize(mean, std)]
    )

    train = datasets.ImageFolder(data_dir / "train", transform=train_transform)
    val = datasets.ImageFolder(data_dir / "val", transform=eval_transform)
    test = datasets.ImageFolder(data_dir / "test", transform=eval_transform)
    if train.class_to_idx != val.class_to_idx or train.class_to_idx != test.class_to_idx:
        raise ValueError("train, val, and test class folders do not match")

    class_names: Sequence[str] = train.classes
    train = _limited(train, limit_train)
    val = _limited(val, limit_eval)
    test = _limited(test, limit_eval)
    return DataBundle(
        _loader(train, batch_size, True, workers, pin_memory),
        _loader(val, batch_size, False, workers, pin_memory),
        _loader(test, batch_size, False, workers, pin_memory),
        3,
        list(class_names),
        mean,
        std,
    )

