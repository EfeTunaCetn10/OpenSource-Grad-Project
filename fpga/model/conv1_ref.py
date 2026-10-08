"""Stdlib-only golden model for one end-to-end conv1 layer.

This composes the three already bit-exact models instead of re-deriving any
arithmetic:

    window_ref.window_stream   -> the activation beat order (ADR-016 HWC,
                                  channel-major k, partial right-edge tiles)
    engine_ref.engine_ref      -> the INT32 accumulator per (output channel,
                                  output position) and the column drain order
    requant_ref.requant_ref    -> the ADR-003 INT32 -> INT8 requantization

Nothing here models a trained network.  Stage 1 proves the datapath is
bit-exact, so random INT8 weights are sufficient and deliberately chosen: a
trained checkpoint would couple this verification to the model side, which is
not what is being tested.

Geometry is the LeNet-5 conv1 of ADR-002: 32x32x3 input, 5x5 kernel, stride 1,
pad 0, 6 output channels -> K = 3*5*5 = 75, output 28x28x6.  Because 6 <= ROWS
there is exactly one output-channel tile, so the conv2 activation-replay
problem (ADR-018 addendum) does not appear here.

The weight address contract is ADR-011: bank r holds output channel
`tile_idx*ROWS + r`, bank-local address `tile_idx*K + k`, with
`k = ci*(kH*kW) + kh*kW + kw`.  `weight_banks()` returns exactly that memory
image, so a mismatch between this model and the RTL is an addressing bug and
not a difference of convention.
"""

from __future__ import annotations

import random

from engine_ref import engine_ref, wrap32
from requant_ref import requant_ref, requant_raw_ref
from window_ref import window_stream

ROWS = 8
COLS = 8

# LeNet-5 conv1 (ADR-002).
IN_H = 32
IN_W = 32
C_IN = 3
K_H = 5
K_W = 5
STRIDE = 1
PAD = 0
C_OUT = 6

K_LEN = C_IN * K_H * K_W          # 75
OUT_H = (IN_H + 2 * PAD - K_H) // STRIDE + 1   # 28
OUT_W = (IN_W + 2 * PAD - K_W) // STRIDE + 1   # 28
TILES_PER_ROW = (OUT_W + COLS - 1) // COLS     # 4 -> active_cols 8/8/8/4
TILES = OUT_H * TILES_PER_ROW                  # 112 engine invocations


