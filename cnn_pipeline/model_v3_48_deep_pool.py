"""Experimental 48x48 deep v3 with an extra pool to reduce FC1 K to 288."""
from torch import nn

from model_v3_48_deep import CompactCNNV3_48Deep


class CompactCNNV3_48DeepPool(CompactCNNV3_48Deep):
    def __init__(self, num_classes: int = 10):
        super().__init__(num_classes)
        self.features = nn.Sequential(
            *self.features.children(),
            nn.MaxPool2d(2, 2),
        )
        self.classifier[1] = nn.Linear(32 * 3 * 3, 64)
