"""Isolated Conv3 RTL fixture: saved PTQ -> software Pool2 -> Conv3 oracle.

No calibration, PTQ parameter selection, training, or full-network inference.
"""
import argparse
from pathlib import Path

import torch

from calibration import json_bytes, sha256
from export_v3_conv1_poc import verified_inputs, packed_bytes
from experimental_v3_ptq import integer_mac, requant_tensor, wrap32_tensor
from integer_tensor_ops_ref import integer_maxpool2d_ref
from export_v3_conv2_poc import pool1_fixture, tile_major_words


def pool2_fixture(image, p1, w1, p2, w2):
    pool1 = pool1_fixture(image,p1,w1)
    y,_ = requant_tensor(integer_mac(pool1,w2),p2['bias_q'],p2['M0'],p2['n'],relu=True)
    return torch.tensor(integer_maxpool2d_ref(y[0].tolist()),dtype=torch.int8).unsqueeze(0)


def export(ptq, output):
    ptq,output = Path(ptq).resolve(),Path(output).resolve()
    if output.exists(): raise FileExistsError(f'Refusing to overwrite {output}')
    q,p1,w1,image,sample,identities = verified_inputs(ptq)
    p2 = q['layers'][1]
    if (p2['name']!='features.3' or p2['shape']!=[24,16,3,3] or p2['kind']!='conv'
            or p2['relu'] is not True or p2['input_key']!='features.1' or p2['output_key']!='features.4'
            or p2['s_x']!=p1['s_y'] or p2['s_y']!=q['activation_scales']['features.4']):
        raise ValueError('Conv2 preparation mismatch')
    all_weights = torch.load(ptq/'weights_int8.pt',map_location='cpu',weights_only=True)
    w2 = all_weights[p2['name']+'.weight']
    if w2.dtype!=torch.int8 or list(w2.shape)!=[24,16,3,3]:
        raise ValueError('Conv2 preparation weights mismatch')
    p = q['layers'][2]
    if (p['name']!='features.6' or p['shape']!=[32,24,3,3] or p['kind']!='conv'
            or p['relu'] is not True or p['input_key']!='features.4' or p['output_key']!='features.7'
            or p['s_x']!=p2['s_y'] or p['s_x']!=q['activation_scales']['features.4']
            or p['s_y']!=q['activation_scales']['features.7']):
        raise ValueError('Conv3 scale/topology mismatch')
    weights = torch.load(ptq/'weights_int8.pt',map_location='cpu',weights_only=True)[p['name']+'.weight']
    if weights.dtype!=torch.int8 or list(weights.shape)!=p['shape']:
        raise ValueError('Conv3 weights mismatch')
    for key in ('bias_q','M0','n','s_w'):
        if len(p[key])!=32: raise ValueError(f'Conv3 channel count: {key}')
    with torch.inference_mode():
        pool = pool2_fixture(image,p1,w1,p2,w2)
        if list(pool.shape)!=[1,24,8,8]: raise ValueError('Pool2 shape mismatch')
        mac = integer_mac(pool,weights)
        biased = wrap32_tensor(mac+torch.tensor(p['bias_q']).reshape(1,32,1,1))
        y,_ = requant_tensor(mac,p['bias_q'],p['M0'],p['n'],relu=True)
    output.mkdir(parents=True,exist_ok=False)
    def write(name,values,bits):
        (output/name).write_text(''.join(f'{int(v)&((1<<bits)-1):0{(bits+3)//4}X}\n' for v in values),encoding='ascii')
    write('frame.mem',tile_major_words(pool[0]),64)
    write('pool2_chw.mem',pool.flatten().tolist(),8)
    write('weights_oihw.mem',weights.flatten().tolist(),8)
    for lane in range(8):
        write(f'wbank{lane}.mem',torch.cat([weights[t*8+lane].flatten() for t in range(4)]).tolist(),8)
    for key,bits in [('bias_q',32),('M0',18),('n',6)]: write(f'{key}.mem',p[key],bits)
    for tile in range(4):
        for name,tensor in [('acc',mac),('biased',biased),('y',y)]:
            values = tensor[0,tile*8:(tile+1)*8].permute(1,2,0).flatten().tolist()
            write(f't{tile}_{name}.mem',packed_bytes(values) if name=='y' else values,64 if name=='y' else 32)
    source_names=['export_v3_conv3_poc.py','export_v3_conv2_poc.py','export_v3_conv1_poc.py','integer_tensor_ops_ref.py']
    payload={'role':'isolated candidate Conv3 RTL POC, no promotion','checkpoint':q['checkpoint'],
             'sample':sample,'source_identity_sha256':identities,
             'export_source_sha256':{n:sha256(Path(__file__).with_name(n)) for n in source_names},
             'layer':p,'pool2_source':'existing integer Conv1/Conv2 oracle plus integer_maxpool2d_ref; no RTL pooling',
             'input_shape':[24,8,8],'output_shape':[32,8,8],'K':216,'padding':1,'stride':1,
             'input_transport':'[c_tile][H][W][8]; byte=(((c//8)*8+h)*8+w)*8+c%8',
             'output_transport':'output tile then h then w then lane; lane0 low byte',
             'weight_transport':'bank=co%8; address=(co//8)*216+ci*9+kh*3+kw',
             'input_beats':192,'output_beats':256,'logical_outputs':2048,'output_channel_tiles':4,
             'arithmetic':q['arithmetic'],'files':{p.name:sha256(p) for p in output.iterdir()}}
    if any(sha256(Path(path))!=digest for path,digest in identities.items()):
        raise ValueError('Source changed during export')
    (output/'manifest.json').write_bytes(json_bytes(payload))
    print(f'Exported {output}: 2048 logical outputs / 256 beats; Pool2 192 tile-major input beats')
    return payload


if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--ptq-dir',type=Path,required=True)
    ap.add_argument('--output-dir',type=Path,required=True)
    args=ap.parse_args();torch.set_num_threads(2)
    export(args.ptq_dir,args.output_dir)
