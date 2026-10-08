"""Experimental FP32 v2 topology; independent of the frozen v1 golden model."""
import torch
from torch import nn


class LeNetV2(nn.Module):
    """RGB 32x32, 10-class Conv(8,24) / Linear(64,32,10) experiment."""

    def __init__(self):
        super().__init__()
        self.input_channels = 3
        self.num_classes = 10
        self.features = nn.Sequential(
            nn.Conv2d(3, 8, 5, stride=1, padding=0),
            nn.ReLU(inplace=True), nn.MaxPool2d(2, 2),
            nn.Conv2d(8, 24, 5, stride=1, padding=0),
            nn.ReLU(inplace=True), nn.MaxPool2d(2, 2),
        )
        self.classifier = nn.Sequential(
            nn.Flatten(), nn.Linear(600, 64), nn.ReLU(inplace=True),
            nn.Linear(64, 32), nn.ReLU(inplace=True), nn.Linear(32, 10),
        )

    def forward(self, inputs: torch.Tensor) -> torch.Tensor:
        if inputs.ndim != 4 or inputs.shape[1:] != (3, 32, 32):
            raise ValueError('expected input shape [N, 3, 32, 32]')
        return self.classifier(self.features(inputs))
