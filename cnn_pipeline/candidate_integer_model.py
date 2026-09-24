"""In-memory candidate software parameters for LeNet; no forward or export."""
from copy import deepcopy
from pathlib import Path

import torch

import multiplier_analysis as analysis
from model import LeNet5
from quantization import quantize_int8
from bias_quant_ref import quantize_bias_candidate
from candidate_requant_params import candidate_requant_params


def prepare_candidate_integer_model(qparams, model_state, weights_int8):
    """Pure preparation from supplied mappings, not a provenance verification API.

    Validate fixed RGB/10-class LeNet shapes, FP32 state and candidate INT8
    weights. Return independent tensors/lists; never run inference or write files.
    Real artifacts must enter through load_candidate_integer_model.
    """
    analysis.analyze_qparams(qparams)
    expected_weights = {name + '.weight' for name, *_ in analysis.LAYERS}
    expected_biases = {name + '.bias' for name, *_ in analysis.LAYERS}
    if set(weights_int8) != expected_weights or set(model_state) != expected_weights | expected_biases:
        raise ValueError('Missing/extra weight or bias keys')
    # Meta device builds topology without real parameter storage or random draws.
    with torch.device('meta'):
        model = LeNet5(3, 10)
    topology = dict(model.named_modules())
    if len(analysis.LAYERS) != 5 or sum(s[0] for *_, s in analysis.LAYERS) != 236:
        raise ValueError('Expected five layers and 236 output channels')
    layers = {}
    for name, xkey, ykey, shape in analysis.LAYERS:
        layer = topology[name]
        if list(layer.weight.shape) != shape:
            raise ValueError(f'{name}: model.py/LAYERS topology mismatch')
        w, b, wi = model_state[name+'.weight'], model_state[name+'.bias'], weights_int8[name+'.weight']
        for value, dtype, expected, label in ((w, torch.float32, shape, 'FP32 weight'),
                                             (b, torch.float32, [shape[0]], 'FP32 bias'),
                                             (wi, torch.int8, shape, 'INT8 weight')):
            if not isinstance(value, torch.Tensor) or value.dtype != dtype or list(value.shape) != expected:
                raise ValueError(f'{name}: invalid {label} dtype/shape')
            if value.device.type != 'cpu' or value.layout != torch.strided or not value.is_contiguous():
                raise ValueError(f'{name}: {label} must be native contiguous CPU tensor')
            if not torch.isfinite(value).all():
                raise ValueError(f'{name}: non-finite {label}')
        sx = qparams['activation_qparams'][xkey]['scale']
        sy = qparams['activation_qparams'][ykey]['scale']
        sw = qparams['weight_qparams'][name]['scale']
        if not torch.equal(quantize_int8(w, sw, axis=0), wi):
            raise ValueError(f'{name}: candidate weight values/channel order mismatch')
        bias = quantize_bias_candidate(b, sx, sw)
        params = candidate_requant_params(sx, sy, sw)
        # Observation names point to ReLU for hidden layers, final Linear for logits.
        output_module = topology[ykey]
        if not isinstance(output_module, (torch.nn.ReLU, torch.nn.Linear)):
            raise ValueError(f'{name}: unsupported output observation')
        layers[name] = {'role': 'candidate software parameters', 'input_key': xkey, 'output_key': ykey,
                        'weights': wi.detach().clone(), 'bias_fp32': b.detach().clone(),
                        'bias_q': bias.tolist(), 'M0': params['M0'], 'n': params['n'],
                        's_x': sx, 's_y': sy, 's_w': list(sw),
                        'relu': isinstance(output_module, torch.nn.ReLU),
                        'weights_list': wi.tolist(), 'requant_diagnostic': params}
    return {'role': 'candidate software parameters; not hardware export',
            'channel_count': 236, 'layers': layers}


def load_candidate_integer_model(qparams_path, *, root=analysis.ROOT):
    """Verify existing provenance then safely load only the recorded CPU artifacts."""
    path, root = Path(qparams_path), Path(root)
    q, checked = analysis.verify_qparams(path, root)
    if 'weight_artifact' not in q:
        raise ValueError('Missing recorded weight artifact')
    weight_path = path.parent / q['weight_artifact']['file']
    checkpoint_path = root / q['checkpoint']['path']
    for p, expected in ((weight_path, q['weight_artifact']['sha256']),
                        (checkpoint_path, q['checkpoint']['sha256'])):
        if checked.get(str(p)) != expected or analysis.digest(p) != expected:
            raise ValueError(f'Unverified artifact path/hash: {p}')
    checkpoint = torch.load(checkpoint_path, map_location='cpu', weights_only=True)
    weights = torch.load(weight_path, map_location='cpu', weights_only=True)
    if checkpoint.get('seed') != 42 or checkpoint.get('best_epoch') != 51:
        raise ValueError('Checkpoint seed/epoch mismatch')
    result = prepare_candidate_integer_model(q, checkpoint['model_state'], weights)
    if any(analysis.digest(p) != h for p, h in checked.items()):
        raise ValueError('Source changed during preparation')
    result['provenance'] = {'checkpoint': deepcopy(q['checkpoint']),
                            'calibration': deepcopy(q['calibration']), 'input_sha256': checked}
    return result
