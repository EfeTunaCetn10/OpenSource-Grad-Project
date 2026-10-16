"""Export isolated v3 Conv1 simulation vectors from existing, verified PTQ files.

No calibration, parameter selection, full forward, or promotion is performed.
The first saved validation sample is replayed solely as a debug fixture.
"""
import argparse
import json
from pathlib import Path

import torch
from torchvision.datasets.folder import pil_loader

from calibration import REPO_ROOT, json_bytes, load_checkpoint, sha256
from data import build_insect_eval_transform
from experimental_v3_ptq import integer_mac, requant_tensor, wrap32_tensor
from model_v3 import CompactCNNV3
from quantization import POLICY, quantize_int8


def verified_inputs(ptq):
    """Verify manifest, source, checkpoint, calibration and sample identities."""
    ptq = Path(ptq).resolve()
    manifest = json.loads((ptq / 'artifact_manifest.json').read_text())
    required = {'qparams.json', 'statistics.json', 'weights_int8.pt',
                'validation_metrics.json', 'calibration_selection_manifest.json'}
    if set(manifest['files']) != required or manifest['model_version'] != 'v3':
        raise ValueError('Unexpected v3 artifact manifest')
    identities = {str(ptq / 'artifact_manifest.json'): sha256(ptq / 'artifact_manifest.json')}
    for name, expected in manifest['files'].items():
        path = ptq / name
        if sha256(path) != expected:
            raise ValueError(f'Artifact hash mismatch: {path}')
        identities[str(path)] = expected
    q = json.loads((ptq / 'qparams.json').read_text())
    if q['model_version'] != 'v3' or q['policy'] != POLICY:
        raise ValueError('Unexpected candidate policy/model')
    for name, expected in q['source_sha256'].items():
        path = Path(__file__).with_name(name)
        if sha256(path) != expected:
            raise ValueError(f'PTQ source changed: {name}')
        identities[str(path.resolve())] = expected
    for name, expected in q['input_sha256'].items():
        path = Path(name)
        if sha256(path) != expected:
            raise ValueError(f'PTQ provenance mismatch: {name}')
        identities[str(path.resolve())] = expected
    checkpoint, digest = load_checkpoint(REPO_ROOT / q['checkpoint']['path'])
    if (digest != q['checkpoint']['sha256'] or digest != manifest['checkpoint_sha256']
            or checkpoint['model_name'] != 'CompactCNNV3' or checkpoint['best_epoch'] != 52
            or checkpoint['seed'] != 42 or checkpoint['training_config']['model_version'] != 'v3'):
        raise ValueError('Checkpoint identity mismatch')
    model = CompactCNNV3(len(checkpoint['class_names']))
    model.load_state_dict(checkpoint['model_state'], strict=True)
    calibration = json.loads((ptq / 'calibration_selection_manifest.json').read_text())
    if sha256(REPO_ROOT / q['calibration']['source_manifest']) != q['calibration']['sha256']:
        raise ValueError('Calibration source hash mismatch')
    if calibration != json.loads((REPO_ROOT / q['calibration']['source_manifest']).read_text()):
        raise ValueError('Calibration copy mismatch')
    if (calibration['class_names'] != checkpoint['class_names']
            or q['calibration']['preprocessing']['mean'] != checkpoint['mean']
            or q['calibration']['preprocessing']['std'] != checkpoint['std']):
        raise ValueError('Preprocessing identity mismatch')
    report = json.loads((ptq / 'validation_metrics.json').read_text())
    if report['checkpoint_sha256'] != digest or report['split'] != 'val':
        raise ValueError('Validation identity mismatch')
    p = q['layers'][0]
    if (p['name'] != 'features.0' or p['shape'] != [16, 3, 3, 3]
            or p['input_key'] != 'input' or p['output_key'] != 'features.1'
            or p['relu'] is not True or p['kind'] != 'conv'
            or p['s_x'] != q['activation_scales']['input']
            or p['s_y'] != q['activation_scales']['features.1']):
        raise ValueError('Conv1 metadata mismatch')
    weights = torch.load(ptq / 'weights_int8.pt', map_location='cpu', weights_only=True)[p['name'] + '.weight']
    if weights.dtype != torch.int8 or list(weights.shape) != p['shape']:
        raise ValueError('Conv1 weights mismatch')
    for key in ('bias_q', 'M0', 'n', 's_w'):
        if len(p[key]) != 16:
            raise ValueError(f'Conv1 channel count mismatch: {key}')
    sample = report['samples'][0]
    image_path = (REPO_ROOT / sample['path']).resolve()
    data_dir = (REPO_ROOT / calibration['split']['data_dir']).resolve()
    split = json.loads((data_dir / 'split_manifest.json').read_text())
    declared = [s for s in split['samples'] if s['destination'] == str(image_path.relative_to(data_dir))]
    if (not image_path.is_relative_to(data_dir / 'val') or len(declared) != 1
            or declared[0]['split'] != 'val' or declared[0]['sha256'] != sample['sha256']
            or declared[0]['class'] != checkpoint['class_names'][sample['label']]
            or sha256(image_path) != sample['sha256']):
        raise ValueError('Debug sample identity mismatch')
    identities[str(image_path)] = sample['sha256']
    image = build_insect_eval_transform(checkpoint['mean'], checkpoint['std'])(pil_loader(image_path))
    return q, p, weights, image, sample, identities


