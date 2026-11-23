"""Pure-Python integer primitives for the frozen v3 network golden model.

Independent of the RTL.  Reduction order of window_gen: k = ci*kh*kw + ky*kw + kx.
Activations are x[h][w][c]; accumulators wrap to signed INT32 like the engine.
"""

from __future__ import annotations

from requant_ref import requant_ref

ROWS = 8


def wrap32(v: int) -> int:
    v &= 0xFFFFFFFF
    return v - (1 << 32) if v & 0x80000000 else v


def conv(x, h, w, c_in, weights, kh=3, kw=3, pad=1):
    """x[h][w][c] -> acc[oh][ow][oc] with `weights[oc][k]`."""
    oh_n, ow_n = h + 2 * pad - kh + 1, w + 2 * pad - kw + 1
    out = []
    for oh in range(oh_n):
        row = []
        for ow in range(ow_n):
            taps = []
            for ky in range(kh):
                ih = oh - pad + ky
                if not 0 <= ih < h:
                    continue
                for kx in range(kw):
                    iw = ow - pad + kx
                    if 0 <= iw < w:
                        taps.append((ky * kw + kx, x[ih][iw]))
            accs = []
            for wo in weights:
                acc = 0
                for kk, px in taps:
                    for ci in range(c_in):
                        acc += px[ci] * wo[ci * kh * kw + kk]
                accs.append(wrap32(acc))
            row.append(accs)
        out.append(row)
    return out


def requant_layer(acc, bias, m0, shift, relu):
    return [[[requant_ref(wrap32(a + bias[c]), m0[c], shift[c], bool(relu[c]))
              for c, a in enumerate(px)] for px in row] for row in acc]


def pool2x2(x):
    h, w, ch = len(x), len(x[0]), len(x[0][0])
    return [[[max(x[2 * r + dr][2 * c + dc][k] for dr in range(2) for dc in range(2))
              for k in range(ch)] for c in range(w // 2)] for r in range(h // 2)]


def pack_word(vals):
    """Up to 8 INT8 lane values -> 64-bit word, lane r in bits 8r+7:8r."""
    return sum((v & 0xFF) << (8 * i) for i, v in enumerate(vals))


def tile_major_words(y, c_out):
    """act_buffer image: tile t, raster pixel -> word of channels 8t..8t+7 (zeros past c_out)."""
    tiles = (c_out + ROWS - 1) // ROWS
    return [pack_word(px[ROWS * t:ROWS * t + ROWS]) for t in range(tiles) for row in y for px in row]


def flatten_hwc(y):
    """FC input: k = (h*W + w)*C + c."""
    return [v for row in y for px in row for v in px]


def argmax_first(v):
    return max(range(len(v)), key=lambda i: (v[i], -i))
