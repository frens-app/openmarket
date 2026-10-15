#!/usr/bin/env python3
"""Analyze the frozen direct Jev benchmark; preserve the earlier Gateway results."""
import collections
import hashlib
import json
import statistics

from analyze import metrics
from direct import DIRECT
from research import OUT


def decisions(row):
    return {f'{row["dataset"]}-{int(k.split("_")[1]):02}':
            v['choice'] != 'mismatch' if v['type'] == 'choice' else v['noul'] >= .8
            for k, v in row['response']['answers'].items()}


def main():
    labels = json.loads((OUT / 'labels.json').read_text())['labels']
    manifest = json.loads((DIRECT / 'manifest.json').read_text())
    assert manifest['labels_sha256'] == hashlib.sha256((OUT / 'labels.json').read_bytes()).hexdigest()
    rows = [json.loads(p.read_text()) for p in DIRECT.glob('result-*.json')]
    assert len(rows) == len(manifest['tasks']) == 63
    assert all(r['status'] == 200 and r['label_sha256'] == manifest['labels_sha256'] for r in rows)
    assert all(r['response']['model'] == r['model_requested'] for r in rows)
    grouped = collections.defaultdict(list)
    for r in rows:
        grouped[r['model_requested'] + '_' + r['arm']].append(r)
    out = {'label_count': len(labels), 'known_labels': sum(l[0] != 'unknown' for l in labels.values()),
           'benchmark_calls': len(rows), 'total_estimated_cost_usd': sum(r['estimated_cost_usd'] for r in rows),
           'methods': {}, 'majority_decisions': {}, 'individual_decisions': {}}
    for method, rs in sorted(grouped.items()):
        assert len(rs) == 9
        votes = collections.defaultdict(list)
        per_repeat = {r: {} for r in range(3)}
        for row in rs:
            dec = decisions(row)
            per_repeat[row['repeat']].update(dec)
            for k, keep in dec.items():
                votes[k].append(keep)
        assert set(votes) == set(labels) and all(len(v) == 3 for v in votes.values())
        majority = {k: sum(v) >= 2 for k, v in votes.items()}
        out['majority_decisions'][method] = majority
        out['individual_decisions'][method] = per_repeat
        times = [r['elapsed_ms'] for r in rs]
        out['methods'][method] = {
            'calls': len(rs), 'median_ms': round(statistics.median(times), 2),
            'min_ms': min(times), 'max_ms': max(times),
            'mean_cost_usd': statistics.mean(r['estimated_cost_usd'] for r in rs),
            'mean_input_tokens': statistics.mean(r['response']['usage']['input_tokens'] for r in rs),
            'mean_request_bytes': statistics.mean(r['request_bytes'] for r in rs),
            'decision_disagreements_across_repeats': [k for k, v in sorted(votes.items()) if len(set(v)) > 1],
            'all_quality': metrics(majority, labels, [0, 1, 2]),
            'desk_quality': metrics(majority, labels, [0, 1]),
            'by_dataset': {i: metrics(majority, labels, [i]) for i in range(3)},
            'per_repeat_quality': {r: metrics(pred, labels, [0, 1, 2]) for r, pred in per_repeat.items()},
            'per_dataset_timing': {i: {'median_ms': statistics.median(r['elapsed_ms'] for r in rs if r['dataset'] == i),
                                     'cost_usd': statistics.mean(r['estimated_cost_usd'] for r in rs if r['dataset'] == i)}
                                   for i in range(3)},
        }
    controls = json.loads((DIRECT / 'controls.json').read_text())
    out['control_calls'] = len(controls)
    out['controls_estimated_cost_usd'] = sum(r['estimated_cost_usd'] for r in controls)
    out['total_estimated_cost_usd'] += out['controls_estimated_cost_usd']
    out['notes'] = [
        'Costs estimated from returned input tokens at $0.042/M; output free; not an invoice.',
        'Endpoint times include HTTPS and upload from this Mac; exclude initial photo downloads.',
        'Same 43 public cards and pre-existing assistant labels; no independent human or held-out validation.',
        'Three repeats per method/dataset measure variability, not 129 independent listings.',
        'Majority quality is descriptive; production would make one call. Per-repeat metrics are also included.',
        'Pinned versions, multipart PNG/JPEG, one candidate photo in each question, no long-context mode.',
    ]
    (DIRECT / 'summary.json').write_text(json.dumps(out, indent=2))
    previous = json.loads((OUT / 'summary.json').read_text())
    combined = {'methods': {**previous['methods'], **out['methods']},
                'majority_decisions': {**previous['majority_decisions'], **out['majority_decisions']}}
    (DIRECT / 'combined-summary.json').write_text(json.dumps(combined, indent=2))
    for method, data in out['methods'].items():
        print(json.dumps({'method': method, **data}))
    print('Estimated total USD:', out['total_estimated_cost_usd'])
    for method in ['jev-1.14.0_descriptor_vision', 'jev-1.14.0_triage_vision']:
        errors = [(k, label, out['majority_decisions'][method][k]) for k, label in labels.items()
                  if label[0] != 'unknown' and (label[0] == 'yes') != out['majority_decisions'][method][k]]
        print(method, 'errors:', json.dumps(errors))


if __name__ == '__main__':
    main()
