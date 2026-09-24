"""Candidate software parameters only; not an RTL production/export contract."""
import math
import sys

import multiplier_analysis
from requant_ref import M0_MIN, M0_MAX, requant_raw


def _scale(value, name):
    if type(value) not in (int, float):
        raise TypeError(f'{name}: expected built-in int/float scalar, not bool or tensor')
    try:
        value = float(value)
    except OverflowError as exc:
        raise ValueError(f'{name}: not representable in float64') from exc
    if not math.isfinite(value) or value <= 0:
        raise ValueError(f'{name}: scale must be finite and positive')
    return value


def _intermediate(value, name):
    # Conservatively reject subnormal intermediates too, not only rounded zero.
    if not math.isfinite(value) or value < sys.float_info.min:
        raise ValueError(f'{name}: float64 underflow/subnormal or overflow; no fallback')
    return value


def candidate_requant_params(s_x, s_y, s_w):
    """Return candidate software parameters for ordered output-channel scales.

    Scalars are built-in int/float (bool excluded); s_w is a nonempty flat
    list/tuple. Arithmetic is binary64, not exact real arithmetic. Selection
    delegates exclusively to multiplier_analysis.analyze_multiplier. Any bad
    channel rejects the whole call. No files, tensors or inputs are modified.
    Returns role, ordered M0/n lists and per-channel M/error/status/anomalies.
    """
    sx, sy = _scale(s_x, 's_x'), _scale(s_y, 's_y')
    if type(s_w) not in (list, tuple):
        raise TypeError('s_w: expected flat list/tuple of channel scales')
    if not s_w:
        raise ValueError('s_w: empty channel sequence')
    channels = []
    for channel, weight_scale in enumerate(s_w):
        sw = _scale(weight_scale, f'channel {channel} s_w')
        product = _intermediate(sx * sw, f'channel {channel} s_x*s_w')
        M = _intermediate(product / sy, f'channel {channel} M')
        analysis = multiplier_analysis.analyze_multiplier(M)
        pair = analysis['selected_candidate']
        if pair is None:
            raise ValueError(f'channel {channel}: M={M} has no selectable candidate; '
                             'entire call rejected, no partial parameters')
        M0, n = pair['M0'], pair['n']
        if (type(M0) is not int or type(n) is not int or
                not M0_MIN <= M0 <= M0_MAX or not 1 <= n <= 49):
            raise ValueError(f'channel {channel}: candidate violates requant contract')
        requant_raw(0, M0, n)  # Exercise the existing signed-width guards too.
        channels.append({'channel': channel, 'M': M, **pair,
                         'status': analysis['status'], 'anomalies': list(analysis['anomalies'])})
    return {'role': 'candidate software parameters; not hardware export',
            'M0': [p['M0'] for p in channels], 'n': [p['n'] for p in channels],
            'channels': channels}
