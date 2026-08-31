from __future__ import annotations

import argparse
import json
import random
from pathlib import Path

import torch
from torch import nn

from data import build_insect_loaders, build_mnist_loaders
from model import LeNet5, count_parameters


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Train a 32x32 LeNet-5 baseline")
    parser.add_argument("--dataset", choices=("mnist", "insects"), required=True)
    parser.add_argument("--data-dir", type=Path, default=Path("data"))
    parser.add_argument("--stats", type=Path)
    parser.add_argument("--output-dir", type=Path, default=Path("outputs"))
    parser.add_argument("--epochs", type=int, default=10)
    parser.add_argument("--batch-size", type=int, default=128)
    parser.add_argument("--learning-rate", type=float, default=1e-3)
    parser.add_argument("--weight-decay", type=float, default=1e-4)
    parser.add_argument("--workers", type=int, default=2)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--limit-train", type=int)
    parser.add_argument("--limit-eval", type=int)
    return parser.parse_args()


def set_seed(seed: int) -> None:
    random.seed(seed)
    torch.manual_seed(seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(seed)


def run_epoch(
    model: nn.Module,
    loader: torch.utils.data.DataLoader,
    criterion: nn.Module,
    device: torch.device,
    optimizer: torch.optim.Optimizer | None = None,
) -> dict[str, float]:
    training = optimizer is not None
    model.train(training)
    total_loss = 0.0
    correct = 0
    total = 0

    with torch.set_grad_enabled(training):
        for inputs, targets in loader:
            inputs = inputs.to(device, non_blocking=True)
            targets = targets.to(device, non_blocking=True)
            if training:
                optimizer.zero_grad(set_to_none=True)
            logits = model(inputs)
            loss = criterion(logits, targets)
            if training:
                loss.backward()
                optimizer.step()
            total_loss += loss.item() * targets.size(0)
            correct += (logits.argmax(dim=1) == targets).sum().item()
            total += targets.size(0)

    return {"loss": total_loss / total, "accuracy": correct / total}


@torch.inference_mode()
def evaluate_with_macro_recall(
    model: nn.Module,
    loader: torch.utils.data.DataLoader,
    criterion: nn.Module,
    device: torch.device,
    num_classes: int,
) -> dict[str, float | list[list[int]]]:
    metrics = run_epoch(model, loader, criterion, device)
    confusion = torch.zeros((num_classes, num_classes), dtype=torch.int64)
    model.eval()
    for inputs, targets in loader:
        predictions = model(inputs.to(device, non_blocking=True)).argmax(dim=1).cpu()
        indices = targets * num_classes + predictions
        confusion += torch.bincount(indices, minlength=num_classes**2).reshape(num_classes, num_classes)
    support = confusion.sum(dim=1)
    recalls = confusion.diag().float() / support.clamp_min(1)
    metrics["macro_recall"] = recalls[support > 0].mean().item()
    metrics["confusion_matrix"] = confusion.tolist()
    return metrics


def main() -> None:
    args = parse_args()
    if args.epochs <= 0 or args.batch_size <= 0:
        raise ValueError("epochs and batch size must be positive")
    set_seed(args.seed)
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    pin_memory = device.type == "cuda"

    if args.dataset == "mnist":
        bundle = build_mnist_loaders(
            args.data_dir / "mnist",
            args.batch_size,
            args.workers,
            pin_memory,
            args.limit_train,
            args.limit_eval,
        )
    else:
        if args.stats is None:
            raise ValueError("--stats is required for the insects dataset")
        bundle = build_insect_loaders(
            args.data_dir,
            args.stats,
            args.batch_size,
            args.workers,
            pin_memory,
            args.limit_train,
            args.limit_eval,
        )

    output_dir = args.output_dir / args.dataset
    output_dir.mkdir(parents=True, exist_ok=True)
    model = LeNet5(bundle.input_channels, len(bundle.class_names)).to(device)
    criterion = nn.CrossEntropyLoss()
    optimizer = torch.optim.AdamW(
        model.parameters(), lr=args.learning_rate, weight_decay=args.weight_decay
    )
    scheduler = torch.optim.lr_scheduler.ReduceLROnPlateau(optimizer, mode="max", patience=3)
    print(f"device={device} parameters={count_parameters(model):,} classes={len(bundle.class_names)}")

    history: list[dict[str, float | int]] = []
    best_accuracy = -1.0
    checkpoint_path = output_dir / "best.pt"
    for epoch in range(1, args.epochs + 1):
        train_metrics = run_epoch(model, bundle.train_loader, criterion, device, optimizer)
        val_metrics = run_epoch(model, bundle.val_loader, criterion, device)
        scheduler.step(val_metrics["accuracy"])
        record = {
            "epoch": epoch,
            "train_loss": train_metrics["loss"],
            "train_accuracy": train_metrics["accuracy"],
            "val_loss": val_metrics["loss"],
            "val_accuracy": val_metrics["accuracy"],
            "learning_rate": optimizer.param_groups[0]["lr"],
        }
        history.append(record)
        print(
            f"epoch={epoch:03d} train_loss={record['train_loss']:.4f} "
            f"train_acc={record['train_accuracy']:.4f} val_loss={record['val_loss']:.4f} "
            f"val_acc={record['val_accuracy']:.4f}"
        )
        if val_metrics["accuracy"] > best_accuracy:
            best_accuracy = val_metrics["accuracy"]
            torch.save(
                {
                    "model_state": model.state_dict(),
                    "model_name": "LeNet5ReLUMaxPool",
                    "input_channels": bundle.input_channels,
                    "image_size": [32, 32],
                    "class_names": bundle.class_names,
                    "mean": bundle.mean,
                    "std": bundle.std,
                    "best_val_accuracy": best_accuracy,
                    "seed": args.seed,
                },
                checkpoint_path,
            )

    (output_dir / "history.json").write_text(json.dumps(history, indent=2), encoding="utf-8")
    checkpoint = torch.load(checkpoint_path, map_location=device, weights_only=True)
    model.load_state_dict(checkpoint["model_state"])
    test_metrics = evaluate_with_macro_recall(
        model, bundle.test_loader, criterion, device, len(bundle.class_names)
    )
    (output_dir / "test_metrics.json").write_text(
        json.dumps(test_metrics, indent=2), encoding="utf-8"
    )
    print(
        f"best_val_acc={best_accuracy:.4f} test_acc={test_metrics['accuracy']:.4f} "
        f"test_macro_recall={test_metrics['macro_recall']:.4f}"
    )


if __name__ == "__main__":
    main()

