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


# ----------------------------------------------------------------------------
# Physical (padded tile-major) buffer model -- ADR-018 Decision 2.
#
# The intermediate activation buffer does not store a dense HWC frame.  It
# stores
#
#     addr = (((c >> 3) * H + h) * W + w) * 8 + (c & 7)
#
# with the inactive lanes of the final channel tile present in memory as real
# bytes.  Two separate numbers therefore describe one tensor:
#
#     c_logical      -- how many channels are real; this and only this sets
#                       the reduction length K = c_logical * k_h * k_w
#     c_phys_stride  -- the byte distance between adjacent columns of a row
#
# Conv1 input is 3/3 and conv2 input is 6/8.  Deriving K from the physical
# stride would give conv2 K = 200 instead of 150: the output tensor would keep
# its shape, every value would be wrong, and nothing would flag it.  That is
# why these models are separate functions rather than one with a flag.
#
# The padding bytes are filled with a NONZERO sentinel on purpose.  Zero
# padding would make a physical/logical confusion invisible, because the
# wrongly fetched byte would be added to the accumulator as a harmless zero.
# ----------------------------------------------------------------------------


def physical_addr(h: int, w: int, c: int, in_h: int, in_w: int) -> int:
    """ADR-018 Decision 2 address, written exactly as the ADR states it."""
    return (((c >> 3) * in_h + h) * in_w + w) * 8 + (c & 7)


def pack_physical_frame(
    frame: list[int],
    in_h: int,
    in_w: int,
    c_logical: int,
    c_phys_stride: int,
    pad_bytes: list[int] | None = None,
) -> list[int]:
    """Pack a dense HWC ``frame`` into the padded tile-major buffer.

    ``pad_bytes`` supplies the sentinel values written into the inactive
    channel lanes, cycling if shorter than the number of pad lanes.  The
    default 0xAA/0xBB pair is the one the RTL testbench uses.
    """
    if c_phys_stride < c_logical:
        raise ValueError("c_phys_stride must be >= c_logical")
    if len(frame) != in_h * in_w * c_logical:
        raise ValueError("frame length does not match HWC dimensions")
    if pad_bytes is None:
        pad_bytes = [0xAA, 0xBB]
    if c_phys_stride > c_logical and not pad_bytes:
        raise ValueError("a padded layout needs at least one sentinel byte")

    phys = [0] * (in_h * in_w * c_phys_stride)
    for h in range(in_h):
        for w in range(in_w):
            base = (h * in_w + w) * c_phys_stride
            for c in range(c_phys_stride):
                if c < c_logical:
                    phys[base + c] = frame[(h * in_w + w) * c_logical + c]
                else:
                    phys[base + c] = pad_bytes[(c - c_logical) % len(pad_bytes)]

    # Stage 1 only ever has c_phys_stride == 8 with c_logical <= 8, i.e. a
    # single channel tile.  Check that the row-stride packing above really is
    # the ADR address in that case, so the two never drift apart.  For
    # c_logical > 8 the row ring cannot hold all channels at once anyway --
    # ADR-018 "Bedeli" item 5 records that as a Stage-2 blocker.
    if c_phys_stride == 8:
        for h in range(in_h):
            for w in range(in_w):
                for c in range(8):
                    assert physical_addr(h, w, c, in_h, in_w) == \
                        (h * in_w + w) * 8 + c
    return phys


def physical_window_stream(
    phys_frame: list[int],
    in_h: int,
    in_w: int,
    c_logical: int,
    c_phys_stride: int,
    k_h: int,
    k_w: int,
    stride: int,
    pad: int = 0,
) -> list[tuple[int, list[int], int]]:
    """``window_stream`` over a padded tile-major buffer.

    The addressing is physical (``w * c_phys_stride``), the channel range is
    logical (``ci < c_logical``), and K is logical.  This is the arithmetic
    ``line_buffer``/``window_gen`` implement.
    """
    if c_phys_stride < c_logical:
        raise ValueError("c_phys_stride must be >= c_logical")
    if min(in_h, in_w, c_logical, k_h, k_w, stride) <= 0 or pad < 0:
        raise ValueError("dimensions and stride must be positive; pad non-negative")
    if len(phys_frame) != in_h * in_w * c_phys_stride:
        raise ValueError("physical frame length does not match the padded layout")

    out_h = (in_h + 2 * pad - k_h) // stride + 1
    out_w = (in_w + 2 * pad - k_w) // stride + 1
    if out_h <= 0 or out_w <= 0:
        raise ValueError("kernel does not fit the padded input")

    stream: list[tuple[int, list[int], int]] = []
    for oh in range(out_h):
        for tile_x in range(0, out_w, 8):
            active_cols = min(8, out_w - tile_x)
            for ci in range(c_logical):          # logical, never physical
                for kh in range(k_h):
                    for kw in range(k_w):
                        values = [0] * 8
                        for lane in range(active_cols):
                            h = oh * stride - pad + kh
                            w = (tile_x + lane) * stride - pad + kw
                            if 0 <= h < in_h and 0 <= w < in_w:
                                # physical offset from a logical coordinate
                                idx = (h * in_w + w) * c_phys_stride + ci
                                values[lane] = _signed_byte(phys_frame[idx])
                        k = ci * (k_h * k_w) + kh * k_w + kw
                        stream.append((k, values, active_cols))
    return stream


