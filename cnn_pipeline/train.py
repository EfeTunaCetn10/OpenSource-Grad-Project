from __future__ import annotations

import copy
import argparse
import hashlib
import json
import random
import math
from pathlib import Path
from dataclasses import replace

import torch
from torch import nn

from data import build_insect_loaders, build_mnist_loaders
from model import LeNet5, count_parameters


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Train a 32x32 LeNet-5 baseline")
    parser.add_argument("--dataset", choices=("mnist", "insects"), required=True)
    parser.add_argument("--model-version", choices=("v1", "v2", "v3", "v3_48", "v3_48_deep", "v3_48_deep_pool", "v3_48_deep_pool_refine"), default="v1")
    parser.add_argument("--data-dir", type=Path, default=Path("data"))
    parser.add_argument("--stats", type=Path)
    parser.add_argument("--output-dir", type=Path, default=Path("outputs"))
    parser.add_argument("--epochs", type=int, default=10)
    parser.add_argument("--batch-size", type=int, default=128)
    parser.add_argument("--learning-rate", type=float, default=1e-3)
    parser.add_argument("--weight-decay", type=float, default=1e-4)
    parser.add_argument("--label-smoothing", type=float, default=0.0,
                        help="Training cross-entropy smoothing only; validation remains unsmoothed")
    parser.add_argument("--kd-teacher", type=Path, help="Opt-in frozen v3_48_deep teacher checkpoint")
    parser.add_argument("--kd-temperature", type=float, default=2.0)
    parser.add_argument("--kd-alpha", type=float, default=0.20)
    parser.add_argument("--ema-decay", type=float, default=None, help="Opt in to fixed late EMA (0.99)")
    parser.add_argument("--ema-start-epoch", type=int, default=40)
    parser.add_argument("--workers", type=int, default=2)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--limit-train", type=int)
    parser.add_argument("--limit-eval", type=int)
    parser.add_argument("--skip-test", action="store_true",
                        help="Only train/validate; reserve test evaluation for the final run")
    parser.add_argument("--weighted-sampler", action="store_true",
                        help="Training only: inverse-frequency sampling with replacement, one dataset length per epoch")
    parser.add_argument("--class-weighted", action="store_true",
                        help="Weight training cross entropy by inverse training class frequency")
    parser.add_argument("--targeted-class-weighted", action="store_true",
                        help="Refine experiment: fixed 1.15 weights for beetle/bug/fly_sarco/hfly_sphaero")
    parser.add_argument("--class-weight-power", type=float, default=1.0,
                        help="Exponent for inverse-frequency weights (0.5 = square root)")
    parser.add_argument("--train-resize", action="store_true",
                        help="Resize full insect images instead of random crops; keep flip/color jitter")
    parser.add_argument("--no-color-jitter", action="store_true",
                        help="Disable training ColorJitter for the insect experiment only")
    parser.add_argument("--scheduler", choices=("plateau", "cosine"), default="plateau")
    return parser.parse_args()


def training_labels(dataset):
    if isinstance(dataset, torch.utils.data.Subset):
        return training_labels(dataset.dataset)[torch.as_tensor(dataset.indices, dtype=torch.long)]
    return torch.as_tensor(dataset.targets, dtype=torch.long)


def with_weighted_training_sampler(bundle, seed):
    """Replace only training sampling; keep transforms, epoch size and eval loaders."""
    loader = bundle.train_loader
    _, counts = training_class_weights(loader.dataset, len(bundle.class_names))
    weights = counts.double().reciprocal()[training_labels(loader.dataset)]
    sampler = torch.utils.data.WeightedRandomSampler(
        weights, num_samples=len(loader.dataset), replacement=True,
        generator=torch.Generator().manual_seed(seed))
    train_loader = torch.utils.data.DataLoader(
        loader.dataset, batch_size=loader.batch_size, sampler=sampler,
        num_workers=loader.num_workers, pin_memory=loader.pin_memory,
        persistent_workers=loader.persistent_workers, generator=loader.generator,
        collate_fn=loader.collate_fn, drop_last=loader.drop_last)
    return replace(bundle, train_loader=train_loader), counts