class Conv1Fixture:
    """The full stimulus for one conv1 frame plus its expected results."""

    def __init__(
        self,
        frame: list[int],
        weights: list[list[int]],
        bias_q: list[int],
        m0: list[int],
        shift_n: list[int],
        relu: list[bool],
        bypass: bool = False,
    ) -> None:
        if len(frame) != IN_H * IN_W * C_IN:
            raise ValueError("frame must be dense HWC 32*32*3")
        if len(weights) != C_OUT or any(len(w) != K_LEN for w in weights):
            raise ValueError("weights must be C_OUT x K_LEN")
        for name, cfg in (("bias_q", bias_q), ("m0", m0),
                          ("shift_n", shift_n), ("relu", relu)):
            if len(cfg) != ROWS:
                raise ValueError(f"{name} must carry one entry per lane (ROWS)")
        self.frame = frame
        self.weights = weights
        self.bias_q = bias_q
        self.m0 = m0
        self.shift_n = shift_n
        self.relu = relu
        self.bypass = bypass

    # -- stimulus ---------------------------------------------------------

    def activation_beats(self) -> list[tuple[int, list[int], int]]:
        """`(k, eight INT8 lane values, active_cols)` in RTL beat order."""
        return window_stream(self.frame, IN_H, IN_W, C_IN,
                             K_H, K_W, STRIDE, PAD)

    def weight_banks(self) -> list[list[int]]:
        """`banks[r][addr]` per ADR-011; unused lanes 6,7 are zero."""
        banks = [[0] * (1 * K_LEN) for _ in range(ROWS)]
        for r in range(C_OUT):
            for k in range(K_LEN):
                banks[r][0 * K_LEN + k] = self.weights[r][k]
        return banks

    # -- expected results -------------------------------------------------

    def tiles(self) -> list[dict]:
        """One entry per engine invocation, in issue order.

        Each entry carries the geometry the layer sequencer must drive and the
        expected INT32 drain plus INT8 requant result, so a testbench can check
        the engine edge and the requant edge independently.
        """
        beats = self.activation_beats()
        if len(beats) != TILES * K_LEN:
            raise AssertionError(
                f"window stream is {len(beats)} beats, expected {TILES * K_LEN}")

        a_matrix = [[self.weights[r][k] if r < C_OUT else 0
                     for k in range(K_LEN)] for r in range(ROWS)]

        out = []
        for t in range(TILES):
            chunk = beats[t * K_LEN:(t + 1) * K_LEN]
            active_cols = chunk[0][2]
            if any(b[2] != active_cols for b in chunk):
                raise AssertionError("active_cols changed inside a tile")
            if [b[0] for b in chunk] != list(range(K_LEN)):
                raise AssertionError("k order inside a tile is not 0..K-1")

            b_matrix = [list(b[1]) for b in chunk]
            _, drain = engine_ref(a_matrix, b_matrix, C_OUT, active_cols, K_LEN)

            oh = t // TILES_PER_ROW
            tile_x = (t % TILES_PER_ROW) * COLS

            # The engine drains column-major: all active rows of column 0, then
            # column 1.  requant_array consumes one column beat at a time with
            # one lane per output channel, which is why the expected INT8 data
            # is grouped the same way.
            acc_by_col = [[0] * ROWS for _ in range(active_cols)]
            for lane, col, value in drain:
                acc_by_col[col][lane] = value

            y_by_col = []
            for col in range(active_cols):
                y_lane = []
                for lane in range(ROWS):
                    if lane >= C_OUT:
                        y_lane.append(0)
                        continue
                    y_lane.append(self._requant(acc_by_col[col][lane], lane))
                y_by_col.append(y_lane)

            out.append({
                "tile": t,
                "oh": oh,
                "tile_x": tile_x,
                "active_cols": active_cols,
                "active_rows": C_OUT,
                "k_len": K_LEN,
                "acc_by_col": acc_by_col,
                "y_by_col": y_by_col,
            })
        return out

    def _requant(self, acc: int, lane: int) -> int:
        """ADR-014 wrapper semantics: bias add, then ADR-003 requantization."""
        biased = wrap32(acc + self.bias_q[lane])
        if self.bypass:
            # Bypass exports the low byte of the biased accumulator unchanged.
            low = biased & 0xFF
            return low - 256 if low >= 128 else low
        return requant_ref(biased, self.m0[lane], self.shift_n[lane],
                           self.relu[lane])

    def output_tensor(self) -> list[int]:
        """Dense HWC INT8 conv1 output, `out[(oh*OUT_W + ow)*C_OUT + ch]`.

        Dense HWC is the model-side layout of ADR-016; whether the on-chip
        buffer stores it dense or padded tile-major is the open ADR-018
        question and does not change these values, only their addresses.
        """
        tensor = [0] * (OUT_H * OUT_W * C_OUT)
        for entry in self.tiles():
            for col in range(entry["active_cols"]):
                ow = entry["tile_x"] + col
                for ch in range(C_OUT):
                    tensor[(entry["oh"] * OUT_W + ow) * C_OUT + ch] = \
                        entry["y_by_col"][col][ch]
        return tensor


