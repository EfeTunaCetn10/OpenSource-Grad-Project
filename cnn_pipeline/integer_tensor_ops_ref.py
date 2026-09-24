"""Independent signed INT8 CHW pooling/flattening; no quantization or backend."""


def _validate_chw(x) -> tuple[int, int, int]:
    def validate(value, rank, path):
        if rank == 0:
            if type(value) is not int:
                raise TypeError(f'{path} must be a built-in Python int')
            if not -128 <= value <= 127:
                raise ValueError(f'{path} outside signed INT8 [-128,127]')
            return ()
        if type(value) not in (list, tuple):
            raise TypeError(f'{path} must be a list or tuple (remaining rank={rank})')
        if not value:
            raise ValueError(f'{path} must not be empty')
        shape = validate(value[0], rank - 1, f'{path}[0]')
        for i in range(1, len(value)):
            if validate(value[i], rank - 1, f'{path}[{i}]') != shape:
                raise ValueError(f'{path}[{i}] is ragged')
        return (len(value), *shape)
    return validate(x, 3, 'x')


def integer_maxpool2d_ref(x: list | tuple) -> list:
    """2x2 max, stride=2, padding=0; only even H/W >=2, no batch/indices."""
    channels, height, width = _validate_chw(x)
    if height < 2 or width < 2 or height % 2 or width % 2:
        raise ValueError('MaxPool requires even H/W >=2; deliberately limited LeNet scope')
    return [[[max(x[c][h][w], x[c][h][w + 1],
                  x[c][h + 1][w], x[c][h + 1][w + 1])
              for w in range(0, width, 2)]
             for h in range(0, height, 2)] for c in range(channels)]


def integer_flatten_chw_ref(x: list | tuple) -> list[int]:
    """Return a fresh list in c -> h -> w order; accepts any nonempty CHW shape."""
    _validate_chw(x)
    return [value for plane in x for row in plane for value in row]
