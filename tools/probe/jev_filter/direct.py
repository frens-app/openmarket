#!/usr/bin/env python3
"""Opt-in paid TypeSafe research on frozen public listing cards.

Uses only JEV_API_KEY from the backend's .env.local, only at api.typesafe.ai.
No application configuration changes; no keys saved or printed. Maximum planned
benchmark cost is below $1 at the documented 64k/request context and input rate.
"""
import argparse
import base64
import hashlib
import io
import json
import random
import time
import urllib.error
import urllib.request
import uuid

from PIL import Image
from benchmark import POLICY, jev_payload
from research import ROOT, OUT

DIRECT = OUT / 'direct-jev'
DIRECT.mkdir(exist_ok=True)
RATE = 0.042 / 1_000_000
URL = 'https://api.typesafe.ai/v1/systemone'
TRIAGE = {
    'match': 'Available evidence supports the requested product and descriptors.',
    'unknown': 'Plausible product, but one or more requested attributes cannot be determined.',
    'mismatch': 'Available evidence clearly contradicts the product type or a requested descriptor.',
}


def direct_key():
    for line in (ROOT / 'apps/backend/.env.local').read_text().splitlines():
        k, sep, v = line.partition('=')
        if sep and k.strip() == 'JEV_API_KEY':
            value = v.strip().strip('\"\'')
            if value:
                return value
    raise RuntimeError('JEV_API_KEY is not configured')


def encode(body, files):
    if not files:
        return json.dumps(body).encode(), 'application/json'
    boundary = 'jev-research-' + uuid.uuid4().hex
    parts = [('request', 'request.json', 'application/json', json.dumps(body).encode())]
    parts += [(name, name + ('.png' if mime == 'image/png' else '.jpg'), mime, raw)
              for name, mime, raw in files]
    chunks = []
    for name, filename, mime, raw in parts:
        chunks.append((f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"; '
                       f'filename="{filename}"\r\nContent-Type: {mime}\r\n\r\n').encode())
        chunks += [raw, b'\r\n']
    chunks.append(f'--{boundary}--\r\n'.encode())
    return b''.join(chunks), 'multipart/form-data; boundary=' + boundary


def call(body, files=(), image_header=False):
    data, content_type = encode(body, files)
    credential = direct_key()
    headers = {'Authorization': 'Bearer ' + credential, 'Content-Type': content_type}
    if image_header:
        headers['TypeSafe-Danger-Zone-Images'] = 'true'
    req = urllib.request.Request(URL, data=data, headers=headers)
    started = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=50) as response:
            raw, status = response.read(5_000_000), response.status
    except urllib.error.HTTPError as error:
        raw, status = error.read(100_000), error.code
    elapsed = round((time.perf_counter() - started) * 1000, 2)
    text = raw.decode(errors='replace').replace(credential, '[REDACTED]')
    try:
        result = json.loads(text)
    except ValueError:
        result = {'unparsed_response': text[:2000]}
    tokens = result.get('usage', {}).get('input_tokens')
    return {'status': status, 'elapsed_ms': elapsed, 'request_bytes': len(data),
            'estimated_cost_usd': tokens * RATE if tokens is not None else None,
            'response': result}


def png(color):
    buf = io.BytesIO()
    Image.new('RGB', (560, 560), color).save(buf, 'PNG')
    return buf.getvalue()


def controls():
    dst = DIRECT / 'controls.json'
    if dst.exists():
        raise RuntimeError('Controls already exist; preserve them before a new run')
    questions = {'color': {'type': 'choice',
        'instructions': 'What color is the rectangle in the provided photo? If no photo is available, choose unknown.',
        'criteria': {'red': 'Red', 'blue': 'Blue', 'green': 'Green', 'unknown': 'Cannot determine'}}}
    results = []
    for color in [None, 'red', 'blue', 'green']:
        body = {'model': 'jev-1.14.0', 'state': 'Inspect the provided photo.', 'questions': questions}
        files = []
        if color:
            ref = str(uuid.uuid4())
            body['state'] = {'photo': ref}
            body['assets'] = {ref: {'type': 'image', 'part': 'photo'}}
            files = [('photo', 'image/png', png(color))]
        result = {'expected': color or 'unknown', **call(body, files, bool(color))}
        results.append(result)
        dst.write_text(json.dumps(results, indent=2))
        print(json.dumps(result), flush=True)
        assert result['status'] == 200
        assert result['response']['answers']['color']['choice'] == (color or 'unknown'), 'Image control failed'
    # Verify question-local assets, used for independent per-listing decisions.
    body = {'model': 'jev-1.14.0', 'state': 'Each question has its own photo.', 'assets': {}, 'questions': {}}
    files = []
    for index, color in enumerate(['red', 'blue']):
        ref = str(uuid.uuid4()); name = f'photo-{index}'
        body['assets'][ref] = {'type': 'image', 'part': name}
        body['questions'][name] = {**questions['color'], 'instructions': 'What color is this rectangle? ' + ref}
        files.append((name, 'image/png', png(color)))
    result = {'expected': {'photo-0': 'red', 'photo-1': 'blue'}, **call(body, files, True)}
    results.append(result); dst.write_text(json.dumps(results, indent=2)); print(json.dumps(result), flush=True)
    assert result['status'] == 200
    assert {k: v['choice'] for k, v in result['response']['answers'].items()} == result['expected']


