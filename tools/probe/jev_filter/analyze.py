#!/usr/bin/env python3
"""Aggregate frozen-label quality, endpoint latency, provider time and billed cost."""
import collections,json,math,statistics
from research import OUT

def choices(result):
    o=result['response'];arm=result['arm']
    if arm.startswith('gemini'):
        values=json.loads(o['choices'][0]['message']['content'])['decisions']
        return {x['index']:x['keep'] for x in values}
    if arm=='jev_triage':return {int(k.split('_')[1]):v['choice']!='mismatch' for k,v in o['answers'].items()}
    return {int(k.split('_')[1]):v['probability']>=.8 for k,v in o['answers'].items()}

def meta(o):
    if 'providerMetadata' in o:return o['providerMetadata'].get('gateway',{})
    if 'provider_metadata' in o:return o['provider_metadata'].get('gateway',{})
    return o['choices'][0]['message'].get('provider_metadata',{}).get('gateway',{})

def cost(o):
    # Gemini is BYOK: Gateway cost=0 is NOT free provider inference.
    return float(o.get('usage',{}).get('market_cost',meta(o).get('marketCost',0)))

def metrics(pred, labels, datasets):
    c=collections.Counter()
    for k,l in labels.items():
        if int(k.split('-')[0]) not in datasets:continue
        keep=pred[k];truth=l[0]
        c['retained']+=keep;c['total']+=1
        if truth=='unknown':c['unknown_retained']+=keep;c['unknown']+=1;continue
        if truth=='yes':c['tp' if keep else 'fn']+=1
        else:c['fp' if keep else 'tn']+=1
    c['precision']=round(c['tp']/(c['tp']+c['fp']),4) if c['tp']+c['fp'] else None
    c['recall']=round(c['tp']/(c['tp']+c['fn']),4) if c['tp']+c['fn'] else None
    c['accuracy']=round((c['tp']+c['tn'])/(c['tp']+c['tn']+c['fp']+c['fn']),4)
    return dict(c)

def main():
    labels=json.loads((OUT/'labels.json').read_text())['labels']
    rows=[json.loads(p.read_text()) for p in OUT.glob('result-*.json')]
    grouped=collections.defaultdict(list)
    for r in rows:
        if r['status']==200:grouped[r['arm']].append(r)
    out={'label_count':len(labels),'known_labels':sum(v[0]!='unknown' for v in labels.values()),'total_model_calls':len(rows),'total_inference_cost_usd':sum(cost(r['response']) for r in rows if r['status']==200),'methods':{}}
    preds={'unfiltered':{k:True for k in labels}}
    for arm,rs in grouped.items():
        votes=collections.defaultdict(list)
        for r in rs:
            for j,keep in choices(r).items():votes[f'{r["dataset"]}-{j:02}'].append(keep)
        pred={k:sum(v)>=len(v)/2 for k,v in votes.items()};preds[arm]=pred
        lat=[r['elapsed_ms'] for r in rs];provider=[];costs=[cost(r['response']) for r in rs]
        uncached=[cost(r['response']) for r in rs if r['response'].get('usage',{}).get('prompt_tokens_details',{}).get('cached_tokens',0)==0]
        for r in rs:
            for model in meta(r['response']).get('routing',{}).get('modelAttempts',[]):
                for attempt in model.get('providerAttempts',[]):
                    if attempt.get('success'):provider.append(attempt['endTime']-attempt['startTime'])
        out['methods'][arm]={'calls':len(rs),'median_ms':round(statistics.median(lat),2),'min_ms':min(lat),'max_ms':max(lat),'sample_p95_ms':sorted(lat)[math.ceil(.95*len(lat))-1],'median_provider_ms':statistics.median(provider) if provider else None,'mean_cost_usd':statistics.mean(costs),'uncached_mean_cost_usd':statistics.mean(uncached) if uncached else None,'decision_disagreements_across_repeats':sum(len(set(v))>1 for v in votes.values())}
    for arm,pred in preds.items():
        m=out['methods'].setdefault(arm,{})
        m['all_quality']=metrics(pred,labels,[0,1,2]);m['desk_quality']=metrics(pred,labels,[0,1]);m['by_dataset']={i:metrics(pred,labels,[i]) for i in range(3)}
    out['majority_decisions']=preds
    (OUT/'summary.json').write_text(json.dumps(out,indent=2))
    print(json.dumps({k:v for k,v in out.items() if k!='majority_decisions'},indent=2))
    print('Desk examples:')
    for k,l in labels.items():
        if not k.startswith('2-'):print(k,l,[(arm,pred.get(k)) for arm,pred in preds.items()])
if __name__=='__main__':main()
