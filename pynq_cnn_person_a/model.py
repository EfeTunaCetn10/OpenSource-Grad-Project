from __future__ import annotations

import torch
from torch import nn


class LeNet5(nn.Module):
    """Hardware-friendly ReLU/max-pool LeNet-5 variant for 32x32 inputs."""

    def __init__(self, input_channels: int = 1, num_classes: int = 10) -> None:
        super().__init__()
        if input_channels <= 0:
            raise ValueError("input_channels must be positive")
        if num_classes < 2:
            raise ValueError("num_classes must be at least 2")

        self.input_channels = input_channels
        self.num_classes = num_classes
        self.features = nn.Sequential(
            nn.Conv2d(input_channels, 6, kernel_size=5),   # 32 -> 28
            nn.ReLU(inplace=True),
            nn.MaxPool2d(kernel_size=2, stride=2),         # 28 -> 14
            nn.Conv2d(6, 16, kernel_size=5),               # 14 -> 10
            nn.ReLU(inplace=True),
            nn.MaxPool2d(kernel_size=2, stride=2),         # 10 -> 5
        )
        self.classifier = nn.Sequential(
            nn.Flatten(),
            nn.Linear(16 * 5 * 5, 120),
            nn.ReLU(inplace=True),
            nn.Linear(120, 84),
            nn.ReLU(inplace=True),
            nn.Linear(84, num_classes),
        )

    def forward(self, inputs: torch.Tensor) -> torch.Tensor:
        if inputs.ndim != 4:
            raise ValueError("expected input shape [N, C, H, W]")
        if inputs.shape[1:] != (self.input_channels, 32, 32):
            raise ValueError(
                f"expected [N, {self.input_channels}, 32, 32], got {list(inputs.shape)}"
            )
        return self.classifier(self.features(inputs))


def count_parameters(model: nn.Module) -> int:
    return sum(parameter.numel() for parameter in model.parameters() if parameter.requires_grad)

