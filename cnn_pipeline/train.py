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
    parser.add_argument("--skip-test", action="store_true",
                        help="Only train/validate; reserve test evaluation for the final run")
    parser.add_argument("--class-weighted", action="store_true",
                        help="Weight training cross entropy by inverse training class frequency")
    parser.add_argument("--class-weight-power", type=float, default=1.0,
                        help="Exponent for inverse-frequency weights (0.5 = square root)")
    return parser.parse_args()


def training_class_weights(dataset, num_classes: int, power: float = 1.0) -> tuple[torch.Tensor, torch.Tensor]:
    """Read training labels without loading images or consuming augmentation RNG."""
    if not 0.0 <= power <= 1.0:
        raise ValueError("Class weight power must be between 0 and 1")
    def labels(ds):
        if isinstance(ds, torch.utils.data.Subset):
            return labels(ds.dataset)[torch.as_tensor(ds.indices, dtype=torch.long)]
        return torch.as_tensor(ds.targets, dtype=torch.long)

    targets = labels(dataset)
    if targets.numel() == 0 or targets.min() < 0 or targets.max() >= num_classes:
        raise ValueError("Training labels must be nonempty and within class range")
    counts = torch.bincount(targets, minlength=num_classes)
    if (counts == 0).any():
        raise ValueError("Every class needs training examples for inverse-frequency weights")
    return (targets.numel() / (num_classes * counts.float())).pow(power), counts


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
    loss_denominator = 0.0
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
            # CrossEntropyLoss(mean) divides by the sum of target weights.
            weight = getattr(criterion, "weight", None)
            denominator = targets.size(0) if weight is None else weight[targets].sum().item()
            total_loss += loss.item() * denominator
            loss_denominator += denominator
            correct += (logits.argmax(dim=1) == targets).sum().item()
            total += targets.size(0)

    return {"loss": total_loss / loss_denominator, "accuracy": correct / total}


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
    if not 0.0 <= args.class_weight_power <= 1.0:
        raise ValueError("Class weight power must be between 0 and 1")
    if not args.class_weighted and args.class_weight_power != 1.0:
        raise ValueError("--class-weight-power requires --class-weighted")
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
    if output_dir.exists() and any(output_dir.iterdir()):
        raise FileExistsError(f"Use a new output directory to preserve previous results: {output_dir}")
    output_dir.mkdir(parents=True, exist_ok=True)
    model = LeNet5(bundle.input_channels, len(bundle.class_names)).to(device)
    criterion = nn.CrossEntropyLoss()
    class_weights, class_counts = None, None
    if args.class_weighted:
        class_weights, class_counts = training_class_weights(
            bundle.train_loader.dataset, len(bundle.class_names), args.class_weight_power)
    train_criterion = nn.CrossEntropyLoss(
        weight=class_weights.to(device) if class_weights is not None else None)
    run_config = {
        **{key: str(value) if isinstance(value, Path) else value for key, value in vars(args).items()},
        "device": str(device), "class_names": bundle.class_names,
        "class_weights": class_weights.tolist() if class_weights is not None else None,
        "train_class_counts": class_counts.tolist() if class_counts is not None else None,
        "validation_loss": "unweighted cross entropy",
    }
    (output_dir / "run_config.json").write_text(json.dumps(run_config, indent=2) + "\n")
    optimizer = torch.optim.AdamW(
        model.parameters(), lr=args.learning_rate, weight_decay=args.weight_decay
    )
    scheduler = torch.optim.lr_scheduler.ReduceLROnPlateau(optimizer, mode="max", patience=3)
    print(f"device={device} parameters={count_parameters(model):,} classes={len(bundle.class_names)}")

    history: list[dict[str, float | int]] = []
    best_accuracy = -1.0
    checkpoint_path = output_dir / "best.pt"
    for epoch in range(1, args.epochs + 1):
        train_metrics = run_epoch(model, bundle.train_loader, train_criterion, device, optimizer)
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
                    "best_epoch": epoch,
                    "training_config": run_config,
                },
                checkpoint_path,
            )

    (output_dir / "history.json").write_text(json.dumps(history, indent=2), encoding="utf-8")
    if args.skip_test:
        print(f"best_val_acc={best_accuracy:.4f}; test evaluation skipped")
        return
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