def stream_checksum(stream: list[tuple[int, list[int], int]]) -> int:
    """Order-sensitive 32-bit digest of a beat stream.

    tb_window_gen computes this same digest over what the RTL actually emits
    and compares it with the constant printed by this module's self-check, so
    the Python model and the hardware are tied together by a number rather
    than by two independently written coordinate functions.
    """
    acc = 0
    mask = 0xFFFFFFFF
    for k, values, active_cols in stream:
        acc = (acc * 31 + k) & mask
        acc = (acc * 31 + active_cols) & mask
        for value in values:
            acc = (acc * 31 + (value & 0xFF)) & mask
    return acc


def _conv2_physical_check() -> None:
    """T_CONV2_REPLAY_001, model side.

    Conv2 input geometry: 14x14, C_LOGICAL=6, C_PHYS_STRIDE=8, 5x5, stride 1.
    Physical row 112 B, ring 5*112 = 560 B, frame 1568 B, K = 150 and
    OUT_H = OUT_W = 10.
    """
    in_h = in_w = 14
    c_logical, c_phys = 6, 8
    k_h = k_w = 5
    sentinels = [0xAA, 0xBB]

    # Values stay in 0..159 so neither sentinel can occur as real data; that
    # is what makes "no sentinel in the stream" a real check instead of a
    # coincidence.  The RTL testbench builds its frame from this same formula.
    dense = [((((h * in_w + w) * c_logical + c) * 53 + 19) % 160)
             for h in range(in_h) for w in range(in_w) for c in range(c_logical)]
    assert all(v not in sentinels for v in dense)

    phys = pack_physical_frame(dense, in_h, in_w, c_logical, c_phys, sentinels)
    assert len(phys) == 1568, len(phys)
    assert len(dense) == 1176
    assert phys[6] == 0xAA and phys[7] == 0xBB
    assert phys[(13 * in_w + 13) * c_phys + 6] == 0xAA

    phys_stream = physical_window_stream(
        phys, in_h, in_w, c_logical, c_phys, k_h, k_w, 1)
    dense_stream = window_stream(dense, in_h, in_w, c_logical, k_h, k_w, 1)

    # K is logical: 150 beats per tile, not 200.
    k_len = c_logical * k_h * k_w
    assert k_len == 150
    assert len(phys_stream) == 10 * 2 * k_len == 3000, len(phys_stream)
    for tile in range(len(phys_stream) // k_len):
        tile_beats = phys_stream[tile * k_len:(tile + 1) * k_len]
        assert [k for k, _, _ in tile_beats] == list(range(k_len))

    # The padding bytes never reach the engine.
    signed_sentinels = {_signed_byte(s) for s in sentinels}
    for k, values, _ in phys_stream:
        assert not signed_sentinels & set(values), (k, values)

    # Physical addressing with a logical channel range is bit-exact against
    # the dense model.  This is the property the RTL split has to reproduce.
    assert phys_stream == dense_stream

    # A stride below the channel count is a hard error, not a silent read of
    # the next column's bytes.
    try:
        pack_physical_frame(dense, in_h, in_w, c_logical, 4, sentinels)
    except ValueError:
        pass
    else:  # pragma: no cover
        raise AssertionError("c_phys_stride < c_logical must raise")

    # Normative checkpoints, quoted in tb_window_gen.
    #   oy=0, tile 0, k=0  -> ci=0,kh=0,kw=0 at (h=0, w=lane)
    assert phys_stream[0][0] == 0
    assert phys_stream[0][1][0] == _signed_byte(dense[0])
    assert phys_stream[0][2] == 8
    #   the right-edge tile of a row has two real columns
    assert phys_stream[k_len][2] == 2
    assert phys_stream[k_len][1][2:] == [0] * 6

    print(f"CONV2_PHYS_CHECKSUM = 0x{stream_checksum(phys_stream):08X}")
    print(f"CONV2_DENSE_CHECKSUM = 0x{stream_checksum(dense_stream):08X}")
    print("PASS window_ref physical tile-major (K=150, no sentinel leak)")


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

    # An unpadded physical model must be the dense model, byte for byte --
    # this is the property that lets C_PHYS_STRIDE default to C_LOGICAL in the
    # RTL and leave conv1 untouched.
    phys = pack_physical_frame(frame, in_h, in_w, c_in, c_in)
    assert phys == frame
    assert physical_window_stream(phys, in_h, in_w, c_in, c_in, 2, 3, 1) == stream
    print("PASS window_ref")


if __name__ == "__main__":
    _self_check()
    _conv2_physical_check()
