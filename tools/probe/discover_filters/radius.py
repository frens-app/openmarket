#!/usr/bin/env python3
"""Cookie-free, bounded Discover radius comparison; aggregate output only."""
import argparse
import collections
import copy
import importlib.util
import json
import math
import pathlib
import time
import urllib.parse
import urllib.request

BASE = pathlib.Path(__file__).resolve().parents[1] / 'anonymous_graphql'
spec = importlib.util.spec_from_file_location('feed_probe', BASE / 'run.py')
feed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(feed)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--mode', choices=['radius','refinement','alternate_path'], default='radius')
    args = parser.parse_args()
    config = json.loads((BASE / 'browse.json').read_text())
    results, previous = [], {}
    # Identical-radius repeats bracket the treatment to expose ordinary churn.
    variants = [('baseline',65000,None), ('small',8000,None), ('tiny',2000,None), ('repeat',65000,None)]
    if args.mode == 'refinement':
        variants = [('control',8000,None), ('local_candidate',8000,{'locality':'local'}),
                    ('price_max_10',8000,{'max_price_cents':1000}),
                    ('local_text',8000,{'text':'local pickup within 5 miles'})]
    if args.mode == 'alternate_path':
        variants = [('alternate_baseline',65000,None), ('alternate_small',8000,None)]
    for label, radius, refinement in variants:
        variables = copy.deepcopy(config['variables'])
        variables['radius'] = radius
        variables['refinement'] = refinement
        if args.mode == 'alternate_path': variables['useSDFPath'] = False
        seen = set()
        for index in range(2):
            fields = {'__user':'0','av':'0','__a':'1','__comet_req':'15',
                'fb_api_caller_class':'RelayModern','fb_api_req_friendly_name':config['operation'],
                'server_timestamps':'true','doc_id':config['doc_id'],'variables':json.dumps(variables)}
            request = urllib.request.Request('https://www.facebook.com/api/graphql/',
                data=urllib.parse.urlencode(fields).encode(), headers={
                    'User-Agent':'OpenMarket/0.0.1 (iOS)', 'Content-Type':'application/x-www-form-urlencoded'})
            started = time.monotonic()
            with urllib.request.urlopen(request,timeout=15) as response:
                raw, status = response.read(), response.status
            cards, info, errors, records = feed.decode(raw)
            if errors or not info:
                raise RuntimeError('GraphQL error or missing page_info; stopping')
            cities = collections.Counter()
            deliveries = collections.Counter()
            location_shapes = collections.Counter()
            distances, prices = [], []
            origin = variables['buyLocation']
            for card in cards.values():
                price = card.get('listing_price') or {}
                if price.get('amount') is not None: prices.append(float(price['amount']))
                elif price.get('amount_with_offset') is not None: prices.append(float(price['amount_with_offset'])/100)
                location = card.get('location') or {}
                location_shapes[','.join(sorted(location))] += 1
                reverse = location.get('reverse_geocode') or {}
                cities[str(reverse.get('city') or reverse.get('city_name') or 'unknown')] += 1
                deliveries['+'.join(sorted(card.get('delivery_types') or [])) or 'unknown'] += 1
                latitude, longitude = location.get('latitude'), location.get('longitude')
                if latitude is not None and longitude is not None:
                    a,b,c,d = map(math.radians,[origin['latitude'],origin['longitude'],latitude,longitude])
                    distances.append(6371*2*math.asin(math.sqrt(math.sin((c-a)/2)**2+math.cos(a)*math.cos(c)*math.sin((d-b)/2)**2)))
            ids = set(cards)
            row = dict(label=label,radius=radius,refinement=refinement,use_sdf_path=variables['useSDFPath'],page=index,status=status,ms=round((time.monotonic()-started)*1000),
                listings=len(ids),new=len(ids-seen),cities=dict(cities),delivery_types=dict(deliveries),
                location_shapes=dict(location_shapes),has_next_page=info.get('has_next_page'),
                price_coverage=len(prices),prices_above_10=sum(p>10 for p in prices),
                distance_coverage=len(distances),outside_8km=sum(d>8 for d in distances) if distances else None,
                max_distance_km=round(max(distances),2) if distances else None,
                overlap_with_baseline=None)
            control_key = ('baseline' if args.mode == 'radius' else 'control' if args.mode == 'refinement' else 'alternate_baseline', index)
            if control_key in previous:
                row['overlap_with_baseline'] = len(ids & previous[control_key])
            results.append(row)
            previous[(label,index)] = ids
            args.output.write_text(json.dumps({'session':'anonymous','results':results},indent=2)+'\n')
            print(json.dumps(row),flush=True)
            cursor = info.get('end_cursor')
            if not info.get('has_next_page'): break
            if not cursor or cursor == variables['cursor']: raise RuntimeError('Cursor did not advance')
            variables['cursor'] = cursor
            seen |= ids
            time.sleep(1)

if __name__ == '__main__': main()
