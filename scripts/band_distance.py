# Usage: python3 -I scripts/band_distance.py collector-src/samples
# Median pairwise RMS distance (missing = -100 dBm) between reference scans, same vs different point, per band.
import json,glob,sys,itertools,statistics as st,math
from collections import defaultdict
refs=[];ch={}
for f in sorted(glob.glob(sys.argv[1]+'/*/scan-*.json')):
    d=json.load(open(f)); sig={}
    for a in d['access_points']:
        b=(a.get('bssid') or '').lower()
        if not b: continue
        if a.get('channel'): ch[b]=a['channel']
        if -127<=a['rssi']<=-1: sig[b]=max(sig.get(b,-999),a['rssi'])
    refs.append((d.get('point_id') or d.get('pointId'),sig))
print(len(refs),{k for k in d})
cnt=defaultdict(lambda:defaultdict(int));tot=defaultdict(int)
for p,s in refs:
    tot[p]+=1
    for b in s: cnt[p][b]+=1
keep={b for p in cnt for b in cnt[p] if cnt[p][b]/tot[p]>=.5}
sets={'all':keep,'2.4':{b for b in keep if ch[b]<=14},'5':{b for b in keep if ch[b]>14}}
for name,B in sets.items():
    fs=[(p,{b:v for b,v in s.items() if b in B}) for p,s in refs]
    for need in (0,3):
        same=[];diff=[]
        for (p,a),(q,b) in itertools.combinations(fs,2):
            if len(a.keys()&b.keys())<need: continue
            k=a.keys()|b.keys()
            dd=math.sqrt(sum((a.get(x,-100)-b.get(x,-100))**2 for x in k)/len(k))
            (same if p==q else diff).append(dd)
        ms,md=st.median(same),st.median(diff)
        print(name,len(B),'overlap>=',need,round(ms,1),round(md,1),round(md/ms,2))
