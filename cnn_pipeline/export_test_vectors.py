"""Canonical candidate golden vectors; no hardware packing, timing or RTL claims."""
import argparse
from copy import deepcopy
import hashlib
import json
from math import prod
from pathlib import Path

import torch
from torchvision.datasets.folder import pil_loader

from calibration import REPO_ROOT, json_bytes, sha256
from data import build_insect_eval_transform
from candidate_integer_model import load_candidate_integer_model
from candidate_integer_forward import candidate_integer_forward
from multiplier_analysis import LAYERS
from integer_linear_ref import integer_linear_ref, wrap32
from integer_conv2d_ref import integer_conv2d_ref
from integer_layer_ref import integer_linear_layer_ref, integer_conv2d_layer_ref
from requant_ref import requant_raw, requant_ref


def integer_tensor(values, shape, dtype, layout):
    """Validate and serialize integers without a float intermediate."""
    limits={'int8':(-128,127),'int32':(-2**31,2**31-1),'int64':(-2**63,2**63-1)}
    low,high=limits[dtype]
    def check(v, dims):
        if not dims:
            if type(v) is not int or not low <= v <= high:
                raise ValueError(f'Expected {dtype} integer value')
        else:
            if type(v) not in (list,tuple) or len(v)!=dims[0]:
                raise ValueError('Tensor shape mismatch')
            for item in v: check(item,dims[1:])
    check(values,shape)
    return {'dtype':dtype,'shape':list(shape),'layout':layout,'values':deepcopy(values)}


def requant_vectors():
    cases=[('positive',6,65536,17),('negative',-6,65536,17),
           ('n0',-1,65536,0),('n1',1,65537,1),('n49',2**31-1,131071,49),
           ('n50',-2**31,131071,50),('n63',2**31-1,131071,63),
           ('positive_tie',5,65536,17),('negative_tie',-5,65536,17),
           ('positive_saturation',1000,65536,16),('negative_saturation',-1000,65536,16),
           ('positive_wrap',2**31,65536,16),('negative_wrap',-2**31-1,65536,16)]
    return [{'name':name,'acc_input':acc,'wrapped_acc':wrap32(acc),'M0':m,'n':n,
             'half_ulp':0 if n==0 else 1<<(n-1),'relu':relu,
             'expected_raw':requant_raw(acc,m,n),'expected_int8':requant_ref(acc,m,n,relu=relu)}
            for name,acc,m,n in cases for relu in (False,True)]


def focused_vectors():
    x=[2,-3,4];w=[[5,6,-2],[-1,0,3]];bias=[1,-7];m=[65536,98304];n=[17,17]
    mac=integer_linear_ref(x,w);acc=[wrap32(a+b) for a,b in zip(mac,bias)]
    cx=[[[1,2,3],[4,5,6],[7,8,9]]];cw=[[[[1,2],[3,4]]]]
    cmac=integer_conv2d_ref(cx,cw)
    cacc=[[[wrap32(v-40) for v in row] for row in plane] for plane in cmac]
    return {'short_mac':{'x':x,'weights':w[0],'expected_int32':mac[0]},
            'linear':{'x':x,'weights':w,'bias_q':bias,'M0':m,'n':n,'relu':False,
                      'expected_mac_int32':mac,'expected_acc_int32':acc,
                      'expected_raw':[requant_raw(a,mm,nn) for a,mm,nn in zip(acc,m,n)],
                      'expected_int8':integer_linear_layer_ref(x,w,bias,m,n,relu=False)},
            'conv2d':{'x':cx,'weights':cw,'input_layout':'CHW','weight_layout':'OIHW',
                      'bias_q':[-40],'M0':[65536],'n':[17],'relu':False,
                      'stride':1,'padding':0,'dilation':1,'kernel_flip':False,
                      'expected_mac_int32':cmac,'expected_acc_int32':cacc,
                      'expected_raw':[[[requant_raw(v,65536,17) for v in row] for row in plane] for plane in cacc],
                      'expected_int8':integer_conv2d_layer_ref(cx,cw,[-40],[65536],[17],relu=False)}}


