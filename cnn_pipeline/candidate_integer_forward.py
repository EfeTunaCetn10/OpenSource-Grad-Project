"""Candidate full INT8 LeNet forward, CHW mathematical semantics; no hardware I/O."""
import math
import warnings

import torch

from quantization import quantize_int8, scaled_values, round_half_up
from multiplier_analysis import LAYERS
from integer_layer_ref import integer_conv2d_layer_ref, integer_linear_layer_ref
from integer_tensor_ops_ref import integer_maxpool2d_ref, integer_flatten_chw_ref


def candidate_integer_forward(image, prepared, *, trace=False):
    """Return ten Python int logits, or (logits, diagnostics) when trace=True.

    image is a normalized CPU float32 tensor [3,32,32]. prepared comes from
    load_candidate_integer_model (real artifacts) or its pure preparation API.
    Input clipping warns even without trace. Intermediate saturation counts are
    unavailable from existing layer APIs; endpoint counts are NOT saturation.
    No model loading, preprocessing, parameter selection or mutation occurs here.
    """
    if type(trace) is not bool:
        raise TypeError('trace must be bool')
    if not isinstance(image, torch.Tensor) or image.dtype != torch.float32 or image.device.type != 'cpu':
        raise TypeError('image must be a normalized CPU float32 tensor')
    if list(image.shape) != [3,32,32] or not torch.isfinite(image).all():
        raise ValueError('image must be finite CHW [3,32,32], without batch dimension')
    layers = prepared['layers']
    if set(layers) != {row[0] for row in LAYERS} or prepared['channel_count'] != 236:
        raise ValueError('Expected prepared five-layer LeNet parameters')
    previous_scale = None
    for i, (name, xkey, ykey, _) in enumerate(LAYERS):
        p = layers[name]
        if p['input_key'] != xkey or p['output_key'] != ykey or type(p['relu']) is not bool or p['relu'] != (i < 4):
            raise ValueError(f'{name}: incompatible topology/ReLU metadata')
        for key in ('s_x','s_y'):
            if type(p[key]) not in (float,int) or not math.isfinite(p[key]) or p[key] <= 0:
                raise ValueError(f'{name}: invalid {key}')
        if previous_scale is not None and p['s_x'] != previous_scale:
            raise ValueError(f'{name}: activation scale transfer mismatch')
        previous_scale = p['s_y']
    sx = layers['features.0']['s_x']
    normalized, _ = scaled_values(image, sx)
    rounded = round_half_up(normalized)
    clipped = int(((rounded < -127) | (rounded > 127)).sum().item())
    if clipped:
        warnings.warn(f'Candidate input quantization clipped {clipped}/{image.numel()} values', RuntimeWarning, stacklevel=2)
    value = quantize_int8(image, sx).tolist()
    records = []

    def record(stage, data, expected, scale_key, scale, relu=False):
        # Only inspect values; PyTorch is not the integer execution engine.
        tensor = torch.tensor(data, dtype=torch.int64)
        if list(tensor.shape) != expected:
            raise ValueError(f'{stage}: expected shape {expected}, got {list(tensor.shape)}')
        if trace:
            records.append({'stage': stage, 'shape': expected, 'min': tensor.min().item(),
                            'max': tensor.max().item(), 'domain': 'signed INT8 / Python int',
                            'scale_name': scale_key, 'scale': scale, 'zero_point': 0,
                            'saturation_count': None,
                            'saturation_status': 'not exposed by existing layer API',
                            'endpoint_count': int(((tensor == (0 if relu else -128)) | (tensor == 127)).sum())})
    record('input',value,[3,32,32],'input',sx)
    shapes = [[6,28,28],[16,10,10],[120],[84],[10]]
    for i, (name, _, ykey, _) in enumerate(LAYERS):
        p = layers[name]
        args = (value,p['weights_list'],p['bias_q'],p['M0'],p['n'])
        if i < 2:
            value = integer_conv2d_layer_ref(*args, relu=p['relu'], layer=name)
        else:
            value = integer_linear_layer_ref(*args, relu=p['relu'])
        record(('conv1','conv2','fc1','fc2','fc3')[i],value,shapes[i],ykey,p['s_y'],p['relu'])
        if i < 2:
            value = integer_maxpool2d_ref(value)
            record(f'pool{i+1}',value,([6,14,14] if i==0 else [16,5,5]),ykey,p['s_y'],True)
        if i == 1:
            value = integer_flatten_chw_ref(value)
            record('flatten',value,[400],ykey,p['s_y'],True)
    if trace:
        return value, {'role':'candidate software forward; not FPGA verification',
                       'input_clipping_count':clipped, 'input_elements':image.numel(),
                       'input_clipping_rate':clipped/image.numel(), 'stages':records}
    return value
