#!/usr/bin/env python3
import json,sys
from pathlib import Path
p=Path(sys.argv[1])
strict=plans=target_hits=0
pending=None
for line in p.read_text(errors='ignore').splitlines():
    if line.startswith('LURE OK mode=exclusive_lure'):
        f={}
        for token in line.split():
            if '=' in token:
                k,v=token.split('=',1); f[k]=v
        pending=(int(f.get('exclusiveBest','0'))>=2 and
                 int(f.get('competitorBest','9'))<=1)
    elif pending is not None and 'BATCH VERIFIED ' in line:
        plans+=1; strict+=int(pending); pending=None
        if ' new=' in line:
            tray=line.split(' new=',1)[1].split(' combo=',1)[0].split('|')
            target_hits+=tray.count('1')
print(json.dumps({'strict':strict,'plans':plans,'targetHits':target_hits}))
