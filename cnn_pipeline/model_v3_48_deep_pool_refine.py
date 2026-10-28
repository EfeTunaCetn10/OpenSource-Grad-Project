"""Experimental deep-pool refinement at 6x6 before the final pooling step."""
from torch import nn

from model_v3_48_deep_pool import CompactCNNV3_48DeepPool


class CompactCNNV3_48DeepPoolRefine(CompactCNNV3_48DeepPool):
    def __init__(self, num_classes: int = 10):
        super().__init__(num_classes)
        layers = list(self.features.children())
        self.features = nn.Sequential(
            *layers[:-1],
            nn.Conv2d(32, 32, kernel_size=3, padding=1),
            nn.ReLU(inplace=True),
            layers[-1],
        )
