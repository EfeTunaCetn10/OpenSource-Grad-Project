"""Isolated 48x48 deep CompactCNN-v3 PTQ entry point; no promotion or hardware export.

Numerical primitives and calibration selection are reused unchanged from v3.
Adds the 6x6 refinement convolution and final pool before Flatten288.
The original selection manifest retains its 32x32 provenance; effective transforms
use the verified checkpoint's 48x48 size, recorded separately in qparams.
"""
import argparse
import copy
import json
from pathlib import Path
import time

import torch
from torch import nn
from torch.utils.data import DataLoader
from torchvision.datasets import ImageFolder
from torchvision.datasets.folder import pil_loader

from calibration import REPO_ROOT, json_bytes, sha256, load_checkpoint
from model_v3_48_deep_pool_refine import CompactCNNV3_48DeepPoolRefine as CompactCNNV3_48DeepPoolRefine
from quantization import POLICY
from compare_candidate_validation import metrics
from experimental_v3_ptq import (
    observe, prepare,
)


from experimental_v3_48_ptq import checkpoint_transform, calibration_loader
from experimental_v3_48_deep_ptq import integer_forward


def discover_layers(model):
    """Discover ordered weight/output boundaries, then enforce the v3_48_deep_pool_refine topology."""
    leaves = [(n,m) for n,m in model.named_modules() if n and not list(m.children())]
    rows = []
    previous = 'input'
    for i,(name,module) in enumerate(leaves):
        if isinstance(module,(nn.Conv2d,nn.Linear)):
            relu = i+1 < len(leaves) and isinstance(leaves[i+1][1],nn.ReLU)
            output = leaves[i+1][0] if relu else name
            pool_index = i+2 if relu else i+1
            pool_after = pool_index < len(leaves) and isinstance(leaves[pool_index][1],nn.MaxPool2d)
            rows.append(dict(name=name,input_key=previous,output_key=output,relu=relu,pool_after=pool_after,
                             kind='conv' if isinstance(module,nn.Conv2d) else 'linear',
                             shape=list(module.weight.shape)))
            previous = output
    expected = [('features.0',[16,3,3,3]),('features.3',[24,16,3,3]),
                ('features.6',[32,24,3,3]),('features.8',[32,32,3,3]),('features.11',[32,32,3,3]),('classifier.1',[64,288]),('classifier.3',[10,64])]
    if [(r['name'],r['shape']) for r in rows] != expected:
        raise ValueError('Expected exactly the experimental 10-class v3_48_deep_pool_refine topology')
    if [type(m) for _,m in leaves] != ([nn.Conv2d,nn.ReLU,nn.MaxPool2d]*2 +
            [nn.Conv2d,nn.ReLU,nn.Conv2d,nn.ReLU,nn.MaxPool2d] +
            [nn.Conv2d,nn.ReLU,nn.MaxPool2d] +
            [nn.Flatten,nn.Linear,nn.ReLU,nn.Linear]):
        raise ValueError('Unexpected v3 operators')
    for _,m in leaves:
        if isinstance(m,nn.Conv2d) and (m.padding!=(1,1) or m.stride!=(1,1) or m.dilation!=(1,1) or m.groups!=1):
            raise ValueError('V3 requires padding=1, stride=dilation=1, groups=1')
        if isinstance(m,nn.MaxPool2d) and (m.kernel_size!=2 or m.stride!=2 or m.padding!=0 or m.ceil_mode):
            raise ValueError('Unexpected pool geometry')
    expected_shapes = [(16,48,48),(16,48,48),(16,24,24),
                       (24,24,24),(24,24,24),(24,12,12),
                       (32,12,12),(32,12,12),(32,12,12),(32,12,12),
                       (32,6,6),(32,6,6),(32,6,6),(32,3,3),
                       (288,),(64,),(64,),(10,)]
    with torch.inference_mode():
        x = torch.zeros(1,3,48,48)
        for (name,module),shape in zip(leaves,expected_shapes):
            x = module(x)
            if tuple(x.shape[1:]) != shape:
                raise ValueError(f'Unexpected activation shape at {name}: {tuple(x.shape)}')
    return rows


