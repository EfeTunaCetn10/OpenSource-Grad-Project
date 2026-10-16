"""Isolated CompactCNN-v3 PTQ experiment; no v1 promotion or hardware export.

CPU int64 tensor execution implements the existing wrap32/signed64 arithmetic.
It is checked against the scalar golden primitives; no quantized backend is used.
"""
import argparse
from collections import Counter
import copy
import hashlib
import json
from math import prod
from pathlib import Path
import time

import torch
from torch import nn
from torch.utils.data import DataLoader, Subset
from torchvision.datasets import ImageFolder
from torchvision.datasets.folder import pil_loader

from calibration import REPO_ROOT, json_bytes, sha256, load_checkpoint, read_split_manifest
from data import build_insect_eval_transform
from model_v3 import CompactCNNV3
from observe_activations import TensorExtrema, activation_hooks, weight_statistics
from quantization import POLICY, candidate_scale, quantize_int8, weight_metrics, scaled_values, round_half_up
from bias_quant_ref import quantize_bias_candidate
from candidate_requant_params import candidate_requant_params
from accumulator_safety import require_accumulator_safety
from requant_ref import requant_raw
from compare_candidate_validation import metrics


def discover_layers(model):
    """Discover ordered weight/output boundaries, then enforce the v3 topology."""
    leaves = [(n,m) for n,m in model.named_modules() if n and not list(m.children())]
    rows = []
    previous = 'input'
    for i,(name,module) in enumerate(leaves):
        if isinstance(module,(nn.Conv2d,nn.Linear)):
            relu = i+1 < len(leaves) and isinstance(leaves[i+1][1],nn.ReLU)
            output = leaves[i+1][0] if relu else name
            rows.append(dict(name=name,input_key=previous,output_key=output,relu=relu,
                             kind='conv' if isinstance(module,nn.Conv2d) else 'linear',
                             shape=list(module.weight.shape)))
            previous = output
    expected = [('features.0',[16,3,3,3]),('features.3',[24,16,3,3]),
                ('features.6',[32,24,3,3]),('classifier.1',[64,512]),('classifier.3',[10,64])]
    if [(r['name'],r['shape']) for r in rows] != expected:
        raise ValueError('Expected exactly the experimental 10-class v3 topology')
    if [type(m) for _,m in leaves] != [nn.Conv2d,nn.ReLU,nn.MaxPool2d]*3 + [nn.Flatten,nn.Linear,nn.ReLU,nn.Linear]:
        raise ValueError('Unexpected v3 operators')
    for _,m in leaves:
        if isinstance(m,nn.Conv2d) and (m.padding!=(1,1) or m.stride!=(1,1) or m.dilation!=(1,1) or m.groups!=1):
            raise ValueError('V3 requires padding=1, stride=dilation=1, groups=1')
        if isinstance(m,nn.MaxPool2d) and (m.kernel_size!=2 or m.stride!=2 or m.padding!=0 or m.ceil_mode):
            raise ValueError('Unexpected pool geometry')
    return rows


def calibration_loader(manifest_path, checkpoint, *, root=REPO_ROOT, batch_size=32):
    """Replay the original selection, never select new samples or spoof v1 metadata."""
    manifest_path=Path(manifest_path)
    manifest=json.loads(manifest_path.read_bytes())
    summary=json.loads(manifest_path.with_name('summary.json').read_bytes())
    if sha256(manifest_path)!=summary['selection_manifest_sha256']:
        raise ValueError('Calibration manifest hash mismatch')
    selection=manifest['selection'];prep=manifest['preprocessing']
    if (manifest['split']['name']!='train' or selection['seed']!=42 or
        selection['samples_per_class']!=100 or selection['count']!=1000):
        raise ValueError('Expected original seed42 train-only 10x100 selection')
    if (manifest['class_names']!=checkpoint['class_names'] or prep['mean']!=checkpoint['mean'] or
        prep['std']!=checkpoint['std'] or prep['random_augmentation'] is not False or
        prep['resize']!=[32,32] or prep['color']!='RGB'):
        raise ValueError('Calibration class/preprocessing mismatch')
    transform=build_insect_eval_transform(checkpoint['mean'],checkpoint['std'])
    resize=transform.transforms[0]
    if resize.interpolation.value!=prep['interpolation'] or resize.antialias!=prep['antialias']:
        raise ValueError('Resize policy mismatch')
    data_dir=(root/manifest['split']['data_dir']).resolve();train=data_dir/'train'
    ds=ImageFolder(train,transform=transform,loader=pil_loader)
    if ds.classes!=checkpoint['class_names']: raise ValueError('Class order mismatch')
    _,identity,_=read_split_manifest(data_dir,ds)
    for key,value in identity.items():
        if manifest['split'].get(key)!=value: raise ValueError('Train split identity mismatch')
    indices={str(Path(p).resolve()):i for i,(p,_) in enumerate(ds.samples)}
    chosen=[]
    for sample in manifest['samples']:
        p=(root/sample['path']).resolve()
        if not p.is_relative_to(train.resolve()) or str(p) not in indices:
            raise ValueError('Calibration image outside train membership')
        index=indices[str(p)]
        if (sha256(p)!=sample['sha256'] or ds.samples[index][1]!=sample['label'] or
            ds.classes[sample['label']]!=sample['class']):
            raise ValueError('Calibration image/label mismatch')
        chosen.append(index)
    if len(chosen)!=1000 or len(set(chosen))!=1000 or Counter(s['class'] for s in manifest['samples'])!=Counter({c:100 for c in ds.classes}):
        raise ValueError('Invalid calibration counts or duplicates')
    return DataLoader(Subset(ds,chosen),batch_size=batch_size,shuffle=False,num_workers=0),manifest


