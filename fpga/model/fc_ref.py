"""Stdlib-only INT8 fully connected reference for the 8-row array.

The caller supplies activations and weights in the same reduction order. For
FC1 this is ADR-018 padded tile-major order; FC2 and FC3 are dense.
"""

from __future__ import annotations

from requant_ref import requant_ref


def tile_major_index(c: int, h: int, w: int, height: int = 5,
                     width: int = 5) -> int:
    """Physical address within a padded 8-channel tile-major map."""
    return ((c // 8 * height + h) * width + w) * 8 + c % 8


def fc1_tile_major(dense: list[int], n_out: int = 1) -> list[int]:
    """Transform output-major [o,c,h,w] values to [o,tile,h,w,lane]."""
    if len(dense) != n_out * 400:
        raise ValueError("FC1 tensor must contain n_out*16*5*5 values")
    out = [0] * len(dense)
    for o in range(n_out):
        for c in range(16):
            for h in range(5):
                for w in range(5):
                    out[o * 400 + tile_major_index(c, h, w)] = (
                        dense[o * 400 + (c * 5 + h) * 5 + w]
                    )
    return out


def fc_accumulators(x: list[int], w: list[int], n_in: int,
                    n_out: int) -> list[int]:
    """Signed INT32 MAC results before bias and requantization."""
    if n_in <= 0 or n_out <= 0 or len(x) != n_in or len(w) != n_in * n_out:
        raise ValueError("invalid FC dimensions")
    if any(v < -128 or v > 127 for v in x) or any(v < -128 or v > 127 for v in w):
        raise ValueError("FC operands must be INT8")
    out = []
    for o in range(n_out):
        acc = sum(x[k] * w[o * n_in + k] for k in range(n_in))
        # PE accumulators are signed INT32.
        out.append(((acc + 2**31) % 2**32) - 2**31)
    return out


def fc_layer(x: list[int], w: list[int], bias_q: list[int],
             m0: list[int], shift_n: list[int], relu: list[bool],
             n_in: int, n_out: int) -> list[int]:
    """One FC layer as 1x1 convolution, INT8 in and INT8 out.

    Requant settings are indexed by row within each 8-output tile.
    """
    if any(len(cfg) != 8 for cfg in (bias_q, m0, shift_n, relu)):
        raise ValueError("requant configuration must have eight rows")
    accs = fc_accumulators(x, w, n_in, n_out)
    out = []
    for o, acc in enumerate(accs):
        r = o % 8
        biased = ((acc + bias_q[r] + 2**31) % 2**32) - 2**31
        out.append(requant_ref(biased, m0[r], shift_n[r], relu[r]))
    return out


if __name__ == "__main__":
    assert tile_major_index(8, 1, 0) == 240
    dense = list(range(400))
    assert fc1_tile_major(dense)[240] == dense[8 * 25 + 5]
    print("PASS fc_ref")
