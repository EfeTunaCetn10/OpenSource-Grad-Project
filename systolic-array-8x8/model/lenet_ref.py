"""Deterministic INT8 LeNet fixture and layer-boundary golden values.

The temporary pool/FC implementations below are integration stand-ins.  The
public imports and call signatures are the frozen seam contract.
"""
from __future__ import annotations

import random

from conv1_ref import Conv1Fixture
from engine_ref import wrap32
from requant_ref import requant_ref

try:
    from pool_ref import pool2x2
    from fc_ref import fc_layer
    HAVE_DEPS = True
except ImportError:
    HAVE_DEPS = False

    # STAND-IN, replaced at integration
    def pool2x2(x: list[int], h: int, w: int, c: int) -> list[int]:
        cp = ((c + 7) // 8) * 8
        y = [0] * ((h // 2) * (w // 2) * cp)
        for tile in range(cp // 8):
            for oh in range(h // 2):
                for ow in range(w // 2):
                    for lane in range(8):
                        src = lambda ih, iw: (((tile * h + ih) * w + iw) * 8 + lane)
                        dst = (((tile * (h // 2) + oh) * (w // 2) + ow) * 8 + lane)
                        y[dst] = max(x[src(2*oh+dh, 2*ow+dw)]
                                     for dh in range(2) for dw in range(2))
        return y

    # STAND-IN, replaced at integration
    def fc_layer(x: list[int], w: list[int], bias_q: list[int],
                 m0: list[int], shift_n: list[int], relu: list[bool],
                 n_in: int, n_out: int) -> list[int]:
        if len(x) != n_in or len(w) != n_in*n_out:
            raise ValueError("FC shape mismatch")
        out = []
        for o in range(n_out):
            acc = 0
            for k in range(n_in):
                acc = wrap32(acc + x[k] * w[o*n_in+k])
            lane = o % 8
            out.append(requant_ref(wrap32(acc + bias_q[lane]),
                                   m0[lane], shift_n[lane], relu[lane]))
        return out


def _config(rng: random.Random, spread: int, relu: bool) -> dict:
    # Scale from this fixture's measured pre-requant accumulator peak.
    # The normalized multiplier is odd to exercise rounding.
    m0 = [rng.randrange((1 << 16) + 1, (1 << 17) - 1, 2) for _ in range(8)]
    target = 95
    shift = [max(0, min(63, (max(1, spread) * m // target).bit_length() - 1))
             for m in m0]
    return dict(bias_q=[rng.randint(-1000, 1000) for _ in range(8)],
                m0=m0, shift_n=shift, relu=[relu] * 8,
                measured_peak=spread)


def _conv_acc(x: list[int], h: int, w: int, ci: int,
              weights: list[list[int]], co: int, physical: bool) -> list[int]:
    oh, ow = h-4, w-4
    out = [0] * (oh*ow*co)
    for y in range(oh):
        for xx in range(ow):
            for o in range(co):
                acc = 0
                for ch in range(ci):
                    for kh in range(5):
                        for kw in range(5):
                            k = ch*25 + kh*5 + kw
                            if physical:
                                ix = ((((ch//8)*h + y+kh)*w + xx+kw)*8 + ch%8)
                            else:
                                ix = (((y+kh)*w + xx+kw)*ci + ch)
                            acc = wrap32(acc + x[ix]*weights[o][k])
                out[(y*ow+xx)*co+o] = acc
    return out


def _fc_acc(x: list[int], w: list[int], n_out: int) -> list[int]:
    ni = len(x)
    return [sum(x[k]*w[o*ni+k] for k in range(ni)) for o in range(n_out)]


def _fc1_physical_weights(dense: list[int]) -> list[int]:
    """ADR-018: (out, channel, h, w) -> (out, tile, h, w, lane)."""
    if len(dense) != 120*400:
        raise ValueError('FC1 dense weights must be 120 x 400')
    physical = [0]*len(dense)
    for o in range(120):
        for c in range(16):
            for h in range(5):
                for w in range(5):
                    src = o*400+c*25+h*5+w
                    dst = o*400+((((c//8)*5+h)*5+w)*8+c%8)
                    physical[dst] = dense[src]
    assert ((((8//8)*5+1)*5+0)*8+8%8) == 240
    assert physical[240] == dense[8*25+1*5]
    return physical


def _padded(x: list[int], h: int, w: int, c: int) -> list[int]:
    out = [0] * (h*w*((c+7)//8)*8)
    for y in range(h):
        for xx in range(w):
            for ch in range(c):
                out[((((ch//8)*h+y)*w+xx)*8+ch%8)] = x[(y*w+xx)*c+ch]
    return out


def _requant_map(acc: list[int], cfg: dict, h: int, w: int, c: int) -> list[int]:
    dense = [requant_ref(wrap32(v + cfg['bias_q'][i%c%8]),
                           cfg['m0'][i%c%8], cfg['shift_n'][i%c%8],
                           cfg['relu'][i%c%8]) for i, v in enumerate(acc)]
    return _padded(dense, h, w, c)


def lenet_fixture(seed: int = 20261009) -> dict:
    rng = random.Random(seed)
    image = [rng.randint(-128,127) for _ in range(32*32*3)]
    w1 = [[rng.randint(-128,127) for _ in range(75)] for _ in range(6)]
    # Conv1 uses the pre-existing verified composition and its measured scale.
    c1 = Conv1Fixture(image, w1, [0]*8, [65537]*8, [27]*8, [False]*8)
    a1 = _conv_acc(image,32,32,3,w1,6,False)
    cfg1 = _config(rng,max(abs(v) for v in a1),True)
    c1.bias_q,c1.m0,c1.shift_n,c1.relu = (cfg1[k] for k in ('bias_q','m0','shift_n','relu'))
    p1 = pool2x2(_padded(c1.output_tensor(),28,28,6),28,28,6)
    w2 = [[rng.randint(-128,127) for _ in range(150)] for _ in range(16)]
    a2 = _conv_acc(p1,14,14,6,w2,16,True)
    cfg2 = _config(rng,max(abs(v) for v in a2),True)
    p2 = pool2x2(_requant_map(a2,cfg2,10,10,16),10,10,16)
    # Transform dense training order into the physical stream K order.
    wf1 = _fc1_physical_weights([rng.randint(-128,127) for _ in range(120*400)])
    af1 = _fc_acc(p2,wf1,120)
    cfgf1 = _config(rng,max(abs(v) for v in af1),True)
    f1 = fc_layer(p2,wf1,**{k:cfgf1[k] for k in ('bias_q','m0','shift_n','relu')},n_in=400,n_out=120)
    wf2 = [rng.randint(-128,127) for _ in range(84*120)]
    cfgf2 = _config(rng,max(abs(v) for v in _fc_acc(f1,wf2,84)),True)
    f2 = fc_layer(f1,wf2,**{k:cfgf2[k] for k in ('bias_q','m0','shift_n','relu')},n_in=120,n_out=84)
    wf3 = [rng.randint(-128,127) for _ in range(10*84)]
    cfgf3 = _config(rng,max(abs(v) for v in _fc_acc(f2,wf3,10)),False)
    return dict(image=image,w_conv1=w1,w_conv2=w2,w_fc1=wf1,w_fc2=wf2,w_fc3=wf3,
                cfg_conv1=cfg1,cfg_conv2=cfg2,cfg_fc1=cfgf1,cfg_fc2=cfgf2,cfg_fc3=cfgf3,
                seed=seed)


def lenet_forward(fx: dict) -> dict:
    c = fx['cfg_conv1']
    c1 = Conv1Fixture(fx['image'],fx['w_conv1'],
                      c['bias_q'],c['m0'],c['shift_n'],c['relu'])
    conv1 = _padded(c1.output_tensor(),28,28,6)
    pool1 = pool2x2(conv1,28,28,6)
    a2 = _conv_acc(pool1,14,14,6,fx['w_conv2'],16,True)
    conv2 = _requant_map(a2,fx['cfg_conv2'],10,10,16)
    pool2 = pool2x2(conv2,10,10,16)
    def fc(x: list[int], key: str, ni: int, no: int) -> list[int]:
        cfg = fx['cfg_'+key]
        return fc_layer(x,fx['w_'+key],cfg['bias_q'],cfg['m0'],
                        cfg['shift_n'],cfg['relu'],ni,no)
    fc1 = fc(pool2,'fc1',400,120)
    fc2 = fc(fc1,'fc2',120,84)
    fc3 = fc(fc2,'fc3',84,10)
    predicted = max(range(10),key=lambda i:fc3[i])
    return dict(conv1=conv1,pool1=pool1,conv2=conv2,pool2=pool2,
                fc1=fc1,fc2=fc2,fc3=fc3,logits=fc3,predicted=predicted)


if __name__ == '__main__':
    fx = lenet_fixture()
    y = lenet_forward(fx)
    assert [len(y[k]) for k in ('conv1','pool1','conv2','pool2','fc1','fc2','fc3')] == [6272,1568,1600,400,120,84,10]
    print('PASS lenet_ref', 'deps=real' if HAVE_DEPS else 'deps=stand-in',
          'predicted=',y['predicted'])