def observe(model, loader, rows):
    inputs=TensorExtrema()
    model.eval()
    with activation_hooks(model,[r['output_key'] for r in rows]) as obs, torch.inference_mode():
        for images,_ in loader:
            inputs.update(images);model(images)
        activations={'input':inputs.report(),**{k:o.report() for k,o in obs.items()}}
    return {'activations':activations,'weights':{r['name']:weight_statistics(
        model.get_submodule(r['name']).weight,model.get_submodule(r['name']).bias) for r in rows}}


def prepare(model, statistics, rows):
    scales={k:candidate_scale(s['min'],s['max'],s['absmax']).item()
            for k,s in statistics['activations'].items()}
    layers=[]
    for r in rows:
        layer=model.get_submodule(r['name']);s=statistics['weights'][r['name']]
        sw=candidate_scale(s['min'],s['max'],s['absmax'])
        sx,sy=scales[r['input_key']],scales[r['output_key']]
        weights=quantize_int8(layer.weight,sw,axis=0)
        bias=quantize_bias_candidate(layer.bias,sx,sw).tolist()
        params=candidate_requant_params(sx,sy,sw.tolist())
        safety=require_accumulator_safety(bias,prod(r['shape'][1:]),layer=r['name'])
        layers.append({**r,'weights':weights,'bias_q':bias,'M0':params['M0'],'n':params['n'],
                       's_x':sx,'s_y':sy,'s_w':sw.tolist(),'requant_diagnostic':params,
                       'accumulator_safety':safety,'weight_metrics':weight_metrics(layer.weight,weights,sw)})
    return {'activation_scales':scales,'layers':layers}


def wrap32_tensor(x):
    return ((x+(1<<31)) & 0xffffffff)-(1<<31)


def integer_mac(x, weights):
    """Exact CPU int64 dot products; Conv uses integer zero padding and ci/kh/kw order."""
    for value in (x,weights):
        if value.device.type!='cpu' or value.dtype not in (torch.int8,torch.int64) or not value.numel():
            raise ValueError('Expected nonempty CPU integer tensor')
        if value.min() < -128 or value.max() > 127: raise ValueError('INT8 domain required')
    x,w=x.to(torch.int64),weights.to(torch.int64)
    if w.ndim==4:
        if x.ndim!=4 or x.shape[1]!=w.shape[1] or w.shape[2:]!=(3,3):
            raise ValueError('Expected NCHW and OI33 weights')
        x=torch.nn.functional.pad(x,(1,1,1,1),value=0)
        # [N,C,H,W,kh,kw] -> [N,H,W,C,kh,kw]; no float unfold/convolution.
        patches=x.unfold(2,3,1).unfold(3,3,1).permute(0,2,3,1,4,5)
        dot=patches.reshape(*patches.shape[:3],-1) @ w.flatten(1).T
        result=dot.permute(0,3,1,2).contiguous()
    elif w.ndim==2 and x.ndim==2 and x.shape[1]==w.shape[1]:
        result=x @ w.T
    else: raise ValueError('Invalid Linear geometry')
    return wrap32_tensor(result)


def requant_tensor(mac, bias, M0, n, *, relu):
    """Vector form of existing scalar requant, with validated signed64 bounds."""
    if mac.dtype!=torch.int64 or mac.device.type!='cpu' or mac.ndim not in (2,4):
        raise ValueError('Expected CPU int64 NC or NCHW MAC')
    if type(relu) is not bool: raise TypeError('relu must be bool')
    channels=mac.shape[1]
    for values in (bias,M0,n):
        if len(values)!=channels or any(type(v) is not int for v in values):
            raise ValueError('Expected integer channel parameters')
    for b,m,s in zip(bias,M0,n):
        if not -(1<<31)<=b<(1<<31): raise ValueError('Bias outside INT32')
        requant_raw(0,m,s)
    shape=(1,channels)+((1,1) if mac.ndim==4 else ())
    def channel(v): return torch.tensor(v,dtype=torch.int64).reshape(shape)
    acc=wrap32_tensor(wrap32_tensor(mac)+channel(bias))
    raw=(acc*channel(M0)+channel([0 if s==0 else 1<<(s-1) for s in n])) >> channel(n)
    # For valid INT32/M0/n, product+offset fits signed64 even at n=63.
    lower=0 if relu else -128
    clamps=int(((raw<lower)|(raw>127)).sum())
    return raw.clamp(lower,127),clamps


