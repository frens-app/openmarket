#!/usr/bin/env python3
"""Bounded, cookie-free Discover count comparison. Saves aggregates only."""
import argparse
import collections
import copy
import datetime
import json
import pathlib
import time
import urllib.parse
import urllib.request

BASE = pathlib.Path(__file__).resolve().parents[1] / 'anonymous_graphql'


def decode(raw):
    text = raw.decode('utf-8').removeprefix('for (;;);').strip()
    try:
        records = [json.loads(text)]
    except json.JSONDecodeError:
        records = [json.loads(line) for line in text.splitlines() if line.strip()]
    edges, info, saw_connection = {}, None, False
    for record in records:
        if record.get('error') or record.get('errors'):
            raise RuntimeError('GraphQL returned an error; stopping without retry')
        body, path = record.get('data'), record.get('path')
        if not isinstance(body, dict):
            raise RuntimeError('Missing response data')
        if path is None:
            connection = body.get('marketplace_home_feed')
            if not isinstance(connection, dict) or not isinstance(connection.get('edges'), list):
                raise RuntimeError('Missing Discover connection')
            saw_connection = True
            edges.update(enumerate(connection['edges']))
            if isinstance(connection.get('page_info'), dict):
                info = connection['page_info']
        elif len(path) == 3 and path[:2] == ['marketplace_home_feed', 'edges'] and isinstance(path[2], int):
            edges[path[2]] = body
        elif path == ['marketplace_home_feed'] and isinstance(body.get('page_info'), dict):
            info = body['page_info']
        elif len(path) > 4 and path[:2] == ['marketplace_home_feed', 'edges'] and path[3:5] == ['node', 'story'] and edges.get(path[2], {}).get('node', {}).get('__typename') == 'MarketplaceFeedAdStory':
            continue
        else:
            raise RuntimeError('Unrecognized streamed patch; inspect before measuring')
    if not saw_connection or not isinstance(info, dict) or not isinstance(info.get('has_next_page'), bool):
        raise RuntimeError('Missing verified page_info')
    cards, types, occurrences = {}, collections.Counter(), 0
    for edge in edges.values():
        node = edge['node']
        types[node.get('__typename', 'unknown')] += 1
        if isinstance(node.get('marketplace_listings'), list):
            candidates = node['marketplace_listings']
        elif node.get('__typename') == 'MarketplaceFeedGeneralListingObject':
            listing = node.get('listing') or {}
            candidates = [{'id': listing.get('id'), 'location': (node.get('entity') or {}).get('location')}]
        else:
            candidates = []
        for listing in candidates:
            if not listing.get('id'):
                raise RuntimeError('Listing missing canonical ID')
            occurrences += 1
            cards[listing['id']] = listing
    return cards, info, dict(types), occurrences, len(records), len(edges)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--mode', choices=('comparison', 'cap'), default='comparison')
    parser.add_argument('--radius', type=int, choices=(8000, 65000), default=8000)
    args = parser.parse_args()
    config = json.loads((BASE / 'browse.json').read_text())
    result = {'observed_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'session': 'anonymous', 'operation': config['operation'], 'document_id': config['doc_id'],
              'radius': args.radius, 'use_sdf_path': True, 'mode': args.mode,
              'pages_per_variant': 3 if args.mode == 'comparison' else 1, 'results': []}
    variants = [('baseline', 1), ('count_2', 2), ('count_4', 4), ('count_8', 8), ('repeat', 1)]
    if args.mode == 'cap':
        variants = [('seed', 1), ('count_5', 5), ('count_8', 8), ('count_16', 16)]
    seed_cursor, seed_ids, matched_ids = None, set(), None
    for label, count in variants:
        variables = copy.deepcopy(config['variables'])
        variables.update(count=count, radius=args.radius)
        if args.mode == 'cap' and label != 'seed':
            if not seed_cursor: raise RuntimeError('Seed page did not provide a cursor')
            variables['cursor'] = seed_cursor
        seen, cursors = (set(seed_ids) if args.mode == 'cap' else set()), set()
        for index in range(3 if args.mode == 'comparison' else 1):
            fields = {'__user': '0', 'av': '0', '__a': '1', '__comet_req': '15',
                      'fb_api_caller_class': 'RelayModern', 'fb_api_req_friendly_name': config['operation'],
                      'server_timestamps': 'true', 'doc_id': config['doc_id'], 'variables': json.dumps(variables)}
            request = urllib.request.Request('https://www.facebook.com/api/graphql/',
                data=urllib.parse.urlencode(fields).encode(), headers={
                    'User-Agent': 'OpenMarket/0.0.1 (iOS)', 'Content-Type': 'application/x-www-form-urlencoded'})
            started = time.monotonic()
            with urllib.request.urlopen(request, timeout=15) as response:
                raw, status = response.read(5_000_001), response.status
            network_ms = round((time.monotonic() - started) * 1000)
            if len(raw) > 5_000_000:
                raise RuntimeError('Response exceeds production size limit')
            cards, info, types, occurrences, records, edges = decode(raw)
            ids = set(cards)
            cities = collections.Counter(((card.get('location') or {}).get('reverse_geocode') or {}).get('city') or 'unknown' for card in cards.values())
            cursor = info.get('end_cursor')
            changed = bool(cursor) and cursor != variables['cursor'] and cursor not in cursors
            row = {'variant': label, 'count': count, 'page': index + 1, 'status': status,
                   'network_ms': network_ms, 'bytes': len(raw), 'records': records, 'edges': edges,
                   'edge_types': types, 'listing_occurrences': occurrences, 'unique_listings': len(ids),
                   'duplicates_within_page': occurrences - len(ids), 'new_listings': len(ids - seen),
                   'duplicates_from_prior_pages': len(ids & seen), 'cities': dict(cities),
                   'known_delivery': sum(bool(c.get('delivery_types')) for c in cards.values()),
                   'has_next_page': info['has_next_page'], 'cursor_changed': changed}
            if args.mode == 'cap':
                row['page'] = 1 if label == 'seed' else 2
                row['shared_start_cursor'] = label != 'seed'
                if label == 'seed':
                    seed_cursor, seed_ids = cursor, ids
                else:
                    row['overlap_with_count_5'] = len(ids & matched_ids) if matched_ids is not None else None
                    if label == 'count_5': matched_ids = ids
            result['results'].append(row)
            args.output.write_text(json.dumps(result, indent=2) + '\n')
            print(json.dumps(row), flush=True)
            if not info['has_next_page']:
                break
            if not changed:
                raise RuntimeError('Missing, repeated, or cyclic cursor; stopping')
            if index and not ids - seen:
                raise RuntimeError('No new listings; stopping rather than retrying')
            seen.update(ids)
            cursors.add(cursor)
            variables['cursor'] = cursor
            time.sleep(1)


if __name__ == '__main__':
    main()
