"""Stdlib-only golden model for the HWC activation window stream.

The returned tuples are ``(k, values, active_cols)``.  ``values`` is always
eight signed INT8 values in output-column order; inactive lanes in a partial
right-edge tile are zero.  The reduction order is channel-major, matching the
weight address contract:

    k = ci * (kH * kW) + kh * kW + kw
"""

from __future__ import annotations


def _signed_byte(value: int) -> int:
    if not 0 <= value <= 255:
        if -128 <= value <= 127:
            return value
        raise ValueError("frame values must be bytes (0..255) or signed INT8")
    return value - 256 if value >= 128 else value


def window_stream(
    frame: list[int],
    in_h: int,
    in_w: int,
    c_in: int,
    k_h: int,
    k_w: int,
    stride: int,
    pad: int = 0,
) -> list[tuple[int, list[int], int]]:
    """Return the activation beats in output-row/tile/k order.

    ``frame`` is flat HWC: ``frame[(h*in_w + w)*c_in + ci]``.  Zero padding
    is modelled for completeness; the Stage-1 RTL contract uses ``pad=0``.
    """
    if min(in_h, in_w, c_in, k_h, k_w, stride) <= 0 or pad < 0:
        raise ValueError("dimensions and stride must be positive; pad non-negative")
    if len(frame) != in_h * in_w * c_in:
        raise ValueError("frame length does not match HWC dimensions")

    out_h = (in_h + 2 * pad - k_h) // stride + 1
    out_w = (in_w + 2 * pad - k_w) // stride + 1
    if out_h <= 0 or out_w <= 0:
        raise ValueError("kernel does not fit the padded input")

    stream: list[tuple[int, list[int], int]] = []
    for oh in range(out_h):
        for tile_x in range(0, out_w, 8):
            active_cols = min(8, out_w - tile_x)
            for ci in range(c_in):
                for kh in range(k_h):
                    for kw in range(k_w):
                        values = [0] * 8
                        for lane in range(active_cols):
                            h = oh * stride - pad + kh
                            w = (tile_x + lane) * stride - pad + kw
                            if 0 <= h < in_h and 0 <= w < in_w:
                                idx = (h * in_w + w) * c_in + ci
                                values[lane] = _signed_byte(frame[idx])
                        k = ci * (k_h * k_w) + kh * k_w + kw
                        stream.append((k, values, active_cols))
    return stream


def _self_check() -> None:
    # Every coordinate has a distinct low-byte identity, so both HWC indexing
    # and the channel-major k order are exercised by this compact case.
    in_h, in_w, c_in = 3, 11, 2
    frame = [((h * 50 + w * 7 + c) & 0xFF)
             for h in range(in_h) for w in range(in_w) for c in range(c_in)]
    stream = window_stream(frame, in_h, in_w, c_in, 2, 3, 1)
    assert len(stream) == 2 * 2 * (2 * 2 * 3)
    assert stream[0][0] == 0
    assert stream[0][1][:3] == [0, 7, 14]
    assert stream[6][0] == 6  # ci=1 starts after the six spatial elements
    assert stream[6][1][0] == 1
    assert stream[11][2] == 8  # 8-wide tile is full
    assert stream[12 + 6][2] == 1  # final tile has only one column
    assert stream[12 + 6][1][1:] == [0, 0, 0, 0, 0, 0, 0]
    assert all(0 <= k < c_in * 2 * 3 for k, _, _ in stream)
    print("PASS window_ref")


if __name__ == "__main__":
    _self_check()
