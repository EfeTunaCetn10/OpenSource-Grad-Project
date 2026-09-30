"""Export/configuration proof; never substitutes for runtime wrap32 arithmetic."""
from integer_linear_ref import checked_int32, INT32_MAX


def accumulator_safety(bias_q, K):
    """Report abs(bias[c])+K*16384 bound and signed-positive headroom per channel."""
    if type(K) is not int or K <= 0:
        raise ValueError('K must be a positive built-in int')
    if type(bias_q) not in (list, tuple) or not bias_q:
        raise ValueError('bias_q must be a nonempty list/tuple')
    rows = []
    for c, bias in enumerate(bias_q):
        checked_int32(bias, name=f'bias_q[{c}]')
        bound = abs(bias) + K * 16384
        rows.append({'channel': c, 'bound': bound, 'margin': INT32_MAX - bound,
                     'safe': bound <= INT32_MAX})
    return {'K': K, 'channels': rows, 'safe': all(r['safe'] for r in rows),
            'min_margin': min(r['margin'] for r in rows)}


def require_accumulator_safety(bias_q, K, *, layer='layer'):
    """Reject unsafe configuration; raw numerical primitives still always wrap."""
    report = accumulator_safety(bias_q, K)
    if not report['safe']:
        bad = next(r for r in report['channels'] if not r['safe'])
        raise ValueError(f'{layer} channel {bad["channel"]}: structural INT32 safety '
                         f'bound failed (margin={bad["margin"]})')
    return report
