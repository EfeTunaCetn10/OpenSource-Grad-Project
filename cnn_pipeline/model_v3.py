"""Experimental CompactCNN-v3; separate from the frozen v1 candidate."""
import torch
from torch import nn


class CompactCNNV3(nn.Module):
    """RGB 32x32 classifier using only Conv/ReLU/MaxPool/Flatten/Linear."""

    def __init__(self, num_classes: int = 10):
        super().__init__()
        if type(num_classes) is not int or num_classes < 2:
            raise ValueError('num_classes must be an integer >= 2')
        self.input_channels = 3
        self.num_classes = num_classes
        self.features = nn.Sequential(
            nn.Conv2d(3, 16, 3, stride=1, padding=1),
            nn.ReLU(inplace=True), nn.MaxPool2d(2, 2),
            nn.Conv2d(16, 24, 3, stride=1, padding=1),
            nn.ReLU(inplace=True), nn.MaxPool2d(2, 2),
            nn.Conv2d(24, 32, 3, stride=1, padding=1),
            nn.ReLU(inplace=True), nn.MaxPool2d(2, 2),
        )
        self.classifier = nn.Sequential(
            nn.Flatten(), nn.Linear(512, 64), nn.ReLU(inplace=True),
            nn.Linear(64, num_classes),
        )

    def forward(self, inputs: torch.Tensor) -> torch.Tensor:
        if inputs.ndim != 4 or inputs.shape[1:] != (3, 32, 32):
            raise ValueError('expected input shape [N, 3, 32, 32]')
        return self.classifier(self.features(inputs))
