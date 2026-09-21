import pytest
import torch

from model import LeNet5, count_parameters


@pytest.mark.parametrize("channels,classes", [(1, 10), (3, 5), (3, 102)])
def test_output_shape(channels: int, classes: int) -> None:
    model = LeNet5(channels, classes)
    output = model(torch.randn(4, channels, 32, 32))
    assert output.shape == (4, classes)
    assert count_parameters(model) > 0


def test_rejects_wrong_spatial_shape() -> None:
    model = LeNet5(3, 5)
    with pytest.raises(ValueError):
        model(torch.randn(1, 3, 28, 28))

