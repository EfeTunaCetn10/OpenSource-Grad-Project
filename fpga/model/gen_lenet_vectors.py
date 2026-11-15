#!/usr/bin/env python3
"""Serialize every LeNet layer boundary for tb_lenet_e2e.

Invoke explicitly until sim/run_tests.py gains this generator in its fixed
VECTOR_GENERATORS list.  All files are deterministic and gitignored.
"""
from __future__ import annotations

from pathlib import Path
from lenet_ref import HAVE_DEPS, lenet_fixture, lenet_forward

VECTORS = Path(__file__).resolve().parent.parent / 'sim' / 'vectors'


def words(name: str, values: list[int], bits: int) -> None:
    VECTORS.mkdir(parents=True, exist_ok=True)
    mask = (1 << bits) - 1
    (VECTORS / f'lenet_{name}.mem').write_text(
        ''.join(f'{v & mask:0{bits//4}X}\n' for v in values), encoding='ascii')


def packed(x: list[int]) -> list[int]:
    return [sum((v & 255) << (8*j) for j,v in enumerate(x[i:i+8]))
            for i in range(0,len(x),8)]


def main() -> None:
    fx = lenet_fixture()
    y = lenet_forward(fx)
    words('image_frame',packed(fx['image']),64)
    for layer in ('conv1','pool1','conv2','pool2','fc1','fc2','fc3'):
        words(layer+'_y',y[layer],8)
    words('pred', [y['predicted']],8)
    for layer, ni, no in [('conv1',75,6),('conv2',150,16),
                          ('fc1',400,120),('fc2',120,84),('fc3',84,10)]:
        w = fx['w_'+layer]
        for row in range(8):
            vals = []
            for tile in range((no+7)//8):
                o = tile*8+row
                vals.extend((w[o] if layer.startswith('conv') else w[o*ni:(o+1)*ni])
                            if o < no else [0]*ni)
            words(layer+f'_wbank{row}',vals,8)
        c = fx['cfg_'+layer]
        for key,bits in [('bias_q',32),('m0',18),('shift_n',6),('relu',1)]:
            words(layer+'_'+key,[int(v) for v in c[key]],max(8,bits) if bits<8 else ((bits+3)//4)*4)
    print('PASS gen_lenet_vectors', 'real refs' if HAVE_DEPS else 'stand-ins',
          'predicted',y['predicted'])


if __name__ == '__main__':
    main()