def integer_forward(images, prepared):
    sx=prepared['activation_scales']['input']
    normalized,_=scaled_values(images,sx)
    rounded=round_half_up(normalized)
    diagnostics={'input_elements':images.numel(),
                 'input_clipping_count':int(((rounded < -127)|(rounded > 127)).sum()),'stages':{}}
    x=quantize_int8(images,sx).to(torch.int64)
    for p in prepared['layers']:
        if p['kind']=='linear': x=x.flatten(1)
        # Recheck configuration safety at the execution boundary.
        require_accumulator_safety(p['bias_q'],prod(p['shape'][1:]),layer=p['name'])
        x,clamps=requant_tensor(integer_mac(x,p['weights']),p['bias_q'],p['M0'],p['n'],relu=p['relu'])
        diagnostics['stages'][p['name']]={'shape':list(x.shape[1:]),'elements':x.numel(),
            'clamp_count':clamps,'minus128_count':int((x==-128).sum()),'plus127_count':int((x==127).sum())}
        if p['kind']=='conv':
            x=x.unfold(2,2,2).unfold(3,2,2).amax(dim=(-1,-2))
    return x,diagnostics


def run(checkpoint_path, manifest_path, output_dir):
    checkpoint_path,manifest_path,output_dir=map(Path,(checkpoint_path,manifest_path,output_dir))
    if output_dir.exists(): raise FileExistsError(output_dir)
    if output_dir.resolve().parent!=checkpoint_path.resolve().parent or output_dir.name!='ptq':
        raise ValueError('Use a new ptq/ under the v3 experiment')
    c,cp_hash=load_checkpoint(checkpoint_path)
    if (c.get('model_name')!='CompactCNNV3' or c.get('seed')!=42 or c.get('best_epoch')!=52 or
        c.get('training_config',{}).get('model_version')!='v3'):
        raise ValueError('Expected v3 seed42 epoch52 checkpoint')
    prior=checkpoint_path.with_name('validation_metrics.json')
    reference=json.loads(prior.read_text())
    if reference['checkpoint_sha256']!=cp_hash: raise ValueError('FP32 reference checkpoint mismatch')
    model=CompactCNNV3(len(c['class_names']));model.load_state_dict(c['model_state'],strict=True);model.eval()
    rows=discover_layers(model)
    loader,manifest=calibration_loader(manifest_path,c)
    inputs={str(p.resolve()):sha256(p) for p in (checkpoint_path,manifest_path,manifest_path.with_name('summary.json'),prior)}
    data_dir=REPO_ROOT/manifest['split']['data_dir']
    split_path=data_dir/'split_manifest.json'
    inputs[str(split_path.resolve())]=sha256(split_path)
    state={k:v.clone() for k,v in model.state_dict().items()}
    statistics=observe(model,loader,rows)
    prepared=prepare(model,statistics,rows)
    print('Calibrated 1000 train images; prepared 3 Conv + 2 Linear layers',flush=True)
    ds=ImageFolder(data_dir/'val',transform=build_insect_eval_transform(c['mean'],c['std']),loader=pil_loader)
    if ds.classes!=c['class_names']: raise ValueError('Validation class order mismatch')
    split=json.loads(split_path.read_text())
    declared={s['destination']:s for s in split['samples'] if s['split']=='val'}
    if {str(Path(p).relative_to(data_dir)) for p,_ in ds.samples}!=set(declared):
        raise ValueError('Validation split inventory mismatch')
    samples=[]
    for p,y in ds.samples:
        path=Path(p);record=declared[str(path.relative_to(data_dir))];h=sha256(path)
        if not path.resolve().is_relative_to((data_dir/'val').resolve()) or h!=record['sha256'] or record['class']!=ds.classes[y]:
            raise ValueError('Validation image identity mismatch')
        samples.append({'path':str(path.relative_to(REPO_ROOT)),'label':y,'sha256':h})
    labels=[];fp=[];iq=[];diagnostics={'input_elements':0,'input_clipping_count':0,'stages':{}}
    started=time.perf_counter()
    with torch.inference_mode():
        for images,ys in DataLoader(ds,batch_size=32,shuffle=False,num_workers=0):
            fp.extend(model(images).argmax(1).tolist())
            logits,diag=integer_forward(images,prepared)
            iq.extend(logits.argmax(1).tolist());labels.extend(ys.tolist())
            for k in ('input_elements','input_clipping_count'): diagnostics[k]+=diag[k]
            for name,s in diag['stages'].items():
                target=diagnostics['stages'].setdefault(name,{'shape':s['shape'],'elements':0,'clamp_count':0,'minus128_count':0,'plus127_count':0})
                for k in ('elements','clamp_count','minus128_count','plus127_count'): target[k]+=s[k]
            if len(labels)%320==0: print(f'Validation {len(labels)}/{len(ds)}',flush=True)
    elapsed=time.perf_counter()-started
    result=metrics(labels,fp,iq,ds.classes)
    if result['fp32_accuracy']!=reference['accuracy'] or result['fp32_confusion_true_pred']!=reference['confusion_matrix']:
        raise ValueError('FP32 validation no longer matches saved reference')
    for key in ('fp32','int8'):
        recalls=[r[key+'_accuracy'] for r in result['per_class'] if r['samples']]
        result[key+'_macro_recall']=sum(recalls)/len(recalls)
    result['macro_recall_drop_pp']=100*(result['fp32_macro_recall']-result['int8_macro_recall'])
    result['accuracy_drop_pp']=100*(result['fp32_accuracy']-result['int8_accuracy'])
    result['prediction_changes']=sum(a!=b for a,b in zip(fp,iq))
    for row in result['per_class']:
        row['int8_minus_fp32_recall_pp']=100*(row['int8_accuracy']-row['fp32_accuracy']) if row['samples'] else None
    if any(sha256(Path(p))!=h for p,h in inputs.items()): raise ValueError('Source identity changed during run')
    if any(not torch.equal(v,model.state_dict()[k]) for k,v in state.items()): raise ValueError('FP32 model mutated')
    source_names=['experimental_v3_ptq.py','model_v3.py','calibration.py','data.py','observe_activations.py',
                  'quantization.py','bias_quant_ref.py','candidate_requant_params.py','multiplier_analysis.py',
                  'accumulator_safety.py','requant_ref.py','compare_candidate_validation.py']
    qparams={'role':'experimental v3 candidate PTQ; not promoted or hardware export',
             'model_version':'v3','checkpoint':{'path':str(checkpoint_path.resolve().relative_to(REPO_ROOT)),'sha256':cp_hash,'epoch':52},
             'policy':copy.deepcopy(POLICY),'arithmetic':'INT32 wrap; signed64 half-up; requant clamp [0,127] or [-128,127]',
             'bias_policy':'candidate float64 half-up in s_x*s_w domain, INT32 checked',
             'multiplier_policy':'unchanged analyze_multiplier selection, search n=1..49',
             'calibration':{'source_manifest':str(manifest_path),'sha256':sha256(manifest_path),
                            'selection':manifest['selection'],'preprocessing':manifest['preprocessing'],'limitations':manifest['limitations']},
             'activation_scales':prepared['activation_scales'],
             'layers':[{k:v for k,v in p.items() if k!='weights'} for p in prepared['layers']],
             'input_sha256':inputs,'source_sha256':{n:sha256(Path(__file__).with_name(n)) for n in source_names},
             'torch_version':torch.__version__,'scale_transfer':'Pool/Flatten preserve scale and zero point; CHW flatten',
             'padding':'integer zero for zero-point=0, no contract change'}
    report={'schema_version':1,'split':'val','metrics':result,'diagnostics':diagnostics,
            'samples':samples,'fp32_predictions':fp,'int8_predictions':iq,
            'runtime_seconds':elapsed,'seconds_per_image':elapsed/len(labels),
            'checkpoint_sha256':cp_hash,'class_names':ds.classes,'role':'experimental v3 only'}
    output_dir.mkdir(exist_ok=False)
    files={'qparams.json':qparams,'statistics.json':statistics,'validation_metrics.json':report,
           'calibration_selection_manifest.json':manifest}
    for name,value in files.items(): (output_dir/name).write_bytes(json_bytes(value))
    torch.save({p['name']+'.weight':p['weights'] for p in prepared['layers']},output_dir/'weights_int8.pt')
    (output_dir/'artifact_manifest.json').write_bytes(json_bytes({'model_version':'v3','checkpoint_sha256':cp_hash,
        'files':{p.name:sha256(p) for p in output_dir.iterdir() if p.is_file()},'command':__import__('sys').argv}))
    print(json.dumps(result,indent=2),flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('checkpoint','selection-manifest','output-dir'): parser.add_argument('--'+name,type=Path,required=True)
    args=parser.parse_args()
    torch.set_num_threads(2);torch.manual_seed(42)
    run(args.checkpoint,args.selection_manifest,args.output_dir)