def payload(ds, model, arm):
    with_images = arm.endswith('_vision')
    if arm.startswith('triage'):
        questions = {f'candidate_{j}': {'type': 'choice', 'instructions': POLICY +
                     ' Classify this candidate against the query in shared state. Candidate: ' +
                     json.dumps({'title': c['title']}), 'criteria': TRIAGE}
                     for j, c in enumerate(ds['cards'])}
        body = {'model': model, 'state': {'query': ds['query']}, 'questions': questions}
    else:
        body = jev_payload(ds, 'current_text' if arm == 'current_text' else 'descriptor_text')
        body['model'] = model
        for question in body['questions'].values():
            question['type'] = 'noul'
    files = []
    if with_images:
        body['assets'] = {}
        for j, c in enumerate(ds['cards']):
            ref = str(uuid.uuid4()); name = f'photo-{j}'
            raw = (OUT / c['image']['path']).read_bytes()
            with Image.open(io.BytesIO(raw)) as im:
                w, h = im.size
                assert im.format == 'JPEG' and 256 <= min(w, h) and max(w, h) <= 1568
                assert 78400 <= w * h <= 2458624
            body['assets'][ref] = {'type': 'image', 'part': name}
            body['questions'][f'candidate_{j}']['instructions'] += ' Headline photo: ' + ref
            files.append((name, 'image/jpeg', raw))
    return body, files


def validate(result, count):
    assert result['status'] == 200, 'API failure; stopped without retry'
    answers = result['response']['answers']
    assert set(answers) == {f'candidate_{j}' for j in range(count)}
    for answer in answers.values():
        if answer['type'] == 'noul':
            assert isinstance(answer['noul'], (float, int)) and 0 <= answer['noul'] <= 1
        else:
            assert answer['type'] == 'choice' and answer['choice'] in TRIAGE
    assert result['estimated_cost_usd'] is not None, 'Missing usage; stop billing blind'


def benchmark():
    assert (DIRECT / 'controls.json').exists(), 'Run and pass image controls first'
    controls_data = json.loads((DIRECT / 'controls.json').read_text())
    assert len(controls_data) == 5 and all(r['status'] == 200 for r in controls_data)
    datasets = [json.loads((OUT / f'dataset-{i}.json').read_text()) for i in range(3)]
    label_hash = hashlib.sha256((OUT / 'labels.json').read_bytes()).hexdigest()
    tasks = [(model, arm, i, repeat)
             for model, arms in [('jev-1.14.0', ['current_text', 'descriptor_text', 'descriptor_vision', 'triage_text', 'triage_vision']),
                                 ('jev-1.13.0', ['descriptor_text', 'descriptor_vision'])]
             for arm in arms for i in range(3) for repeat in range(3)]
    random.Random(1413).shuffle(tasks)
    # No long-context mode. Entire fixed suite remains below $1 even at 64k/call.
    assert len(tasks) * 65536 * RATE < 1
    manifest = {'labels_sha256': label_hash, 'policy': POLICY, 'triage_criteria': TRIAGE,
                'noul_threshold': .8, 'seed': 1413, 'input_usd_per_million': .042,
                'tasks': tasks, 'endpoint': URL, 'image_transport': 'multipart, one image in its candidate question',
                'source_sha256': hashlib.sha256(__import__('pathlib').Path(__file__).read_bytes()).hexdigest(),
                'data_sha256': {f'dataset-{i}.json': hashlib.sha256((OUT / f'dataset-{i}.json').read_bytes()).hexdigest() for i in range(3)},
                'image_sha256': {c['image']['path']: hashlib.sha256((OUT / c['image']['path']).read_bytes()).hexdigest() for ds in datasets for c in ds['cards']}}
    manifest_path = DIRECT / 'manifest.json'
    if manifest_path.exists():
        assert json.loads(manifest_path.read_text()) == json.loads(json.dumps(manifest)), 'Frozen inputs or script changed'
    else:
        manifest_path.write_text(json.dumps(manifest, indent=2))
    for n, (model, arm, i, repeat) in enumerate(tasks):
        dst = DIRECT / f'result-{model}-{arm}-{i}-{repeat}.json'
        if dst.exists():
            validate(json.loads(dst.read_text()), len(datasets[i]['cards']))
            continue
        body, files = payload(datasets[i], model, arm)
        result = {'model_requested': model, 'arm': arm, 'dataset': i, 'repeat': repeat,
                  'label_sha256': label_hash, **call(body, files, bool(files))}
        dst.write_text(json.dumps(result, indent=2))
        print(json.dumps({k: v for k, v in result.items() if k != 'response'} | {
            'model_returned': result['response'].get('model'), 'usage': result['response'].get('usage'),
            'task': n + 1, 'of': len(tasks)}), flush=True)
        validate(result, len(datasets[i]['cards']))
        time.sleep(.2)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['controls', 'benchmark'])
    args = parser.parse_args()
    {'controls': controls, 'benchmark': benchmark}[args.action]()
