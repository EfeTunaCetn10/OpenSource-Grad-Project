"""Experimental 48x48 CompactCNN-v3; the original 32x32 model is unchanged."""
import torch
from torch import nn

from model_v3 import CompactCNNV3


class CompactCNNV3_48(CompactCNNV3):
    """Reuse v3 Conv/Pool blocks, with a 1152 -> 64 -> num_classes head."""

    def __init__(self, num_classes: int = 10):
        super().__init__(num_classes)
        self.classifier[1] = nn.Linear(32 * 6 * 6, 64)

    def forward(self, inputs: torch.Tensor) -> torch.Tensor:
        if inputs.ndim != 4 or inputs.shape[1:] != (3, 48, 48):
            raise ValueError('expected input shape [N, 3, 48, 48]')
        return self.classifier(self.features(inputs))
