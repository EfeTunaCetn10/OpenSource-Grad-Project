"""Single-layer candidate software composition; no final RTL overflow policy."""
from integer_linear_ref import integer_linear_ref, checked_int32
from integer_conv2d_ref import integer_conv2d_ref
from requant_ref import requant_raw, requant_ref


def _parameters(weights, bias_q, M0, n, relu, layer):
    if type(layer) is not str or not layer:
        raise TypeError('layer must be a nonempty string')
    if type(relu) is not bool:
        raise TypeError(f'{layer}: relu must be built-in bool')
    if type(weights) not in (list, tuple):
        raise TypeError(f'{layer}: weights must be list/tuple')
    if not weights:
        raise ValueError(f'{layer}: weights must not be empty')
    for name, values in (('bias_q', bias_q), ('M0', M0), ('n', n)):
        if type(values) not in (list, tuple):
            raise TypeError(f'{layer}: {name} must be list/tuple')
        if len(values) != len(weights):
            raise ValueError(f'{layer}: {name} needs {len(weights)} output channels')
        for c, value in enumerate(values):
            if type(value) is not int:
                raise TypeError(f'{layer} channel {c}: {name} must be built-in int')
    for c in range(len(weights)):
        checked_int32(bias_q[c], name=f'{layer} channel {c} bias_q')
        try:
            requant_raw(0, M0[c], n[c])
        except (ValueError, OverflowError) as exc:
            raise type(exc)(f'{layer} channel {c}: {exc}') from exc


def _output(mac, bias, multiplier, shift, relu, location):
    acc = checked_int32(mac + bias, name=f'{location} MAC+bias')
    return requant_ref(acc, multiplier, shift, relu=relu)


def integer_linear_layer_ref(x, weights, bias_q, M0, n, *, relu):
    """Candidate software composition: Linear MAC + INT32 bias + requant.

    Parameters are ready channel-ordered Python integer lists/tuples. Invalid
    parameters are rejected before MAC. No scale selection or input mutation.
    Return [C_out] Python ints; any overflow rejects the entire call.
    """
    _parameters(weights, bias_q, M0, n, relu, 'linear')
    mac = integer_linear_ref(x, weights)
    return [_output(value, bias_q[c], M0[c], n[c], relu,
                    f'linear channel {c} position scalar') for c, value in enumerate(mac)]


def integer_conv2d_layer_ref(x, weights, bias_q, M0, n, *, relu, layer='conv2d'):
    """Candidate software composition returning CHW Python ints.

    Reuses valid stride=1/padding=0/dilation=1 cross-correlation. No bias/scale
    generation. INT32 overflow rejection is diagnostic, not final RTL policy.
    """
    _parameters(weights, bias_q, M0, n, relu, layer)
    mac = integer_conv2d_ref(x, weights, layer=layer)
    return [[[_output(value, bias_q[c], M0[c], n[c], relu,
                      f'{layer} channel {c} position ({h},{w})')
              for w, value in enumerate(row)] for h, row in enumerate(plane)]
            for c, plane in enumerate(mac)]
