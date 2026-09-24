"""Candidate/diagnostic multiplier analysis; never a hardware parameter export."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path

# Layer, input observation, output observation, native weight shape.
LAYERS = (
    ('features.0', 'input', 'features.1', [6, 3, 5, 5]),
    ('features.3', 'features.1', 'features.4', [16, 6, 5, 5]),
    ('classifier.1', 'features.4', 'classifier.2', [120, 400]),
    ('classifier.3', 'classifier.2', 'classifier.4', [84, 120]),
    ('classifier.5', 'classifier.4', 'classifier.5', [10, 84]),
)
ROOT = Path(__file__).resolve().parents[1]
MIN_M = 65536 / 2**49
MAX_M = 131071 / 2


def positive(value, name='M'):
    if type(value) not in (int, float) or not math.isfinite(value) or value <= 0:
        raise ValueError(f'{name}: expected finite positive scalar')
    return float(value)


def candidate_pair(M, n):
    """Nearest M0, half-up tie candidate; reject rather than clamp overflow."""
    M = positive(M)
    if type(n) is not int or not 1 <= n <= 49:
        raise ValueError('Only temporary n=1..49 region supported; n=0/50..63 unresolved')
    scaled = math.ldexp(M, n)
    if not math.isfinite(scaled):
        raise ValueError('Non-finite scaled multiplier')
    floor = math.floor(scaled)
    M0 = floor + int(scaled - floor >= .5)
    if not 65536 <= M0 < 131072:
        raise ValueError(f'rounded M0={M0} outside [65536,131072); no clamp')
    approx = math.ldexp(float(M0), -n)
    error = abs(approx - M)
    return {'M0': M0, 'n': n, 'M_approx': approx, 'absolute_error': error,
            'relative_error': error / M, 'exact_float64': approx == M}


def analyze_multiplier(M):
    M = positive(M)
    result = {'M': M, 'status': 'unrepresentable', 'candidates': [], 'selected_candidate': None,
              'anomalies': []}
    if not MIN_M <= M <= MAX_M:
        result['anomalies'] = ['outside supported multiplier envelope; no endpoint clamp']
        return result
    for n in range(1, 50):
        scaled = math.ldexp(M, n)
        try:
            pair = candidate_pair(M, n)
        except ValueError:
            if 65536 <= scaled < 131072:
                result['anomalies'].append(f'n={n}: normalized M0 rounds to upper exclusive boundary')
            continue
        result['candidates'].append(pair)
    if result['candidates']:
        result['selected_candidate'] = min(result['candidates'], key=lambda p: (p['absolute_error'], p['n']))
        result['status'] = 'exact_float64' if result['selected_candidate']['exact_float64'] else 'approximate_candidate'
    return result


def analyze_qparams(q):
    """Validate scale schema and analyze, without reading files or mutating input."""
    try:
        from quantization import POLICY
        if q['schema_version'] != 1 or q['policy'] != POLICY:
            raise ValueError('Unsupported schema or candidate policy')
        a, weights = q['activation_qparams'], q['weight_qparams']
        if set(weights) != {v[0] for v in LAYERS} or set(a) != {v for row in LAYERS for v in row[1:3]}:
            raise ValueError('Layer/activation key mismatch')
        activation_shapes = {'input': ['N', 3, 32, 32], 'features.1': ['N', 6, 28, 28],
                             'features.4': ['N', 16, 10, 10], 'classifier.2': ['N', 120],
                             'classifier.4': ['N', 84], 'classifier.5': ['N', 10]}
        for name, item in a.items():
            positive(item['scale'], name)
            if item['axis'] is not None or item['zero_point'] != 0 or item['tensor_shape'] != activation_shapes[name]:
                raise ValueError(f'{name}: activation metadata mismatch')
        layers = {}
        for name, x, y, shape in LAYERS:
            w = weights[name]
            if (w['axis'] != 0 or w['tensor_shape'] != shape or
                    not isinstance(w['scale'], list) or len(w['scale']) != shape[0] or
                    w['zero_point'] != [0] * shape[0]):
                raise ValueError(f'{name}: weight shape/channel/axis mismatch')
            rows = []
            for channel, scale in enumerate(w['scale']):
                M = positive(a[x]['scale']) * positive(scale, name) / positive(a[y]['scale'])
                rows.append({'channel': channel, **analyze_multiplier(M)})
            valid = [r['selected_candidate'] for r in rows if r['selected_candidate'] is not None]
            layers[name] = {'input_key': x, 'output_key': y, 'channels': rows,
                           'M_min': min(r['M'] for r in rows), 'M_max': max(r['M'] for r in rows),
                           'n_min': min((p['n'] for p in valid), default=None),
                           'n_max': max((p['n'] for p in valid), default=None),
                           'unrepresentable': len(rows) - len(valid),
                           'exact_float64': sum(p['exact_float64'] for p in valid),
                           'max_absolute_error': max((p['absolute_error'] for p in valid), default=None),
                           'max_relative_error': max((p['relative_error'] for p in valid), default=None),
                           'anomaly_count': sum(bool(r['anomalies']) for r in rows)}
        return {'role': 'candidate/diagnostic only; not hardware export',
                'policy': 'enumerate n=1..49; nearest M0 with half-up ties; reject invalid M0; '
                          'minimum absolute error, then smaller n; reject outside envelope',
                'channel_count': sum(len(v['channels']) for v in layers.values()), 'layers': layers}
    except (KeyError, TypeError) as exc:
        raise ValueError(f'Missing/malformed qparams: {exc}') from exc


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def verify_qparams(path, root=ROOT):
    """Verify existing provenance by hashes/metadata, without inference/calibration."""
    from quantization import POLICY
    path, root = Path(path), Path(root)
    q = json.loads(path.read_text())
    checked = {str(path): digest(path)}
    try:
        if q['policy'] != POLICY or q['schema_version'] != 1:
            raise ValueError('Candidate policy/schema mismatch')
        inputs = q['input_sha256']
        if not inputs:
            raise ValueError('Missing provenance hashes')
        for filename, expected in inputs.items():
            p = Path(filename)
            if not p.is_absolute():
                p = root / p
            if digest(p) != expected:
                raise ValueError(f'Input hash mismatch: {p}')
            checked[str(p)] = expected
        def recorded(p):
            p = Path(p)
            if str(p) not in checked:
                raise ValueError(f'Missing provenance entry: {p}')
            return json.loads(p.read_text())
        cp = q['checkpoint']
        cp_path = root / cp['path']
        selected = recorded(root / 'cnn_pipeline/docs/accuracy_improvement/selected_model.json')
        if (checked.get(str(cp_path)) != cp['sha256'] or cp['sha256'] != selected['checkpoint_sha256']
                or cp['seed'] != 42 or cp['epoch'] != 51):
            raise ValueError('Checkpoint identity mismatch')
        cal = q['calibration']
        mp = root / cal['selection_manifest_path']
        manifest = recorded(mp)
        if checked[str(mp)] != cal['selection_manifest_sha256'] or manifest['checkpoint']['sha256'] != cp['sha256']:
            raise ValueError('Calibration identity mismatch')
        summary = recorded(mp.with_name('summary.json'))
        if summary['selection_manifest_sha256'] != checked[str(mp)]:
            raise ValueError('Calibration summary mismatch')
        for key in ('selection', 'split', 'preprocessing'):
            if cal[key] != manifest[key]:
                raise ValueError(f'Calibration {key} mismatch')
        if (cal['selection']['count'] != 1000 or cal['selection']['samples_per_class'] != 100
                or cal['selection']['seed'] != 42 or cal['split']['name'] != 'train'
                or cal['preprocessing']['random_augmentation'] is not False
                or len(manifest['samples']) != 1000 or len(q['class_names']) != 10
                or q['class_names'] != manifest['class_names']):
            raise ValueError('Calibration selection/class mismatch')
        stats_paths = [Path(p) for p in checked if Path(p).name == 'statistics.json']
        if len(stats_paths) != 1:
            raise ValueError('Missing/ambiguous statistics identity')
        stats = recorded(stats_paths[0])
        if stats['checkpoint'] != cp or stats['calibration'] != cal or stats['class_names'] != q['class_names']:
            raise ValueError('Statistics identity mismatch')
        # Verify scales are the actual absmax/127 candidates from recorded statistics.
        for section, source in [('activation_qparams', 'activations'), ('weight_qparams', 'weights')]:
            for name, item in q[section].items():
                extrema = stats[source][name]['absmax']
                expected = [v / 127 for v in extrema] if isinstance(extrema, list) else extrema / 127
                if item['scale'] != expected:
                    raise ValueError(f'{name}: scale/statistics mismatch')
        if 'weight_artifact' in q:
            artifact = path.parent / q['weight_artifact']['file']
            if digest(artifact) != q['weight_artifact']['sha256']:
                raise ValueError('Weight artifact hash mismatch')
            checked[str(artifact)] = digest(artifact)
        analyze_qparams(q)
    except (KeyError, TypeError) as exc:
        raise ValueError(f'Missing/malformed qparams identity: {exc}') from exc
    return q, checked


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--qparams', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    args = parser.parse_args()
    base = ROOT / 'cnn_pipeline/outputs/multiplier_analysis'
    if args.output_dir.exists() or not args.output_dir.resolve().is_relative_to(base) or args.output_dir.resolve() == base:
        raise ValueError('Use a new run directory under outputs/multiplier_analysis')
    q, checked = verify_qparams(args.qparams)
    report = analyze_qparams(q)
    report.update({'checkpoint': q['checkpoint'], 'calibration': q['calibration'],
                   'input_sha256': checked, 'source_sha256': digest(__file__)})
    if any(digest(p) != h for p, h in checked.items()):
        raise ValueError('Input changed during analysis')
    args.output_dir.mkdir(parents=True, exist_ok=False)
    (args.output_dir / 'diagnostic.json').write_text(json.dumps(report, indent=2, allow_nan=False) + '\n')
    for name, layer in report['layers'].items():
        print(name, {k: v for k, v in layer.items() if k != 'channels'})


if __name__ == '__main__':
    main()