def packed_bytes(values):
    values = list(values)
    if len(values) % 8 or any(type(v) is not int or not -128 <= v <= 127 for v in values):
        raise ValueError('Expected whole beats of signed bytes')
    return [sum((v & 255) << (8 * i) for i, v in enumerate(values[j:j+8]))
            for j in range(0, len(values), 8)]


def export(ptq, output):
    output = Path(output).resolve()
    if output.exists():
        raise FileExistsError(f'Refusing to overwrite {output}')
    q, p, weights, image, sample, identities = verified_inputs(ptq)
    with torch.inference_mode():
        x = quantize_int8(image.unsqueeze(0), p['s_x'])
        mac = integer_mac(x, weights)
        biased = wrap32_tensor(mac + torch.tensor(p['bias_q']).reshape(1, 16, 1, 1))
        y, _ = requant_tensor(mac, p['bias_q'], p['M0'], p['n'], relu=True)
    output.mkdir(parents=True, exist_ok=False)
    def write(name, values, bits):
        mask = (1 << bits) - 1
        (output / name).write_text(''.join(f'{int(v) & mask:0{(bits+3)//4}X}\n' for v in values), encoding='ascii')
    write('frame.mem', packed_bytes(x[0].permute(1, 2, 0).flatten().tolist()), 64)
    write('input_chw.mem', x.flatten().tolist(), 8)
    write('weights_oihw.mem', weights.flatten().tolist(), 8)
    for lane in range(8):
        write(f'wbank{lane}.mem', torch.cat([weights[lane].flatten(), weights[8+lane].flatten()]).tolist(), 8)
    for key, bits in [('bias_q',32), ('M0',18), ('n',6)]:
        write(f'{key}.mem', p[key], bits)
    for tile in range(2):
        for name, tensor in [('acc',mac), ('biased',biased), ('y',y)]:
            values = tensor[0,tile*8:(tile+1)*8].permute(1,2,0).flatten().tolist()
            write(f't{tile}_{name}.mem', packed_bytes(values) if name == 'y' else values, 64 if name == 'y' else 32)
    payload = {'role':'isolated candidate v3 Conv1 RTL POC; not promotion',
               'checkpoint':q['checkpoint'], 'source_identity_sha256':identities,
               'exporter_sha256':sha256(Path(__file__)), 'sample':sample, 'split':'val (debug only)',
               'layer':p, 'input_shape':[3,32,32], 'output_shape':[16,32,32],
               'kernel':[3,3], 'padding':1, 'stride':1, 'K':27,
               'logical_outputs':16384, 'output_beats':2048,
               'input_transport':'dense HWC, lane0 low byte; mathematical oracle NCHW',
               'output_transport':'tile, h, w, lane; tile0 channels0..7, tile1 channels8..15',
               'weight_transport':'bank=co%8; address=(co//8)*27+ci*9+kh*3+kw',
               'arithmetic':q['arithmetic'], 'orchestration':'testbench input replay, two channel passes',
               'files':{f.name:sha256(f) for f in output.iterdir()}}
    if any(sha256(Path(path)) != digest for path,digest in identities.items()):
        raise ValueError('Source changed during export')
    (output / 'manifest.json').write_bytes(json_bytes(payload))
    print(f'Exported {output}: 16384 logical values / 2048 beats, checkpoint {q["checkpoint"]["sha256"]}')
    return payload


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--ptq-dir',type=Path,required=True)
    ap.add_argument('--output-dir',type=Path,required=True)
    args = ap.parse_args()
    torch.set_num_threads(2)
    export(args.ptq_dir,args.output_dir)