def targeted_class_weights(class_names):
    """Fixed experiment weights, mapped by class name rather than assumed index."""
    weights = {"bee": 1.0, "beetle": 1.15, "beetle_cocci": 1.0,
               "bug": 1.15, "fly": 1.0, "fly_sarco": 1.15,
               "fly_small": 1.0, "hfly_episyr": 1.0,
               "hfly_eupeo": 1.0, "hfly_sphaero": 1.15}
    if len(class_names) != len(weights) or set(class_names) != set(weights):
        raise ValueError("Targeted weighting requires the exact ten insect classes")
    return torch.tensor([weights[name] for name in class_names], dtype=torch.float32)


def training_class_weights(dataset, num_classes: int, power: float = 1.0) -> tuple[torch.Tensor, torch.Tensor]:
    """Read training labels without loading images or consuming augmentation RNG."""
    if not 0.0 <= power <= 1.0:
        raise ValueError("Class weight power must be between 0 and 1")
    targets = training_labels(dataset)
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


def kd_loss(student_logits, teacher_logits, labels, temperature=2.0, alpha=0.20):
    """Positive CE + KL(teacher || student); teacher targets are detached."""
    if not math.isfinite(temperature) or temperature <= 0:
        raise ValueError("KD temperature must be finite and positive")
    if not math.isfinite(alpha) or not 0 <= alpha <= 1:
        raise ValueError("KD alpha must be finite and in [0,1]")
    ce = nn.functional.cross_entropy(student_logits, labels)
    kl = nn.KLDivLoss(reduction="batchmean")(
        nn.functional.log_softmax(student_logits / temperature, dim=1),
        nn.functional.softmax(teacher_logits.detach() / temperature, dim=1))
    return (1-alpha)*ce + alpha*temperature**2*kl


def load_kd_teacher(path, bundle, device):
    checkpoint = torch.load(path, map_location="cpu", weights_only=True)
    if (checkpoint.get("model_name") != "CompactCNNV3_48Deep" or
        checkpoint.get("training_config", {}).get("model_version") != "v3_48_deep" or
        checkpoint.get("image_size") != [48,48] or checkpoint.get("input_channels") != 3 or
        checkpoint.get("class_names") != bundle.class_names or
        list(checkpoint.get("mean", [])) != list(bundle.mean) or
        list(checkpoint.get("std", [])) != list(bundle.std)):
        raise ValueError("KD teacher topology/classes/preprocessing metadata mismatch")
    # Teacher construction must not alter student initialization/augmentation RNG.
    with torch.random.fork_rng(devices=[]):
        teacher = build_model("v3_48_deep", 3, len(bundle.class_names))
    teacher.load_state_dict(checkpoint["model_state"], strict=True)
    return teacher.to(device).eval().requires_grad_(False)


class LateEMA:
    """Independent no-gradient copy, initialized only at the chosen epoch end."""
    def __init__(self, decay=0.99, start_epoch=40):
        self.decay = decay
        self.start_epoch = start_epoch
        self.model = None
        self.updates = 0

    def end_epoch(self, student, epoch):
        if epoch == self.start_epoch and self.model is None:
            self.model = copy.deepcopy(student).eval().requires_grad_(False)
            for p in self.model.parameters():
                p.grad = None

    @torch.no_grad()
    def update(self, student):
        if self.model is None:
            return
        for averaged, current in zip(self.model.parameters(), student.parameters()):
            averaged.mul_(self.decay).add_(current.detach(), alpha=1-self.decay)
        self.updates += 1


def run_epoch(
    model: nn.Module,
    loader: torch.utils.data.DataLoader,
    criterion: nn.Module,
    device: torch.device,
    optimizer: torch.optim.Optimizer | None = None,
    *, teacher: nn.Module | None = None, temperature=2.0, alpha=0.20, ema=None,
) -> dict[str, float]:
    training = optimizer is not None
    model.train(training)
    if teacher is not None and training:
        teacher.eval()
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
            if training and teacher is not None:
                with torch.no_grad():
                    teacher_logits = teacher(inputs)
                loss = kd_loss(logits, teacher_logits, targets, temperature, alpha)
            else:
                loss = criterion(logits, targets)
            if training:
                loss.backward()
                optimizer.step()
                if ema is not None:
                    ema.update(model)
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


