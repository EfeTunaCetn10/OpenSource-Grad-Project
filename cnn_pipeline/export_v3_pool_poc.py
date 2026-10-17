"""Real pooling and optional FC fixtures from saved parameters; no PTQ or promotion."""
import argparse
from pathlib import Path
import torch
from calibration import json_bytes, sha256
from export_v3_conv1_poc import verified_inputs
from export_v3_conv2_poc import tile_major_words
from experimental_v3_ptq import integer_mac, requant_tensor
from integer_tensor_ops_ref import integer_maxpool2d_ref
from quantization import quantize_int8


def pool_chw(x):
    if x.dtype!=torch.int8 or x.device.type!='cpu' or x.ndim!=3:
        raise ValueError('Expected CPU INT8 CHW')
    return torch.tensor(integer_maxpool2d_ref(x.tolist()),dtype=torch.int8)


def export(ptq,output):
    ptq,output=Path(ptq).resolve(),Path(output).resolve()
    if output.exists(): raise FileExistsError(f'Refusing to overwrite {output}')
    q,_,_,image,sample,identities=verified_inputs(ptq)
    weights=torch.load(ptq/'weights_int8.pt',map_location='cpu',weights_only=True)
    expected=[('features.0',[16,3,3,3],'input','features.1'),
              ('features.3',[24,16,3,3],'features.1','features.4'),
              ('features.6',[32,24,3,3],'features.4','features.7')]
    fixtures=[]
    with torch.inference_mode():
        x=quantize_int8(image.unsqueeze(0),q['activation_scales']['input'])
        for i,(name,shape,ik,ok) in enumerate(expected):
            p=q['layers'][i];w=weights[name+'.weight']
            if (p['name']!=name or p['shape']!=shape or p['input_key']!=ik or p['output_key']!=ok
                    or p['kind']!='conv' or p['relu'] is not True or list(w.shape)!=shape or w.dtype!=torch.int8
                    or p['s_x']!=q['activation_scales'][ik] or p['s_y']!=q['activation_scales'][ok]):
                raise ValueError(f'Conv{i+1} topology/scale mismatch')
            conv,_=requant_tensor(integer_mac(x,w),p['bias_q'],p['M0'],p['n'],relu=True)
            conv=conv[0].to(torch.int8);pooled=pool_chw(conv)
            fixtures.append((conv,pooled,p['s_y']))
            x=pooled.unsqueeze(0)
    output.mkdir(parents=True,exist_ok=False)
    stages=[]
    for i,(conv,pooled,scale) in enumerate(fixtures,1):
        for suffix,tensor in [('input',conv),('expected',pooled)]:
            (output/f'pool{i}_{suffix}.mem').write_text(''.join(f'{word:016X}\n' for word in tile_major_words(tensor)))
        stages.append({'name':f'Pool{i}','input_shape':list(conv.shape),'output_shape':list(pooled.shape),
                       'output_count':pooled.numel(),'input_scale':scale,'output_scale':scale,'zero_point':0})
    if any(sha256(Path(p))!=h for p,h in identities.items()): raise ValueError('Source changed during export')
    manifest={'role':'isolated pooling POC, no promotion','checkpoint':q['checkpoint'],'sample':sample,
              'source_identity_sha256':identities,'source_sha256':{n:sha256(Path(__file__).with_name(n)) for n in
              ['export_v3_pool_poc.py','export_v3_conv1_poc.py','export_v3_conv2_poc.py','experimental_v3_ptq.py','integer_tensor_ops_ref.py']},
              'layout':'[c_tile][H][W][8], lane0 low byte','stages':stages,'total_output_count':sum(s['output_count'] for s in stages),
              'files':{p.name:sha256(p) for p in output.iterdir()}}
    (output/'manifest.json').write_bytes(json_bytes(manifest))
    print(f'Exported {output}: Pool1 4096, Pool2 1536, Pool3 512; no scale changes')
    return manifest


def pool3_flatten_indices():
    """Physical byte index -> canonical CHW index; no golden layout change."""
    return [c*16+h*4+w for ct in range(4) for h in range(4)
            for w in range(4) for c in range(ct*8,ct*8+8)]


