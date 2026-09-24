import copy
import json
import math

import pytest

from multiplier_analysis import (LAYERS, MIN_M, MAX_M, analyze_multiplier,
                                 analyze_qparams, candidate_pair, digest, verify_qparams)
from quantization import POLICY


@pytest.mark.parametrize('M,M0,n', [(.5, 65536, 17), (.25, 65536, 18),
                                   (MIN_M, 65536, 49), (MAX_M, 131071, 1)])
def test_exact(M, M0, n):
    p = analyze_multiplier(M)['selected_candidate']
    assert (p['M0'], p['n'], p['absolute_error'], p['relative_error']) == (M0, n, 0., 0.)


@pytest.mark.parametrize('n', [0, *range(50, 64), -1, 64, True, 1.5])
def test_shift_rejected(n):
    with pytest.raises(ValueError, match='1..49'):
        candidate_pair(.5, n)


@pytest.mark.parametrize('M', [0, -1, math.nan, math.inf, -math.inf, True, [.5]])
def test_invalid_multiplier(M):
    with pytest.raises(ValueError):
        analyze_multiplier(M)


@pytest.mark.parametrize('M', [MIN_M / 2, MAX_M * 2, math.nextafter(MIN_M, 0),
                              math.nextafter(MAX_M, math.inf)])
def test_outside_not_clamped(M):
    r = analyze_multiplier(M)
    assert r['status'] == 'unrepresentable' and r['selected_candidate'] is None


def test_upper_rounding_boundary():
    M = 131071.5 / 2**18
    with pytest.raises(ValueError, match='no clamp'):
        candidate_pair(M, 18)
    r = analyze_multiplier(M)
    assert r['anomalies']
    assert (r['selected_candidate']['M0'], r['selected_candidate']['n']) == (65536, 17)
    assert r['selected_candidate']['absolute_error'] == 2**-19


def test_nearest_half_up_candidate():
    p = candidate_pair(65536.5 / 2**18, 18)
    assert p['M0'] == 65537 and p['absolute_error'] == 2**-19
    assert p['relative_error'] == pytest.approx(.5 / 65536.5)


@pytest.fixture
def qparams():
    shapes = {'input': ['N', 3, 32, 32], 'features.1': ['N', 6, 28, 28],
              'features.4': ['N', 16, 10, 10], 'classifier.2': ['N', 120],
              'classifier.4': ['N', 84], 'classifier.5': ['N', 10]}
    return {'schema_version': 1, 'policy': copy.deepcopy(POLICY),
            'activation_qparams': {k: {'scale': float(2**i), 'axis': None,
                                      'zero_point': 0, 'tensor_shape': v}
                                   for i, (k, v) in enumerate(shapes.items())},
            'weight_qparams': {name: {'scale': [1.] * shape[0], 'zero_point': [0] * shape[0],
                                     'axis': 0, 'tensor_shape': shape}
                               for name, _, _, shape in LAYERS}}


def test_mapping_repeatability_and_unchanged(qparams):
    original = copy.deepcopy(qparams)
    report = analyze_qparams(qparams)
    assert report == analyze_qparams(qparams) and qparams == original
    assert report['channel_count'] == 236
    expected = [('input', 'features.1'), ('features.1', 'features.4'),
                ('features.4', 'classifier.2'), ('classifier.2', 'classifier.4'),
                ('classifier.4', 'classifier.5')]
    for layer, keys in zip(report['layers'].values(), expected):
        assert (layer['input_key'], layer['output_key']) == keys
        assert layer['M_min'] == layer['M_max'] == .5
        assert layer['unrepresentable'] == 0


@pytest.mark.parametrize('mutation', [
    lambda q: q.pop('policy'),
    lambda q: q['policy'].update(qmin=-128),
    lambda q: q['weight_qparams'].pop('features.0'),
    lambda q: q['activation_qparams']['input'].update(scale=[1.]),
    lambda q: q['activation_qparams']['input'].update(scale=math.nan),
    lambda q: q['weight_qparams']['features.0'].update(scale=[1.]),
    lambda q: q['weight_qparams']['features.0'].update(axis=1),
    lambda q: q['weight_qparams']['features.0'].update(tensor_shape=[6, 1, 5, 5]),
    lambda q: q['weight_qparams']['features.0'].update(scale=[0.] * 6),
])
def test_schema_rejects(qparams, mutation):
    mutation(qparams)
    with pytest.raises(ValueError):
        analyze_qparams(qparams)


@pytest.fixture
def provenance(tmp_path, qparams):
    root = tmp_path
    def write(rel, obj):
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(obj))
        return p
    cp = write('checkpoint.pt', {'synthetic': True})
    checkpoint = {'path': 'checkpoint.pt', 'sha256': digest(cp), 'seed': 42, 'epoch': 51}
    classes = [str(i) for i in range(10)]
    selection = {'count': 1000, 'samples_per_class': 100, 'seed': 42}
    manifest = {'checkpoint': checkpoint, 'class_names': classes, 'selection': selection,
                'split': {'name': 'train'}, 'preprocessing': {'random_augmentation': False},
                'samples': [{} for _ in range(1000)]}
    mp = write('cal/selection_manifest.json', manifest)
    cal = {k: manifest[k] for k in ('selection', 'split', 'preprocessing')}
    cal.update(selection_manifest_path='cal/selection_manifest.json', selection_manifest_sha256=digest(mp))
    summary = write('cal/summary.json', {'selection_manifest_sha256': digest(mp)})
    selected = write('cnn_pipeline/docs/accuracy_improvement/selected_model.json', {'checkpoint_sha256': digest(cp)})
    stats = {'checkpoint': checkpoint, 'calibration': cal, 'class_names': classes,
             'activations': {k: {'absmax': v['scale'] * 127} for k, v in qparams['activation_qparams'].items()},
             'weights': {k: {'absmax': [127.] * len(v['scale'])} for k, v in qparams['weight_qparams'].items()}}
    sp = write('statistics.json', stats)
    artifact = write('weights.pt', {'synthetic': True})
    qparams.update(checkpoint=checkpoint, calibration=cal, class_names=classes,
                   input_sha256={str(p): digest(p) for p in (cp, mp, summary, selected, sp)},
                   weight_artifact={'file': 'weights.pt', 'sha256': digest(artifact)})
    return write('qparams.json', qparams), root


def test_identity_and_files_unchanged(provenance):
    path, root = provenance
    before = {str(p): digest(p) for p in root.rglob('*') if p.is_file()}
    q, checked = verify_qparams(path, root)
    assert analyze_qparams(q)['channel_count'] == 236
    assert all(digest(p) == h for p, h in before.items())
    assert checked[str(path)] == digest(path)


@pytest.mark.parametrize('field', ['checkpoint', 'calibration', 'weight_artifact', 'input_sha256'])
def test_identity_mismatch(provenance, field):
    path, root = provenance
    q = json.loads(path.read_text())
    if field == 'input_sha256':
        q[field] = {}
    elif field == 'calibration':
        q[field]['selection_manifest_sha256'] = 'wrong'
    else:
        q[field]['sha256'] = 'wrong'
    path.write_text(json.dumps(q))
    with pytest.raises(ValueError):
        verify_qparams(path, root)


def test_missing_file(tmp_path):
    with pytest.raises(FileNotFoundError):
        verify_qparams(tmp_path / 'missing.json', tmp_path)
