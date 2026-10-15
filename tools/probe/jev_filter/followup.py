#!/usr/bin/env python3
"""Exploratory controls: same Gemini prompt without images; Jev three-way choice.
These are follow-up arms on the same sample, not an independent held-out test.
"""
import hashlib,json,random,time
from research import OUT,request
from benchmark import POLICY,vision_payload

def main():
    tasks=[(i,arm,r) for i in range(3) for arm in ['gemini_text','jev_triage'] for r in range(3)]
    random.Random(13).shuffle(tasks)
    for i,arm,r in tasks:
        ds=json.loads((OUT/f'dataset-{i}.json').read_text())
        dst=OUT/f'result-{i}-{arm}-{r}.json'
        if dst.exists(): continue
        if arm=='gemini_text':
            body=vision_payload(ds)
            body['messages'][0]['content']=[p for p in body['messages'][0]['content'] if p['type']=='text']
            url='https://ai-gateway.vercel.sh/v1/chat/completions'
        else:
            questions={}
            for j,c in enumerate(ds['cards']):
                questions[f'candidate_{j}']={'type':'choice','instructions':POLICY+' Classify this candidate against the query in shared state. Candidate: '+json.dumps({'title':c['title']}),'criteria':{'match':'Available evidence supports the requested product and descriptors.','unknown':'Plausible product, but one or more requested attributes cannot be determined.','mismatch':'Available evidence clearly contradicts the product type or a requested descriptor.'}}
            body={'model':'typesafe-ai/jev','state':{'query':ds['query']},'questions':questions}
            url='https://ai-gateway.vercel.sh/v1/evaluate'
        encoded=json.dumps(body).encode();status,raw,ms=request(url,encoded,True,{'Content-Type':'application/json'})
        obj=json.loads(raw)
        dst.write_text(json.dumps({'dataset':i,'arm':arm,'repeat':r,'status':status,'elapsed_ms':ms,'request_bytes':len(encoded),'label_sha256':hashlib.sha256((OUT/'labels.json').read_bytes()).hexdigest(),'response':obj},indent=2))
        print(json.dumps({'dataset':i,'arm':arm,'repeat':r,'status':status,'elapsed_ms':ms,'usage':obj.get('usage')}),flush=True)
        if status!=200: raise RuntimeError('Model failed; stop')
        time.sleep(.15)
if __name__=='__main__':main()
