"""Valid CHW integer cross-correlation; stride=1, padding=0, dilation=1 only."""
from integer_linear_ref import checked_int32


def _shape_int8(value, rank: int, name: str) -> tuple[int, ...]:
    if rank == 0:
        if type(value) is not int:
            raise TypeError(f'{name} must be a built-in Python int')
        if not -128 <= value <= 127:
            raise ValueError(f'{name}={value} outside signed INT8 [-128,127]')
        return ()
    if type(value) not in (list, tuple):
        raise TypeError(f'{name} must be a list or tuple (rank {rank})')
    if not value:
        raise ValueError(f'{name} must not be empty')
    child_shape = _shape_int8(value[0], rank - 1, f'{name}[0]')
    for i in range(1, len(value)):
        if _shape_int8(value[i], rank - 1, f'{name}[{i}]') != child_shape:
            raise ValueError(f'{name}[{i}] is ragged')
    return (len(value), *child_shape)


def integer_conv2d_ref(x: list | tuple, weights: list | tuple, *,
                       layer: str = 'conv2d') -> list:
    """Compute [out,H-kH+1,W-kW+1] Python int sums, without modifying inputs.

    Reduction order is ci, kh, kw; no kernel flip, im2col, bias or requantization.
    INT32 partial/final overflow is rejected diagnostically, not modeled as RTL.
    """
    if type(layer) is not str or not layer:
        raise TypeError('layer must be a nonempty string')
    ci_count, height, width = _shape_int8(x, 3, 'input')
    co_count, weight_ci, kh_count, kw_count = _shape_int8(weights, 4, 'weights')
    if ci_count != weight_ci:
        raise ValueError(f'{layer}: input channels {ci_count} != weight channels {weight_ci}')
    if kh_count > height or kw_count > width:
        raise ValueError(f'{layer}: kernel larger than input')
    outputs = []
    for co in range(co_count):
        plane = []
        for h in range(height - kh_count + 1):
            row = []
            for w in range(width - kw_count + 1):
                total = 0
                for ci in range(ci_count):
                    for kh in range(kh_count):
                        for kw in range(kw_count):
                            total += x[ci][h + kh][w + kw] * weights[co][ci][kh][kw]
                            checked_int32(total, name=(f'{layer} output[{co},{h},{w}] '
                                                       f'partial ci={ci},kh={kh},kw={kw}'))
                checked_int32(total, name=f'{layer} output[{co},{h},{w}] final sum')
                row.append(total)
            plane.append(row)
        outputs.append(plane)
    return outputs
