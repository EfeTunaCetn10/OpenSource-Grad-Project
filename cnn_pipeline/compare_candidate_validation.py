"""Deterministic validation-only FP32/candidate INT8 evaluation; no tuning."""
import argparse
import hashlib
import json
import random
import time
import warnings
from pathlib import Path

import torch

from calibration import REPO_ROOT, load_checkpoint, validate_metadata, sha256, json_bytes
from data import build_insect_loaders
from model import LeNet5
from candidate_integer_model import load_candidate_integer_model
from candidate_integer_forward import candidate_integer_forward


def subset_indices(size, limit=None, seed=42):
    if type(size) is not int or size <= 0 or type(seed) is not int:
        raise ValueError('Expected positive size and integer seed')
    if limit is not None and (type(limit) is not int or limit <= 0):
        raise ValueError('limit must be positive or None')
    # Shuffle even for full split: the 100-image pilot is a prefix of full run.
    indices = list(range(size))
    random.Random(seed).shuffle(indices)
    return indices[:limit] if limit is not None else indices


def metrics(labels, fp, iq, classes):
    if not labels or len(labels) != len(fp) or len(labels) != len(iq):
        raise ValueError('Nonempty equally sized predictions and labels required')
    if not classes or len(set(classes)) != len(classes):
        raise ValueError('Unique class names required')
    k=len(classes)
    if any(type(v) is not int or not 0 <= v < k for v in labels+fp+iq):
        raise ValueError('Class index outside class order')
    fc=[[0]*k for _ in classes];ic=[[0]*k for _ in classes];agreement=[[0]*k for _ in classes]
    counts=dict(both_correct=0,fp32_correct_int8_wrong=0,fp32_wrong_int8_correct=0,both_wrong=0)
    for y,a,b in zip(labels,fp,iq):
        fc[y][a]+=1;ic[y][b]+=1;agreement[a][b]+=1
        key='both_correct' if a==y and b==y else 'fp32_correct_int8_wrong' if a==y else 'fp32_wrong_int8_correct' if b==y else 'both_wrong'
        counts[key]+=1
    n=len(labels);fa=sum(fc[c][c] for c in range(k))/n;ia=sum(ic[c][c] for c in range(k))/n
    per=[]
    for c,name in enumerate(classes):
        ids=[i for i,y in enumerate(labels) if y==c];num=len(ids)
        per.append({'class':name,'label':c,'samples':num,
                    'fp32_accuracy':sum(fp[i]==c for i in ids)/num if num else None,
                    'int8_accuracy':sum(iq[i]==c for i in ids)/num if num else None,
                    'agreement':sum(fp[i]==iq[i] for i in ids)/num if num else None})
    return {'samples':n,'fp32_accuracy':fa,'int8_accuracy':ia,
            'int8_minus_fp32_pp':100*(ia-fa),'absolute_accuracy_difference_pp':100*abs(ia-fa),
            'agreement_rate':sum(agreement[c][c] for c in range(k))/n,'accounting':counts,
            'per_class':per,'fp32_confusion_true_pred':fc,'int8_confusion_true_pred':ic,
            'agreement_matrix_fp32_int8':agreement}


def add_diagnostics(total, trace):
    total['input_elements']+=trace['input_elements']
    total['input_clipping_count']+=trace['input_clipping_count']
    for s in trace['stages']:
        row=total['stages'].setdefault(s['stage'],dict(output_count=0,minus128_count=0,plus127_count=0))
        for key in row: row[key]+=s[key]


def save_report(report, output_dir):
    if report['schema_version'] != 1 or report['split']['name'] != 'val' or report['metrics']['samples'] != len(report['samples']):
        raise ValueError('Invalid evaluation report schema')
    payload=json_bytes(report)  # Reject non-finite JSON before creating output directory.
    output_dir=Path(output_dir)
    output_dir.mkdir(parents=True,exist_ok=False)
    (output_dir/'report.json').write_bytes(payload)


