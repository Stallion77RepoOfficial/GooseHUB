from pathlib import Path
import csv,json,collections,statistics,sys,math
r=Path(__file__).resolve().parent;label=sys.argv[1];j=json.loads((r/(label+'.json')).read_text());rows=list(csv.DictReader((r/(label+'-frames.csv')).open()));factor=j['timebase']['numer']/j['timebase']['denom']/1e6
for row in rows:
 for k in ['ticks','swap_ticks','thread','begin','draw','upload']:
  row[k]=int(row[k])
threads=collections.Counter((row['thread'],row['hdc']) for row in rows);primary=threads.most_common(1)[0][0];rows=[row for row in rows if (row['thread'],row['hdc'])==primary];data=[]
def pct(a,q):
 return sorted(a)[max(0,min(len(a)-1,math.ceil(q*len(a))-1))]
for phase in j['phases']:
 selected=[(a,b) for a,b in zip(rows,rows[1:]) if a['ticks']>=phase['beginTicks'] and b['ticks']<=phase['endTicks']]
 if not selected:continue
 times=[(b['ticks']-a['ticks'])*factor for a,b in selected];swaps=[b['swap_ticks']*factor for a,b in selected];slow=sorted(times,reverse=True)[:max(1,math.ceil(len(times)*.01))]
 d={'phase':phase['name'],'frames':len(times),'fps':1000/statistics.mean(times),'medianMs':statistics.median(times),'p95Ms':pct(times,.95),'p99Ms':pct(times,.99),'maxMs':max(times),'low1PercentFPS':1000/statistics.mean(slow),'swapMeanMs':statistics.mean(swaps),'swapP99Ms':pct(swaps,.99),'beginPerFrame':statistics.mean(b['begin'] for a,b in selected),'drawPerFrame':statistics.mean(b['draw'] for a,b in selected),'uploadsPerFrame':statistics.mean(b['upload'] for a,b in selected),'sceneReport':phase['report']};data.append(d)
 print(phase['name'],json.dumps({k:round(v,3) if isinstance(v,float) else v for k,v in d.items() if k not in ['sceneReport','phase']}))
(r/(label+'-analysis.json')).write_text(json.dumps({'primaryContext':primary,'phases':data},indent=2)+'\n')
