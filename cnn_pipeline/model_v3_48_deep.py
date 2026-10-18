"""Experimental v3-48 with one extra Conv/ReLU immediately before Pool3."""
from torch import nn

from model_v3_48 import CompactCNNV3_48


class CompactCNNV3_48Deep(CompactCNNV3_48):
    def __init__(self, num_classes: int = 10):
        super().__init__(num_classes)
        layers = list(self.features.children())
        self.features = nn.Sequential(
            *layers[:-1],
            nn.Conv2d(32, 32, 3, stride=1, padding=1),
            nn.ReLU(inplace=True),
            layers[-1],
        )