def export_fc(ptq, pool_dir, output):
    """Isolated FC fixtures from saved Pool3, using unchanged PTQ parameters.

    FC1 columns are permuted to match [c_tile][h][w][8], as in ADR-018.
    Direct core configuration exercises K=512; AXI c_in remains only nine bits.
    This does not promote v3 or sequence a network in RTL.
    """
    import json
    from export_v3_conv1_poc import packed_bytes
    from experimental_v3_ptq import wrap32_tensor
    from integer_tensor_ops_ref import integer_flatten_chw_ref
    ptq,pool_dir,output=map(lambda p:Path(p).resolve(),(ptq,pool_dir,output))
    if output.exists(): raise FileExistsError(f'Refusing to overwrite {output}')
    q,_,_,_,sample,identities=verified_inputs(ptq)
    manifest=json.loads((pool_dir/'manifest.json').read_text())
    if manifest['checkpoint']!=q['checkpoint'] or manifest['sample']!=sample:
        raise ValueError('Pool fixture checkpoint/sample identity mismatch')
    for path,digest in manifest['source_identity_sha256'].items():
        if sha256(Path(path))!=digest: raise ValueError('Pool fixture source identity mismatch')
    for name,digest in manifest['files'].items():
        if sha256(pool_dir/name)!=digest: raise ValueError('Pool fixture hash mismatch')
    stage=manifest['stages'][2]
    if stage['output_shape']!=[32,4,4] or stage['output_scale']!=q['activation_scales']['features.7']:
        raise ValueError('Pool3 geometry/scale mismatch')
    words=[int(v,16) for v in (pool_dir/'pool3_expected.mem').read_text().split()]
    if len(words)!=64 or any(v<0 or v>=2**64 for v in words): raise ValueError('Pool3 word count/range')
    physical=torch.tensor([((word>>(8*lane))&255) for word in words for lane in range(8)],dtype=torch.int16)
    physical=torch.where(physical>=128,physical-256,physical).to(torch.int8)
    indices=pool3_flatten_indices()
    chw=torch.empty(512,dtype=torch.int8);chw[indices]=physical
    canonical=torch.tensor(integer_flatten_chw_ref(chw.reshape(32,4,4).tolist()),dtype=torch.int8)
    if tile_major_words(chw.reshape(32,4,4))!=words: raise ValueError('Pool3 layout roundtrip mismatch')
    weights=torch.load(ptq/'weights_int8.pt',map_location='cpu',weights_only=True)
    fixtures=[]
    x=canonical.unsqueeze(0)
    for i,(name,shape,ik,ok) in enumerate([
        ('classifier.1',[64,512],'features.7','classifier.2'),
        ('classifier.3',[10,64],'classifier.2','classifier.3')]):
        p=q['layers'][3+i];w=weights[name+'.weight']
        if (p['name']!=name or p['shape']!=shape or list(w.shape)!=shape or w.dtype!=torch.int8
                or p['kind']!='linear' or p['input_key']!=ik or p['output_key']!=ok or p['relu']!=(i==0)
                or p['s_x']!=q['activation_scales'][ik] or p['s_y']!=q['activation_scales'][ok]):
            raise ValueError('FC topology/scale mismatch')
        mac=integer_mac(x,w)
        stream=physical if i==0 else x[0]
        physical_w=w[:,indices] if i==0 else w
        if not torch.equal(mac,integer_mac(stream.unsqueeze(0),physical_w)):
            raise ValueError('Physical FC weight order differs from canonical MAC')
        y,_=requant_tensor(mac,p['bias_q'],p['M0'],p['n'],relu=i==0)
        biased=wrap32_tensor(mac+torch.tensor(p['bias_q'],dtype=torch.int64))
        fixtures.append((stream,physical_w,mac[0],biased[0],y[0],p))
        x=y.to(torch.int8)
    if any(sha256(Path(p))!=h for p,h in identities.items()): raise ValueError('Source changed')
    output.mkdir(parents=True,exist_ok=False)
    for i,(stream,w,mac,biased,y,p) in enumerate(fixtures,1):
        d=output/f'fc{i}';d.mkdir();cout,k=w.shape;tiles=(cout+7)//8
        def write(name,values,digits):
            (d/name).write_text(''.join(f'{int(v)&((1<<(digits*4))-1):0{digits}X}\n' for v in values))
        write('frame.mem',packed_bytes(stream.tolist()),16)
        for bank in range(8):
            write(f'wbank{bank}.mem',[int(w[c,j]) if c<cout else 0
                for c in range(bank,tiles*8,8) for j in range(k)],2)
        for key,digits,filler in [('bias_q',8,0),('M0',5,65536),('n',2,16)]:
            write(key+'.mem',list(p[key])+[filler]*(tiles*8-cout),digits)
        for tile in range(tiles):
            for suffix,values,digits in [('acc',mac,8),('biased',biased,8),('y',y,16)]:
                vals=[int(values[c]) if c<cout else 0 for c in range(tile*8,tile*8+8)]
                write(f't{tile}_{suffix}.mem',packed_bytes(vals) if suffix=='y' else vals,digits)
    report={'role':'isolated FC functional POC; no promotion','checkpoint':q['checkpoint'],
        'sample':sample,'source_identity_sha256':identities,
        'pool_manifest_sha256':sha256(pool_dir/'manifest.json'),
        'pool3_physical_to_chw_index':indices,
        'K512':'direct core supported; AXI nine-bit c_in cannot encode 512',
        'stages':[{'name':f'FC{i+1}','outputs':len(f[4]),'K':f[1].shape[1],
            'relu':i==0,'final_tile_active_outputs':(len(f[4])-1)%8+1} for i,f in enumerate(fixtures)],
        'files':{str(p.relative_to(output)):sha256(p) for p in output.rglob('*.mem')}}
    (output/'manifest.json').write_bytes(json_bytes(report))
    print(f'Exported {output}: FC1 64 / FC2 10, canonical MAC == physical-order MAC')
    return report


if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--ptq-dir',type=Path,required=True)
    ap.add_argument('--output-dir',type=Path,required=True)
    ap.add_argument('--fc-from-pool',type=Path,help='Export FC fixtures using an existing verified Pool3 fixture')
    a=ap.parse_args();torch.set_num_threads(2)
    if a.fc_from_pool: export_fc(a.ptq_dir,a.fc_from_pool,a.output_dir)
    else: export(a.ptq_dir,a.output_dir)