def build_vectors(image, prepared, *, sample, class_names, input_provenance):
    """Pure assembly; caller supplies verified real provenance or labelled fixture."""
    if len(class_names)!=10 or len(set(class_names))!=10 or type(sample['label']) is not int or not 0<=sample['label']<10:
        raise ValueError('Expected ten ordered classes and valid sample label')
    if sample['class']!=class_names[sample['label']]: raise ValueError('Sample class mismatch')
    logits,trace=candidate_integer_forward(image,prepared,trace=True,capture_tensors=True)
    files={'requant_vectors.json':{'schema_version':1,'vectors':requant_vectors()},
           'focused_vectors.json':{'schema_version':1,**focused_vectors()}}
    order=[]
    for i,(name,xkey,ykey,shape) in enumerate(LAYERS):
        p=prepared['layers'][name];order.append(name);count=shape[0]
        files[f'layer_params/{name}.json']={
            'layer':name,'order':i,'K':prod(shape[1:]),'relu':p['relu'],
            'weights':integer_tensor(p['weights_list'],shape,'int8','OIHW' if len(shape)==4 else 'OI'),
            'bias_q':integer_tensor(p['bias_q'],[count],'int32','O'),
            'M0':integer_tensor(p['M0'],[count],'int32','O'),
            'n':integer_tensor(p['n'],[count],'int32','O'),
            'M0_contract':'positive [65536,131071], signed 18-bit carrier',
            'n_contract':'unsigned 6-bit [0,63]; JSON int32 container only',
            'input_scale':p['s_x'],'weight_scales':list(p['s_w']),'output_scale':p['s_y'],
            'input_scale_name':xkey,'output_scale_name':ykey,'zero_point':0,
            'accumulator_safety':deepcopy(p['accumulator_safety'])}
    stage_order=[]
    for s in trace['stages']:
        name='input_int8' if s['stage']=='input' else s['stage'];stage_order.append(name)
        files[f'expected/{name}.json']={**integer_tensor(s.pop('values'),s['shape'],'int8','CHW' if len(s['shape'])==3 else 'vector'),
                                      'stage':name,'scale':s['scale'],'scale_name':s['scale_name'],'zero_point':0}
    files['normalized_input.json']={'dtype':'float32','shape':[3,32,32],'layout':'CHW',
                                     'values':image.detach().tolist(),'provenance':deepcopy(input_provenance)}
    files['metadata.json']={'schema_version':1,'role':'canonical candidate golden test vectors; not packed hardware export',
                            'sample':deepcopy(sample),'class_names':list(class_names),
                            'input_provenance':deepcopy(input_provenance),
                            'model_provenance':deepcopy(prepared.get('provenance',{'status':'synthetic fixture; unverified'})),
                            'layer_order':order,'stage_order':stage_order,'logits':logits,
                            'trace':trace,'accumulator':'signed INT32 wrap modulo 2^32',
                            'requant':'signed64; n=0..63; half-up ties toward +inf',
                            'layout':'CHW activations; OIHW Conv; OI Linear; FC3 signed INT8',
                            'proposed_hardware_semantics_applied':False}
    return files


def write_vectors(files, output_dir):
    """Deterministic JSON bytes plus hashes; no timestamps or overwrite."""
    output_dir=Path(output_dir)
    if output_dir.exists(): raise FileExistsError(output_dir)
    encoded={}
    for name,value in files.items():
        path=Path(name)
        if path.is_absolute() or '..' in path.parts: raise ValueError('Unsafe output path')
        encoded[name]=json_bytes(value)
    metadata=deepcopy(files['metadata.json'])
    metadata['file_sha256']={name:hashlib.sha256(raw).hexdigest() for name,raw in encoded.items() if name!='metadata.json'}
    encoded['metadata.json']=json_bytes(metadata)
    output_dir.mkdir(parents=True,exist_ok=False)
    for name,raw in encoded.items():
        p=output_dir/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(raw)


def export_real(qparams_path, output_dir):
    """Use first existing train calibration-manifest sample; never reselect/calibrate."""
    output_dir=Path(output_dir);base=REPO_ROOT/'cnn_pipeline/outputs/hardware_test_vectors'
    if output_dir.exists(): raise FileExistsError(output_dir)
    if output_dir.resolve()==base or not output_dir.resolve().is_relative_to(base):
        raise ValueError('Use a new run folder under outputs/hardware_test_vectors')
    prepared=load_candidate_integer_model(qparams_path)
    cal=prepared['provenance']['calibration'];mp=REPO_ROOT/cal['selection_manifest_path']
    if sha256(mp)!=cal['selection_manifest_sha256']: raise ValueError('Manifest changed')
    manifest=json.loads(mp.read_text());sample=deepcopy(manifest['samples'][0]);ip=REPO_ROOT/sample['path']
    if not ip.resolve().is_relative_to((REPO_ROOT/cal['split']['data_dir']/'train').resolve()):
        raise ValueError('Debug sample is not train-only')
    if sha256(ip)!=sample['sha256']: raise ValueError('Image hash mismatch')
    pp=cal['preprocessing'];image=build_insect_eval_transform(pp['mean'],pp['std'])(pil_loader(ip))
    provenance={'preprocessing':pp,'selection_manifest_sha256':cal['selection_manifest_sha256'],
                'selection':'existing manifest samples[0], no new sampling','qparams_path':str(qparams_path),
                'qparams_sha256':sha256(Path(qparams_path)),'split':'train'}
    files=build_vectors(image,prepared,sample=sample,class_names=manifest['class_names'],input_provenance=provenance)
    sources=['export_test_vectors.py','candidate_integer_forward.py','candidate_integer_model.py','integer_layer_ref.py',
             'integer_conv2d_ref.py','integer_linear_ref.py','integer_tensor_ops_ref.py','requant_ref.py',
             'quantization.py','bias_quant_ref.py','candidate_requant_params.py','multiplier_analysis.py','data.py']
    files['metadata.json']['source_sha256']={name:sha256(Path(__file__).with_name(name)) for name in sources}
    for path,h in prepared['provenance']['input_sha256'].items():
        if sha256(Path(path))!=h: raise ValueError('Source artifact changed during export')
    if sha256(ip)!=sample['sha256']: raise ValueError('Sample changed during export')
    write_vectors(files,output_dir)
    return files['metadata.json']


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--qparams',type=Path,required=True);parser.add_argument('--output-dir',type=Path,required=True)
    args=parser.parse_args()
    torch.set_num_threads(2)
    result=export_real(args.qparams,args.output_dir)
    print(json.dumps({'sample':result['sample'],'logits':result['logits'],'directory':str(args.output_dir)}))
