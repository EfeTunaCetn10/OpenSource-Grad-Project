"""Candidate bias quantization in accumulator units; no export or inference."""
from __future__ import annotations

import torch

from quantization import round_half_up

INT32_MIN = -(1 << 31)
INT32_MAX = (1 << 31) - 1


def _float64(value, name):
    """Preserve supplied floating values; never route scales through float32."""
    if isinstance(value, torch.Tensor):
        if value.dtype not in (torch.float32, torch.float64):
            raise TypeError(f'{name}: expected float32/float64 tensor')
        result = value.detach().to(device='cpu', dtype=torch.float64)
    else:
        def valid(item):
            return type(item) is float or (type(item) in (list, tuple) and
                                          all(valid(v) for v in item))
        if not valid(value):
            raise TypeError(f'{name}: expected Python floats or floating tensor')
        try:
            result = torch.tensor(value, dtype=torch.float64, device='cpu')
        except (ValueError, TypeError) as exc:
            raise ValueError(f'{name}: expected rectangular shape') from exc
    if not torch.isfinite(result).all():
        raise ValueError(f'{name}: NaN/Inf rejected')
    return result


def quantize_bias_candidate(bias, activation_scale, weight_scales) -> torch.Tensor:
    """Return CPU int32 [C_out], using candidate half-up rounding toward +inf.

    Accept 1-D float32/float64 tensors or sequences of Python floats for bias
    and weight_scales, and a Python float or scalar floating tensor for s_x.
    FP32 checkpoint bias values are promoted exactly to CPU float64. No input
    is modified. Unrepresentable scales, ratios or rounded outputs raise errors.
    """
    b = _float64(bias, 'bias')
    sx = _float64(activation_scale, 'activation_scale')
    sw = _float64(weight_scales, 'weight_scales')
    if b.ndim != 1 or not b.numel():
        raise ValueError('bias: expected nonempty 1-D output-channel vector')
    if sx.ndim != 0:
        raise ValueError('activation_scale: expected scalar')
    if sw.ndim != 1 or sw.shape != b.shape:
        raise ValueError('weight_scales: expected one scale per bias output channel')
    if (sx <= 0).any() or (sw <= 0).any():
        raise ValueError('Scales must be strictly positive')
    accumulator_scales = sx * sw
    invalid = ~torch.isfinite(accumulator_scales) | (accumulator_scales <= 0)
    if invalid.any():
        channel = invalid.nonzero()[0].item()
        raise ValueError(f'channel {channel}: scale product is not finite and positive')
    ratios = b / accumulator_scales
    if not torch.isfinite(ratios).all():
        channel = (~torch.isfinite(ratios)).nonzero()[0].item()
        raise ValueError(f'channel {channel}: non-finite scaled bias')
    rounded = round_half_up(ratios)
    outside = (rounded < INT32_MIN) | (rounded > INT32_MAX)
    if outside.any():
        channel = outside.nonzero()[0].item()
        raise OverflowError(f'channel {channel}: rounded bias {rounded[channel].item()} '
                            f'outside signed INT32 [{INT32_MIN}, {INT32_MAX}]; '
                            'no wrap or saturation')
    return rounded.to(torch.int32)