def random_fixture(seed: int = 20261007) -> Conv1Fixture:
    """A deterministic fixture whose requant output spans the INT8 range.

    `m0`/`shift_n` are picked from the MEASURED accumulator spread of this
    fixture, not from the theoretical worst case: with random INT8 operands the
    reduction is a random walk, so |acc| has an RMS near 50,000 and a measured
    peak near 143,000 -- far below the K*16384 = 1,228,800 bound.  Scaling for
    the bound would compress every output into a handful of codes around zero
    and a broken clamp would still pass.  `shift_n` alternates 26/27 per lane so
    some lanes saturate and some do not, and four of six lanes keep ReLU off so
    the -128 clamp is exercised too.
    """
    rng = random.Random(seed)
    frame = [rng.randint(-128, 127) for _ in range(IN_H * IN_W * C_IN)]
    weights = [[rng.randint(-128, 127) for _ in range(K_LEN)]
               for _ in range(C_OUT)]

    bias_q = [0] * ROWS
    m0 = [1 << 16] * ROWS
    shift_n = [0] * ROWS
    relu = [False] * ROWS
    for lane in range(C_OUT):
        bias_q[lane] = rng.randint(-5000, 5000)
        m0[lane] = rng.randrange((1 << 16) + 1, (1 << 17) - 1, 2)  # odd
        shift_n[lane] = 26 + (lane % 2)
        relu[lane] = lane >= 4
    return Conv1Fixture(frame, weights, bias_q, m0, shift_n, relu)


def _self_check() -> None:
    fx = random_fixture()

    beats = fx.activation_beats()
    assert len(beats) == TILES * K_LEN == 112 * 75 == 8400, len(beats)
    assert [b[2] for b in beats[:K_LEN]] == [8] * K_LEN
    # The fourth tile of every output row is the partial right edge.
    assert beats[3 * K_LEN][2] == 4
    assert all(v == 0 for v in beats[3 * K_LEN][1][4:])

    banks = fx.weight_banks()
    assert len(banks) == ROWS and all(len(b) == K_LEN for b in banks)
    assert banks[0][0] == fx.weights[0][0]
    assert banks[5][74] == fx.weights[5][74]
    assert banks[6] == [0] * K_LEN and banks[7] == [0] * K_LEN

    tiles = fx.tiles()
    assert len(tiles) == TILES
    assert [t["active_cols"] for t in tiles[:4]] == [8, 8, 8, 4]
    assert tiles[-1]["active_cols"] == 4

    # One output recomputed straight from the frame, bypassing the window and
    # engine models entirely -- if the composition above mis-indexes anything,
    # these two numbers disagree.
    oh, ow, ch = 1, 3, 2
    acc = 0
    for ci in range(C_IN):
        for kh in range(K_H):
            for kw in range(K_W):
                k = ci * (K_H * K_W) + kh * K_W + kw
                px = fx.frame[((oh + kh) * IN_W + (ow + kw)) * C_IN + ci]
                acc = wrap32(acc + px * fx.weights[ch][k])
    entry = tiles[oh * TILES_PER_ROW + ow // COLS]
    assert entry["acc_by_col"][ow % COLS][ch] == acc, "engine composition"
    biased = wrap32(acc + fx.bias_q[ch])
    expect_y = requant_ref(biased, fx.m0[ch], fx.shift_n[ch], fx.relu[ch])
    assert entry["y_by_col"][ow % COLS][ch] == expect_y, "requant composition"
    assert abs(requant_raw_ref(biased, fx.m0[ch], fx.shift_n[ch])) < (1 << 31)

    tensor = fx.output_tensor()
    assert len(tensor) == OUT_H * OUT_W * C_OUT == 4704
    assert tensor[(oh * OUT_W + ow) * C_OUT + ch] == expect_y
    assert all(-128 <= v <= 127 for v in tensor)

    # The scaling must actually exercise the INT8 range; a fixture whose
    # outputs all sit near zero would pass a broken clamp.
    assert max(tensor) >= 100 and min(tensor) <= -100, (min(tensor), max(tensor))
    relu_vals = [tensor[i * C_OUT + ch] for ch in range(C_OUT) if fx.relu[ch]
                 for i in range(OUT_H * OUT_W)]
    assert all(v >= 0 for v in relu_vals), "relu lanes must never go negative"

    print("PASS conv1_ref")


if __name__ == "__main__":
    _self_check()