def build_loss_functions(label_smoothing: float, class_weights=None):
    """Keep validation CE comparable regardless of the training target smoothing."""
    if not 0.0 <= label_smoothing <= 1.0:
        raise ValueError("label smoothing must be finite and between 0 and 1")
    return (nn.CrossEntropyLoss(weight=class_weights, label_smoothing=label_smoothing),
            nn.CrossEntropyLoss())


def build_model(version: str, input_channels: int, num_classes: int) -> nn.Module:
    """Explicit experimental selection; v1 construction stays unchanged."""
    if version == "v1":
        return LeNet5(input_channels, num_classes)
    if version == "v2":
        from model_v2 import LeNetV2
        if input_channels != 3 or num_classes != 10:
            raise ValueError("experimental v2 requires RGB inputs and 10 classes")
        return LeNetV2()
    if version == "v3_48_deep_pool_refine":
        from model_v3_48_deep_pool_refine import CompactCNNV3_48DeepPoolRefine
        if input_channels != 3:
            raise ValueError("experimental v3_48_deep_pool_refine requires RGB inputs")
        return CompactCNNV3_48DeepPoolRefine(num_classes)
    if version == "v3_48_deep_pool":
        from model_v3_48_deep_pool import CompactCNNV3_48DeepPool
        if input_channels != 3:
            raise ValueError("experimental v3_48_deep_pool requires RGB inputs")
        return CompactCNNV3_48DeepPool(num_classes)
    if version == "v3_48_deep":
        from model_v3_48_deep import CompactCNNV3_48Deep
        if input_channels != 3:
            raise ValueError("experimental v3_48_deep requires RGB inputs")
        return CompactCNNV3_48Deep(num_classes)
    if version == "v3_48":
        from model_v3_48 import CompactCNNV3_48
        if input_channels != 3:
            raise ValueError("experimental v3_48 requires RGB inputs")
        return CompactCNNV3_48(num_classes)
    if version == "v3":
        from model_v3 import CompactCNNV3
        if input_channels != 3:
            raise ValueError("experimental v3 requires RGB inputs")
        return CompactCNNV3(num_classes)
    raise ValueError(f"Unknown model version: {version}")


