#!/usr/bin/env python3
"""Embed compact, already-downloaded sample photos into a review visualization."""
import argparse,base64,io,json,pathlib
from PIL import Image
from research import OUT
parser=argparse.ArgumentParser();parser.add_argument('--output',type=pathlib.Path,default=OUT/'review.html');parser.add_argument('--summary',type=pathlib.Path,default=OUT/'summary.json');args=parser.parse_args();VIS=args.output
summary=json.loads(args.summary.read_text());labels=json.loads((OUT/'labels.json').read_text())['labels']
methods=[m for m in summary['methods'] if m!='unfiltered'];datasets=[]
method_labels={'current_text':'Existing Gateway Jev · text','descriptor_text':'Gateway Jev · descriptor text · 0.8 cutoff','jev_triage':'Gateway Jev · keep uncertain matches','gemini_text':'Gemini · text','gemini_vision':'Gemini · title + photo','jev-1.14.0_current_text':'Jev 1.14 direct · current text policy','jev-1.14.0_descriptor_text':'Jev 1.14 direct · descriptor text · 0.8 cutoff','jev-1.14.0_descriptor_vision':'Jev 1.14 direct · title + photo · 0.8 cutoff','jev-1.14.0_triage_text':'Jev 1.14 direct · text · keep uncertain','jev-1.14.0_triage_vision':'Jev 1.14 direct · title + photo · keep uncertain','jev-1.13.0_descriptor_text':'Jev 1.13 direct · descriptor text · 0.8 cutoff','jev-1.13.0_descriptor_vision':'Jev 1.13 direct · title + photo · 0.8 cutoff'}
for i in range(3):
    ds=json.loads((OUT/f'dataset-{i}.json').read_text());cards=[]
    for j,c in enumerate(ds['cards']):
        k=f'{i}-{j:02}'
        im=Image.open(OUT/c['image']['path']);im.thumbnail((260,260));b=io.BytesIO();im.save(b,'JPEG',quality=65)
        cards.append({'title':c['title'],'label':labels[k][0],'reason':labels[k][1],'image':'data:image/jpeg;base64,'+base64.b64encode(b.getvalue()).decode(),'decisions':{m:summary['majority_decisions'][m][k] for m in methods}})
    datasets.append({'name':ds['query']+' · '+ds['city'],'cards':cards})
text=pathlib.Path(__file__).with_name('review-template.html').read_text();assert '__JEV_DATA__' in text
VIS.write_text(text.replace('__JEV_DATA__',json.dumps({'methods':methods,'methodLabels':method_labels,'datasets':datasets},ensure_ascii=False).replace('</','<\\/')))
assert VIS.stat().st_size<1_000_000
print('Visualization bytes',VIS.stat().st_size)
