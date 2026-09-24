"""Bias-free x[K] * W[out,K] reference using only built-in Python integers.

Strict diagnostic INT32 checks reject overflow; they do not define RTL policy.
No quantization, bias, requantization, batching or hardware layout conversion.
"""

INT32_MIN = -(1 << 31)
INT32_MAX = (1 << 31) - 1


def checked_int32(value: int, *, name: str = 'sum') -> int:
    """Check representability without cast, wrap or saturation."""
    if type(value) is not int:
        raise TypeError(f'{name} must be a built-in Python int')
    if not INT32_MIN <= value <= INT32_MAX:
        raise OverflowError(f'{name}={value} is outside signed INT32 '
                            f'[{INT32_MIN}, {INT32_MAX}]; RTL overflow policy unresolved')
    return value


def _container(value, name: str) -> None:
    if type(value) not in (list, tuple):
        raise TypeError(f'{name} must be a list or tuple')
    if not value:
        raise ValueError(f'{name} must not be empty')


def _int8(value, name: str) -> None:
    if type(value) is not int:
        raise TypeError(f'{name} must be a built-in Python int (bool/float not accepted)')
    if not -128 <= value <= 127:
        raise ValueError(f'{name}={value} is outside signed INT8 [-128, 127]')


def integer_linear_ref(x: list | tuple, weights: list | tuple) -> list[int]:
    """Return sums in input row order; weights must have shape [out,K].

    All data are validated before calculation. Exact sums are computed with
    Python int. Final sums and k-increasing partial sums must fit INT32.
    Even cancellation after a partial overflow is rejected diagnostically;
    this traversal is not a claim about physical RTL accumulation order.
    """
    _container(x, 'x')
    _container(weights, 'weights')
    for k, value in enumerate(x):
        _int8(value, f'x[{k}]')
    for c, row in enumerate(weights):
        _container(row, f'weights[{c}]')
        if len(row) != len(x):
            raise ValueError(f'weights[{c}] length {len(row)} differs from K={len(x)}')
        for k, value in enumerate(row):
            _int8(value, f'weights[{c}][{k}]')
    outputs = []
    for c, row in enumerate(weights):
        total = 0
        first_overflow = None
        for k, (value, weight) in enumerate(zip(x, row)):
            total += value * weight
            if first_overflow is None and not INT32_MIN <= total <= INT32_MAX:
                first_overflow = (k, total)
        checked_int32(total, name=f'output[{c}] exact sum')
        if first_overflow is not None:
            k, value = first_overflow
            checked_int32(value, name=f'output[{c}] partial sum at k={k} (final={total})')
        outputs.append(total)
    return outputs
