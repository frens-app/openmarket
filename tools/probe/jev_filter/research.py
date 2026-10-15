#!/usr/bin/env python3
"""Opt-in research only. Public card retrieval; no cookies, detail fetches or writes.
Raw listings/images/results stay under ignored build/jev-research. Credentials
are read only from the app's explicit Gateway config; never written or logged.
"""
import argparse, base64, concurrent.futures, io, json, math, pathlib, time, urllib.request, urllib.parse, urllib.error
from PIL import Image, ImageOps, ImageDraw
ROOT = pathlib.Path(__file__).resolve().parents[3]
OUT = ROOT/'build/jev-research'
OUT.mkdir(parents=True, exist_ok=True)

def key():
    env={}
    for line in (ROOT/'apps/backend/.env.local').read_text().splitlines():
        if '=' in line and not line.lstrip().startswith('#'):
            k,v=line.split('=',1); env[k.strip()]=v.strip().strip('\"\'')
    return env.get('AI_GATEWAY_API_KEY') or (env['LLM_API_KEY'] if env.get('LLM_PROVIDER')=='vercel' else None)

def request(url, body=None, auth=False, headers=None):
    h={'User-Agent':'OpenMarket/0.0.1 (iOS)'}
    h.update(headers or {})
    if auth: h['Authorization']='Bearer '+key()
    req=urllib.request.Request(url,data=body,headers=h)
    t=time.perf_counter()
    try:
        with urllib.request.urlopen(req,timeout=40) as r:
            data=r.read(5_000_000); status=r.status
    except urllib.error.HTTPError as e:
        data=e.read(2000); status=e.code
    return status,data,round((time.perf_counter()-t)*1000,2)

def collect():
    searches=[('black standing desk','Toronto',43.6532,-79.3832),('black standing desk','San Francisco',37.779379,-122.418433),('white dresser','Toronto',43.6532,-79.3832)]
    for index,(query,city,lat,lon) in enumerate(searches):
        config=json.loads((ROOT/'tools/probe/anonymous_graphql/search.json').read_text())
        v=config['variables']; v['params']['bqf']['query']=query
        b=v['params']['browse_request_params'];b.update(filter_location_latitude=lat,filter_location_longitude=lon,filter_radius_km=25,commerce_enable_shipping=False)
        fields={'__user':'0','av':'0','__a':'1','__comet_req':'15','fb_api_caller_class':'RelayModern','fb_api_req_friendly_name':config['operation'],'server_timestamps':'true','doc_id':config['doc_id'],'variables':json.dumps(v)}
        status,raw,ms=request('https://www.facebook.com/api/graphql/',urllib.parse.urlencode(fields).encode(),headers={'Content-Type':'application/x-www-form-urlencoded','Accept':'application/json'})
        if status!=200: raise RuntimeError(f'Search stopped: HTTP {status}')
        text=raw.decode().removeprefix('for (;;);').strip()
        records=[json.loads(line) for line in text.splitlines() if line.strip()]
        cards=[]; info=None
        for record in records:
            if record.get('error') or record.get('errors'): raise RuntimeError('GraphQL error; stop')
            conn=record.get('data',{}).get('marketplace_search',{}).get('feed_units')
            if conn:
                info=conn['page_info']
                for edge in conn['edges']:
                    l=edge.get('node',{}).get('listing')
                    if not l: continue
                    cards.append({'id':l['id'],'title':l['marketplace_listing_title'],'price':l.get('listing_price'),'image_url':l.get('primary_listing_photo',{}).get('image',{}).get('uri'),'is_sold':l.get('is_sold')})
        if info is None: raise RuntimeError('No verified search connection')
        out={'query':query,'city':city,'lat':lat,'lon':lon,'radius_km':25,'search_ms':ms,'has_more':info.get('has_next_page'),'cards':cards}
        (OUT/f'dataset-{index}.json').write_text(json.dumps(out,indent=2))
        print(json.dumps({'dataset':index,'query':query,'city':city,'count':len(cards),'search_ms':ms}),flush=True)
        time.sleep(.5)

