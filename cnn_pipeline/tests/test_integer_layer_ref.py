from copy import deepcopy

import pytest

import integer_layer_ref as layers
from integer_linear_ref import integer_linear_ref, checked_int32
from integer_conv2d_ref import integer_conv2d_ref
from requant_ref import requant_ref


def test_linear_manual_and_primitives():
    x, w = [2, -3, 4], [[5, 6, -2], [-1, 0, 3], [1, 0, 0]]
    b, m, n = [1, -7, -6], [65536, 98304, 65536], [17, 17, 18]
    # MAC [-16,10,2], +bias [-15,3,-4], scaled [-7.5,2.25,-1].
    before = deepcopy((x, w, b, m, n))
    result = layers.integer_linear_layer_ref(x, w, b, m, n, relu=False)
    assert result == [-7, 2, -1] and all(type(v) is int for v in result)
    assert result == [requant_ref(checked_int32(v+b[c]), m[c], n[c])
                      for c, v in enumerate(integer_linear_ref(x, w))]
    assert layers.integer_linear_layer_ref(x, w, b, m, n, relu=True) == [0, 2, 0]
    assert (x, w, b, m, n) == before


def test_conv_manual_channels_positions():
    x = [[[1, 2], [-1, -2]], [[3, -3], [4, -4]]]
    w = [[[[1]], [[1]]], [[[2]], [[-1]]]]
    b, m, n = [-1, 1], [65536, 98304], [17, 18]
    # MAC planes [[4,-1],[3,-6]] and [[-1,7],[-6,0]].
    # Biased [[3,-2],[2,-7]] and [[0,8],[-5,1]]; scales .5, .375.
    before = deepcopy((x, w, b, m, n))
    out = layers.integer_conv2d_layer_ref(x, w, b, m, n, relu=False)
    assert out == [[[2, -1], [1, -3]], [[0, 3], [-2, 0]]]
    mac = integer_conv2d_ref(x, w)
    assert out == [[[requant_ref(checked_int32(v+b[c]), m[c], n[c]) for v in row]
                    for row in plane] for c, plane in enumerate(mac)]
    assert all(type(v) is int for plane in out for row in plane for v in row)
    assert (x, w, b, m, n) == before


@pytest.mark.parametrize('conv', [False, True])
@pytest.mark.parametrize('bias,expected', [(5, 3), (-5, -2), (1000, 127), (-1000, -128)])
def test_ties_and_saturation(conv, bias, expected):
    if conv:
        assert layers.integer_conv2d_layer_ref([[[0]]], [[[[1]]]], [bias], [65536], [17], relu=False) == [[[expected]]]
    else:
        assert layers.integer_linear_layer_ref([0], [[1]], [bias], [65536], [17], relu=False) == [expected]


@pytest.mark.parametrize('conv', [False, True])
@pytest.mark.parametrize('x,bias', [(1, 2**31-1), (-1, -2**31)])
def test_mac_plus_bias_overflow(conv, x, bias):
    if conv:
        with pytest.raises(OverflowError, match=r'custom channel 0 position \(0,0\) MAC\+bias'):
            layers.integer_conv2d_layer_ref([[[x]]], [[[[1]]]], [bias], [65536], [17], relu=False, layer='custom')
    else:
        with pytest.raises(OverflowError, match=r'linear channel 0.*MAC\+bias'):
            layers.integer_linear_layer_ref([x], [[1]], [bias], [65536], [17], relu=False)


def test_mac_overflow_propagates():
    with pytest.raises(OverflowError, match='exact sum=2147483648'):
        layers.integer_linear_layer_ref([-128]*131072, [[-128]*131072], [0], [65536], [17], relu=False)


@pytest.mark.parametrize('field,bad,exception', [
    ('M0', [65535], ValueError), ('M0', [131072], ValueError),
    ('n', [0], ValueError), *[('n', [v], OverflowError) for v in range(50,64)],
    ('n', [-1], ValueError), ('n', [64], ValueError),
    ('bias_q', [2**31], OverflowError), ('bias_q', [-2**31-1], OverflowError),
    ('bias_q', [True], TypeError), ('M0', [1.0], TypeError), ('n', [False], TypeError),
    ('bias_q', [], ValueError), ('M0', [65536,65536], ValueError),
    ('n', 17, TypeError), ('relu', 1, TypeError)])
@pytest.mark.parametrize('conv', [False, True])
def test_parameter_rejection_before_mac(monkeypatch, field, bad, exception, conv):
    def forbidden(*a, **kw):
        pytest.fail('MAC must not start for invalid parameters')
    name = 'integer_conv2d_ref' if conv else 'integer_linear_ref'
    monkeypatch.setattr(layers, name, forbidden)
    args = dict(bias_q=[0], M0=[65536], n=[17], relu=False)
    args[field] = bad
    fn = layers.integer_conv2d_layer_ref if conv else layers.integer_linear_layer_ref
    with pytest.raises(exception):
        fn([1], [[1]], **args)


@pytest.mark.parametrize('x,w', [([], [[1]]), ([1,2], [[1]]), ([True], [[1]]), ([128], [[1]])])
def test_linear_shape_type(x,w):
    with pytest.raises((TypeError,ValueError)):
        layers.integer_linear_layer_ref(x,w,[0],[65536],[17],relu=False)


@pytest.mark.parametrize('x,w', [([1], [[[[1]]]]), ([[[1],[]]], [[[[1]]]]),
                                  ([[[1]]], [[[[1]],[[1]]]]), ([[[1.]]], [[[[1]]]])])
def test_conv_shape_type(x,w):
    with pytest.raises((TypeError,ValueError)):
        layers.integer_conv2d_layer_ref(x,w,[0],[65536],[17],relu=False)
