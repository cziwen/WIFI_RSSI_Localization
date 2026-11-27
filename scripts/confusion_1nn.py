# Usage: python3 -I scripts/confusion_1nn.py collector-src/samples collector-src/wifi-rssi-samples-by-round [band: all|5]
# Pooled 1-NN on the 66 test scans, same rules as KNN.swift (>=50% at any point, -100 fill, >=3 shared APs).
import json,glob,sys,collections
def load(f):
    d=json.load(open(f)); s={}
    for a in d['access_points']:
        b=(a.get('bssid') or '').lower()
        if b and -127<=a['rssi']<=-1: s[b]=max(s.get(b,-999),a['rssi']); ch[b]=a.get('channel') or ch.get(b,0)
    return d['point_id'],s
ch={}
refs=[load(f) for f in sorted(glob.glob(sys.argv[1]+'/*/scan-*.json'))]
tests=[load(f) for f in sorted(glob.glob(sys.argv[2]+'/round-*/test/**/*.json',recursive=True))]
cnt=collections.defaultdict(collections.Counter);tot=collections.Counter()
for p,s in refs:
    tot[p]+=1; cnt[p].update(s.keys())
keep={b for p in cnt for b in cnt[p] if cnt[p][b]/tot[p]>=.5}
if len(sys.argv)>3 and sys.argv[3]=='5': keep={b for b in keep if ch[b]>14}
R=[(p,{b:v for b,v in s.items() if b in keep}) for p,s in refs]
conf=collections.Counter();ok=0
for t,s in tests:
    s={b:v for b,v in s.items() if b in keep}; best=None
    for p,r in R:
        if len(s.keys()&r.keys())<3: continue
        k=s.keys()|r.keys(); d=sum((s.get(x,-100)-r.get(x,-100))**2 for x in k)/len(k)
        if best is None or d<best[0]: best=(d,p)
    pr=best[1] if best else None; conf[(t,pr)]+=1; ok+=pr==t
print(len(keep),'BSSIDs',ok,'/',len(tests))
print(','.join(f"{t[1:]}/{p[1:]}/{n}" for (t,p),n in sorted(conf.items()) if p))