def evaluate(qparams_path, data_dir, *, limit=100, seed=42):
    started=time.perf_counter()
    prepared=load_candidate_integer_model(qparams_path)
    provenance=prepared['provenance'];cp_path=REPO_ROOT/provenance['checkpoint']['path']
    checkpoint,digest=load_checkpoint(cp_path)
    if digest != provenance['checkpoint']['sha256']: raise ValueError('Checkpoint identity changed')
    classes,mean,std=validate_metadata(checkpoint)
    data_dir=Path(data_dir).resolve();stats_path=data_dir/'stats.json';split_path=data_dir/'split_manifest.json'
    stats_hash,split_hash=sha256(stats_path),sha256(split_path)
    if split_hash != provenance['calibration']['split']['manifest_sha256']:
        raise ValueError('Unexpected dataset split identity')
    bundle=build_insect_loaders(data_dir,stats_path,1,0,False)
    if bundle.class_names != classes or bundle.mean != mean or bundle.std != std:
        raise ValueError('Dataset classes/normalization differ from checkpoint')
    dataset=bundle.val_loader.dataset
    split=json.loads(split_path.read_text())
    declared={s['destination']:s for s in split['samples'] if s['split']=='val'}
    actual={str(Path(p).relative_to(data_dir)) for p,_ in dataset.samples}
    if actual != set(declared): raise ValueError('Validation inventory differs from split manifest')
    with torch.random.fork_rng(devices=[]): model=LeNet5(3,len(classes))
    model.load_state_dict(checkpoint['model_state'],strict=True);model.eval()
    chosen=subset_indices(len(dataset),limit,seed)
    labels=[];fp=[];iq=[];samples=[]
    diagnostics={'input_elements':0,'input_clipping_count':0,'stages':{}}
    fp_time=iq_time=0.
    with torch.inference_mode():
        for count,index in enumerate(chosen,1):
            path,label=dataset.samples[index];path=Path(path)
            if not path.resolve().is_relative_to((data_dir/'val').resolve()): raise ValueError('Image outside val')
            record=declared[str(path.relative_to(data_dir))];image_hash=sha256(path)
            if record['class']!=classes[label] or record['sha256']!=image_hash:
                raise ValueError('Validation sample label/hash mismatch')
            image,y=dataset[index]
            tick=time.perf_counter();a=int(model(image.unsqueeze(0)).argmax(1).item());fp_time+=time.perf_counter()-tick
            tick=time.perf_counter()
            # Clipping is retained quantitatively in the report, without per-image warning spam.
            with warnings.catch_warnings():
                warnings.filterwarnings('ignore',message='Candidate input quantization clipped.*',category=RuntimeWarning)
                values,trace=candidate_integer_forward(image,prepared,trace=True)
            iq_time+=time.perf_counter()-tick
            b=max(range(len(values)),key=values.__getitem__)
            labels.append(y);fp.append(a);iq.append(b);add_diagnostics(diagnostics,trace)
            samples.append({'index':index,'path':str(path.relative_to(REPO_ROOT)), 'sha256':image_hash,
                            'label':y,'fp32_prediction':a,'int8_prediction':b})
            if count%100==0: print(f'{count}/{len(chosen)} validation images',flush=True)
    for p,h in provenance['input_sha256'].items():
        if sha256(Path(p))!=h: raise ValueError('Source changed during evaluation')
    if sha256(stats_path)!=stats_hash or sha256(split_path)!=split_hash: raise ValueError('Dataset metadata changed')
    if any(sha256(REPO_ROOT/s['path'])!=s['sha256'] for s in samples): raise ValueError('Image changed during evaluation')
    diagnostics['input_clipping_rate']=diagnostics['input_clipping_count']/diagnostics['input_elements']
    diagnostics['interpretation']='Input clipping is measured; -128/+127 counts are boundary proxies, not internal clamp events. True internal clamp counts unavailable.'
    total=time.perf_counter()-started
    return {'schema_version':1,'role':'evaluation only; candidate software INT8, no tuning',
            'checkpoint':provenance['checkpoint'],'qparams':{'path':str(qparams_path),'sha256':sha256(Path(qparams_path))},
            'split':{'name':'val','data_dir':str(data_dir),'manifest_sha256':split_hash,'stats_sha256':stats_hash,
                     'available_samples':len(dataset),'seed':seed,'selection':'seeded shuffle prefix',
                     'selection_sha256':hashlib.sha256(json_bytes(samples)).hexdigest(),
                     'full_validation':len(chosen)==len(dataset)},
            'class_names':classes,'preprocessing':provenance['calibration']['preprocessing'],
            'metrics':metrics(labels,fp,iq,classes),'diagnostics':diagnostics,'samples':samples,
            'runtime':{'total_seconds':total,'fp32_seconds':fp_time,'int8_seconds':iq_time,
                       'int8_seconds_per_image':iq_time/len(chosen),
                       'estimated_full_int8_seconds':iq_time/len(chosen)*len(dataset)},
            'source_sha256':{name:sha256(Path(__file__).with_name(name)) for name in
                ('compare_candidate_validation.py','candidate_integer_forward.py','integer_layer_ref.py','requant_ref.py')}}


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--qparams',type=Path,required=True);p.add_argument('--data-dir',type=Path,required=True)
    p.add_argument('--output-dir',type=Path,required=True);p.add_argument('--limit',type=int,default=100)
    p.add_argument('--full',action='store_true');p.add_argument('--seed',type=int,default=42)
    args=p.parse_args()
    base=REPO_ROOT/'cnn_pipeline/outputs/validation_comparison'
    if args.output_dir.exists() or args.output_dir.resolve()==base or not args.output_dir.resolve().is_relative_to(base):
        raise ValueError('Use a new run directory under outputs/validation_comparison')
    torch.set_num_threads(2);torch.use_deterministic_algorithms(True)
    r=evaluate(args.qparams,args.data_dir,limit=None if args.full else args.limit,seed=args.seed)
    save_report(r,args.output_dir)
    print(json.dumps({'metrics':{k:v for k,v in r['metrics'].items() if k not in ('per_class','fp32_confusion_true_pred','int8_confusion_true_pred','agreement_matrix_fp32_int8')},'runtime':r['runtime']}))


if __name__=='__main__': main()