def run(checkpoint_path, manifest_path, output_dir):
    checkpoint_path,manifest_path,output_dir=map(Path,(checkpoint_path,manifest_path,output_dir))
    if output_dir.exists(): raise FileExistsError(output_dir)
    if output_dir.resolve().parent!=checkpoint_path.resolve().parent or output_dir.name!='ptq':
        raise ValueError('Use a new ptq/ under the v3_48_deep_pool_refine experiment')
    c,cp_hash=load_checkpoint(checkpoint_path)
    if (c.get('model_name')!='CompactCNNV3_48DeepPoolRefine' or c.get('seed')!=123 or c.get('best_epoch')!=57 or
        c.get('training_config',{}).get('model_version')!='v3_48_deep_pool_refine' or
        c.get('image_size')!=[48,48] or c.get('input_channels')!=3):
        raise ValueError('Expected v3_48_deep_pool_refine seed123 epoch57 checkpoint')
    prior=checkpoint_path.with_name('validation_metrics.json')
    reference=json.loads(prior.read_text()) if prior.exists() else None
    if reference is not None and reference['checkpoint_sha256']!=cp_hash: raise ValueError('FP32 reference checkpoint mismatch')
    model=CompactCNNV3_48DeepPoolRefine(len(c['class_names']));model.load_state_dict(c['model_state'],strict=True);model.eval()
    rows=discover_layers(model)
    loader,manifest=calibration_loader(manifest_path,c)
    input_paths=[checkpoint_path,manifest_path,manifest_path.with_name('summary.json')]
    if reference is not None: input_paths.append(prior)
    inputs={str(p.resolve()):sha256(p) for p in input_paths}
    data_dir=REPO_ROOT/manifest['split']['data_dir']
    split_path=data_dir/'split_manifest.json'
    inputs[str(split_path.resolve())]=sha256(split_path)
    state={k:v.clone() for k,v in model.state_dict().items()}
    statistics=observe(model,loader,rows)
    prepared=prepare(model,statistics,rows)
    print('Calibrated 1000 train images; prepared 5 Conv + 2 Linear layers',flush=True)
    ds=ImageFolder(data_dir/'val',transform=checkpoint_transform(c),loader=pil_loader)
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
    if reference is not None and (result['fp32_accuracy']!=reference['accuracy'] or
                                  result['fp32_confusion_true_pred']!=reference['confusion_matrix']):
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
    source_names=['experimental_v3_48_deep_pool_refine_ptq.py','model_v3_48_deep_pool_refine.py','model_v3_48_deep_pool.py','model_v3_48_deep.py','experimental_v3_48_deep_ptq.py','experimental_v3_48_ptq.py','experimental_v3_ptq.py','model_v3_48.py','model_v3.py','calibration.py','data.py','observe_activations.py',
                  'quantization.py','bias_quant_ref.py','candidate_requant_params.py','multiplier_analysis.py',
                  'accumulator_safety.py','requant_ref.py','compare_candidate_validation.py']
    qparams={'role':'experimental v3_48_deep_pool_refine candidate PTQ; not promoted or hardware export',
             'model_version':'v3_48_deep_pool_refine','checkpoint':{'path':str(checkpoint_path.resolve().relative_to(REPO_ROOT)),'sha256':cp_hash,'epoch':57},
             'policy':copy.deepcopy(POLICY),'arithmetic':'INT32 wrap; signed64 half-up; requant clamp [0,127] or [-128,127]',
             'bias_policy':'candidate float64 half-up in s_x*s_w domain, INT32 checked',
             'multiplier_policy':'unchanged analyze_multiplier selection, search n=1..49',
             'calibration':{'source_manifest':str(manifest_path),'sha256':sha256(manifest_path),
                            'selection':manifest['selection'],
                            'source_preprocessing':manifest['preprocessing'],
                            'preprocessing':{**manifest['preprocessing'],'resize':list(c['image_size'])},
                            'limitations':manifest['limitations']},
             'activation_scales':prepared['activation_scales'],
             'layers':[{k:v for k,v in p.items() if k!='weights'} for p in prepared['layers']],
             'input_sha256':inputs,'source_sha256':{n:sha256(Path(__file__).with_name(n)) for n in source_names},
             'torch_version':torch.__version__,'scale_transfer':'Pool/Flatten preserve scale and zero point; CHW flatten',
             'padding':'integer zero for zero-point=0, no contract change'}
    report={'schema_version':1,'split':'val','metrics':result,'diagnostics':diagnostics,
            'samples':samples,'fp32_predictions':fp,'int8_predictions':iq,
            'runtime_seconds':elapsed,'seconds_per_image':elapsed/len(labels),
            'checkpoint_sha256':cp_hash,'class_names':ds.classes,'role':'experimental v3_48_deep_pool_refine only',
            'image_size':c['image_size'],
            'fp32_reference_source':'recomputed and checked against saved reference' if reference is not None else 'recomputed from checkpoint on validation split'}
    output_dir.mkdir(exist_ok=False)
    files={'qparams.json':qparams,'statistics.json':statistics,'validation_metrics.json':report,
           'calibration_selection_manifest.json':manifest}
    for name,value in files.items(): (output_dir/name).write_bytes(json_bytes(value))
    torch.save({p['name']+'.weight':p['weights'] for p in prepared['layers']},output_dir/'weights_int8.pt')
    (output_dir/'artifact_manifest.json').write_bytes(json_bytes({'model_version':'v3_48_deep_pool_refine','checkpoint_sha256':cp_hash,
        'files':{p.name:sha256(p) for p in output_dir.iterdir() if p.is_file()},'command':__import__('sys').argv}))
    print(json.dumps(result,indent=2),flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('checkpoint','selection-manifest','output-dir'): parser.add_argument('--'+name,type=Path,required=True)
    args=parser.parse_args()
    torch.set_num_threads(2);torch.manual_seed(123)
    run(args.checkpoint,args.selection_manifest,args.output_dir)