def main() -> None:
    args = parse_args()
    if args.model_version in ("v2", "v3", "v3_48", "v3_48_deep", "v3_48_deep_pool", "v3_48_deep_pool_refine") and args.dataset != "insects":
        raise ValueError(f"experimental {args.model_version} supports the RGB insect dataset only")
    if args.model_version in ("v3", "v3_48", "v3_48_deep", "v3_48_deep_pool", "v3_48_deep_pool_refine") and args.output_dir.exists():
        raise FileExistsError(f"Use a new {args.model_version} experiment directory: {args.output_dir}")
    if not 0.0 <= args.label_smoothing <= 1.0:
        raise ValueError("label smoothing must be finite and between 0 and 1")
    if args.epochs <= 0 or args.batch_size <= 0:
        raise ValueError("epochs and batch size must be positive")
    if not 0.0 <= args.class_weight_power <= 1.0:
        raise ValueError("Class weight power must be between 0 and 1")
    if not args.class_weighted and args.class_weight_power != 1.0:
        raise ValueError("--class-weight-power requires --class-weighted")
    if args.train_resize and args.dataset != "insects":
        raise ValueError("--train-resize is only supported for insects")
    if args.no_color_jitter and args.dataset != "insects":
        raise ValueError("--no-color-jitter is only supported for insects")
    if args.weighted_sampler and args.class_weighted:
        raise ValueError("Use sampling or loss weighting, not both in this controlled experiment")
    if args.targeted_class_weighted:
        if (args.model_version != "v3_48_deep_pool_refine" or args.dataset != "insects"
                or args.class_weighted or args.weighted_sampler or args.kd_teacher is not None
                or args.label_smoothing != 0):
            raise ValueError("Targeted weighting requires refine, no KD/sampler/inverse weights/smoothing")
    if args.kd_teacher is not None:
        if (args.model_version != "v3_48_deep_pool_refine" or args.label_smoothing != 0
                or args.class_weighted or args.weighted_sampler):
            raise ValueError("Controlled KD requires refine student and ordinary unsmoothed CE/sampling")
        if not args.kd_teacher.is_file():
            raise FileNotFoundError(args.kd_teacher)
        if not math.isfinite(args.kd_temperature) or args.kd_temperature <= 0:
            raise ValueError("KD temperature must be finite and positive")
        if not math.isfinite(args.kd_alpha) or not 0 <= args.kd_alpha <= 1:
            raise ValueError("KD alpha must be finite and in [0,1]")
    if args.ema_decay is not None:
        if (args.model_version != "v3_48_deep_pool_refine" or args.epochs != 60
                or args.ema_decay != 0.99 or args.ema_start_epoch != 40
                or args.class_weighted or args.targeted_class_weighted or args.weighted_sampler
                or args.kd_teacher or args.label_smoothing != 0 or not args.skip_test):
            raise ValueError("Bounded EMA requires refine, 60 epochs, decay=.99, start=40, ordinary CE/sampling and --skip-test")
    elif args.ema_start_epoch != 40:
        raise ValueError("--ema-start-epoch requires --ema-decay")
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
            train_resize=args.train_resize,
            train_color_jitter=not args.no_color_jitter,
            image_size=48 if args.model_version in ("v3_48", "v3_48_deep", "v3_48_deep_pool", "v3_48_deep_pool_refine") else 32,
        )

    sampler_counts = None
    if args.weighted_sampler:
        bundle, sampler_counts = with_weighted_training_sampler(bundle, args.seed)

    output_dir = args.output_dir / args.dataset
    if output_dir.exists() and any(output_dir.iterdir()):
        raise FileExistsError(f"Use a new output directory to preserve previous results: {output_dir}")
    model = build_model(args.model_version, bundle.input_channels, len(bundle.class_names)).to(device)
    teacher = load_kd_teacher(args.kd_teacher, bundle, device) if args.kd_teacher else None
    output_dir.mkdir(parents=True, exist_ok=True)
    class_weights, class_counts = None, sampler_counts
    if args.class_weighted:
        class_weights, class_counts = training_class_weights(
            bundle.train_loader.dataset, len(bundle.class_names), args.class_weight_power)
    if args.targeted_class_weighted:
        class_weights = targeted_class_weights(bundle.class_names)
    train_criterion, criterion = build_loss_functions(
        args.label_smoothing,
        class_weights.to(device) if class_weights is not None else None)
    run_config = {
        **{key: str(value) if isinstance(value, Path) else value for key, value in vars(args).items()},
        "device": str(device), "class_names": bundle.class_names,
        "class_weights": class_weights.tolist() if class_weights is not None else None,
        "train_class_counts": class_counts.tolist() if class_counts is not None else None,
        "validation_loss": "unweighted cross entropy",
        "ema": ({"decay": args.ema_decay, "initialize_at_epoch_end": 40,
                 "update_epochs": [41,60], "evaluation_epoch": 60,
                 "selection": "fixed epoch; no EMA validation selection"}
                if args.ema_decay is not None else None),
        "distillation": ({"teacher_checkpoint": str(args.kd_teacher.resolve()),
                          "teacher_sha256": hashlib.sha256(args.kd_teacher.read_bytes()).hexdigest(),
                          "temperature": args.kd_temperature, "alpha": args.kd_alpha,
                          "loss": "(1-alpha)*CE + alpha*T^2*KL(teacher||student)",
                          "student_initialization": "from scratch"} if teacher is not None else None),
        "sampling_policy": ({"weights": "1/train_class_count", "replacement": True,
                             "samples_per_epoch": len(bundle.train_loader.dataset), "seed": args.seed}
                            if args.weighted_sampler else None),
        "source_sha256": {
            name: hashlib.sha256(Path(__file__).with_name(name).read_bytes()).hexdigest()
            for name in (("train.py", "data.py", "model.py") +
                         (() if args.model_version == "v1" else (f"model_{args.model_version}.py",)) +
                         (("model_v3.py",) if args.model_version in ("v3_48", "v3_48_deep", "v3_48_deep_pool", "v3_48_deep_pool_refine") else ()) +
                         (("model_v3_48.py",) if args.model_version in ("v3_48_deep", "v3_48_deep_pool", "v3_48_deep_pool_refine") else ()) +
                         (("model_v3_48_deep.py",) if args.model_version in ("v3_48_deep_pool", "v3_48_deep_pool_refine") else ()) +
                         (("model_v3_48_deep_pool.py",) if args.model_version == "v3_48_deep_pool_refine" else ()))
        },
    }
    (output_dir / "run_config.json").write_text(json.dumps(run_config, indent=2) + "\n")
    optimizer = torch.optim.AdamW(
        model.parameters(), lr=args.learning_rate, weight_decay=args.weight_decay
    )
    scheduler = (
        torch.optim.lr_scheduler.CosineAnnealingLR(
            optimizer, T_max=args.epochs, eta_min=args.learning_rate * 0.01)
        if args.scheduler == "cosine" else
        torch.optim.lr_scheduler.ReduceLROnPlateau(optimizer, mode="max", patience=3)
    )
    print(f"device={device} parameters={count_parameters(model):,} classes={len(bundle.class_names)}")

    history: list[dict[str, float | int]] = []
    best_accuracy = -1.0
    checkpoint_path = output_dir / "best.pt"
    ema = LateEMA(args.ema_decay, args.ema_start_epoch) if args.ema_decay is not None else None
    for epoch in range(1, args.epochs + 1):
        train_metrics = run_epoch(model, bundle.train_loader, train_criterion, device, optimizer,
                                  teacher=teacher, temperature=args.kd_temperature, alpha=args.kd_alpha, ema=ema)
        val_metrics = run_epoch(model, bundle.val_loader, criterion, device)
        if args.scheduler == "cosine":
            scheduler.step()
        else:
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
                    "model_name": {"v1": "LeNet5ReLUMaxPool", "v2": "LeNetV2Conv8x24FC64x32",
                                   "v3": "CompactCNNV3", "v3_48": "CompactCNNV3_48",
                                   "v3_48_deep": "CompactCNNV3_48Deep",
                                   "v3_48_deep_pool": "CompactCNNV3_48DeepPool",
                                   "v3_48_deep_pool_refine": "CompactCNNV3_48DeepPoolRefine",
                                   }[args.model_version],
                    "input_channels": bundle.input_channels,
                    "image_size": [48, 48] if args.model_version in ("v3_48", "v3_48_deep", "v3_48_deep_pool", "v3_48_deep_pool_refine") else [32, 32],
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

        if ema is not None:
            ema.end_epoch(model, epoch)

    (output_dir / "history.json").write_text(json.dumps(history, indent=2), encoding="utf-8")
    if ema is not None:
        # End-only evaluation: never use EMA validation results for selection.
        selected = torch.load(checkpoint_path, map_location=device, weights_only=True)
        best_model = copy.deepcopy(model)
        best_model.load_state_dict(selected["model_state"], strict=True)
        report = {"class_names": bundle.class_names, "split": "val",
                  "best_epoch": selected["best_epoch"], "fixed_epoch": 60,
                  "ema_updates": ema.updates}
        for name, evaluated in (("raw_epoch60", model), ("ema_epoch60", ema.model), ("normal_best", best_model)):
            result = evaluate_with_macro_recall(evaluated, bundle.val_loader, criterion, device, len(bundle.class_names))
            cm = result["confusion_matrix"]
            result["per_class"] = [{"class": label, "support": sum(cm[i]),
                                    "recall": cm[i][i]/sum(cm[i]) if sum(cm[i]) else None}
                                   for i,label in enumerate(bundle.class_names)]
            report[name] = result
        for name, evaluated in (("raw_epoch60", model), ("ema_epoch60", ema.model)):
            saved = {k:v for k,v in selected.items() if k not in ("model_state", "best_epoch", "best_val_accuracy")}
            saved.update(model_state=evaluated.state_dict(), epoch=60, checkpoint_role=name,
                         val_accuracy=report[name]["accuracy"])
            torch.save(saved, output_dir / (name + ".pt"))
        (output_dir / "ema_validation_comparison.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))
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
