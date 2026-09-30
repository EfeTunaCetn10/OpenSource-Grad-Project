"""Bias-free x[K] * W[out,K] reference using only built-in Python integers.

ADR-003 (2026-09-25): accumulator arithmetic wraps modulo 2^32.
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
                            f'[{INT32_MIN}, {INT32_MAX}]; configuration value is not representable')
    return value



def wrap32(value: int) -> int:
    """Signed two's-complement modulo; not saturation or a range assertion."""
    if type(value) is not int:
        raise TypeError('wrap32 requires a built-in Python int')
    return ((value + (1 << 31)) % (1 << 32)) - (1 << 31)


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

    All data are validated before calculation. Exact Python int sums are
    wrapped once at the INT32 output boundary, equivalent to per-add wrap.
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
        for value, weight in zip(x, row):
            total += value * weight
        outputs.append(wrap32(total))
    return outputs