def download_images():
    for path in sorted(OUT.glob('dataset-*.json')):
        ds=json.loads(path.read_text()); i=path.stem.split('-')[1]
        def get(pair):
            j,c=pair
            if not c.get('image_url'): return dict(index=j,error='missing')
            status,raw,ms=request(c['image_url'])
            if status!=200: return dict(index=j,error=f'HTTP {status}')
            t=time.perf_counter()
            im=ImageOps.exif_transpose(Image.open(io.BytesIO(raw))).convert('RGB')
            original=list(im.size)
            im.thumbnail((560,560))
            # Fit all documented minimum dimensions/area without distorting.
            w,h=im.size; factor=max(1,256/w,256/h,math.sqrt(78400/(w*h)))
            if factor>1: im=im.resize((math.ceil(w*factor),math.ceil(h*factor)),Image.Resampling.LANCZOS)
            dst=OUT/f'{i}-{j:02}.jpg';im.save(dst,'JPEG',quality=80)
            return dict(index=j,path=dst.name,download_ms=ms,prepare_ms=round((time.perf_counter()-t)*1000,2),source_bytes=len(raw),bytes=dst.stat().st_size,original_size=original,size=list(im.size))
        t=time.perf_counter()
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool: images=list(pool.map(get,enumerate(ds['cards'])))
        ds['images_wall_ms']=round((time.perf_counter()-t)*1000,2)
        for c,m in zip(ds['cards'],images): c['image']=m
        path.write_text(json.dumps(ds,indent=2))
        print(json.dumps({'dataset':i,'images_wall_ms':ds['images_wall_ms'],'failures':sum('error' in x for x in images),'bytes':sum(x.get('bytes',0) for x in images)}),flush=True)
        for offset in range(0,len(ds['cards']),12):
            subset=ds['cards'][offset:offset+12]
            sheet=Image.new('RGB',(1200,math.ceil(len(subset)/4)*300),'white'); draw=ImageDraw.Draw(sheet)
            import textwrap
            for k,c in enumerate(subset):
                x=(k%4)*300;y=(k//4)*300
                if 'path' in c['image']:
                    im=Image.open(OUT/c['image']['path']);im.thumbnail((290,220));sheet.paste(im,(x+(300-im.width)//2,y))
                label=f'{i}-{offset+k:02}: '+c['title']
                draw.multiline_text((x+5,y+222),'\n'.join(textwrap.wrap(label,width=43)[:4]),fill='black')
            sheet.save(OUT/f'sheet-{i}-{offset}.jpg')

def smoke():
    # Known visual control; generated test fixture, not a product photograph.
    im=Image.new('RGB',(280,280),'red');buf=io.BytesIO();im.save(buf,'PNG')
    asset={'type':'image','format':'png','data_base64':base64.b64encode(buf.getvalue()).decode()}
    for label,with_image in [('text',False),('image',True)]:
        body={'model':'typesafe-ai/jev','state':'a red rectangle' if not with_image else {'photo':'probe-image-4cd378c7'},'questions':{'color':{'type':'choice','instructions':'What color is the rectangle?','criteria':{'red':'Red','blue':'Blue','green':'Green','unknown':'Cannot determine'}}}}
        if with_image: body['assets']={'probe-image-4cd378c7':asset}
        status,raw,ms=request('https://ai-gateway.vercel.sh/typesafe/v1/systemone',json.dumps(body).encode(),True,{'Content-Type':'application/json','TypeSafe-Danger-Zone-Images':'true'})
        result={'label':label,'status':status,'elapsed_ms':ms,'response':json.loads(raw)}
        (OUT/f'smoke-{label}.json').write_text(json.dumps(result,indent=2))
        print(json.dumps(result)[:4000],flush=True)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('action',choices=['collect','images','smoke']);a=p.parse_args()
    {'collect':collect,'images':download_images,'smoke':smoke}[a.action]()
