#!/usr/bin/env python3
from pathlib import Path
from collections import Counter
from functools import lru_cache
import json, math, random
ROOT=Path(__file__).resolve().parent
shapes=[]; weights={}
for line in (ROOT/'observed_shapes.tsv').read_text().splitlines():
 s,n=line.split('\t');shapes.append(s);weights[s]=int(n)
idx={s:i for i,s in enumerate(shapes)}
placements={}
for s in shapes:
 rows=s.split('/');h=len(rows);w=len(rows[0]); ps=[]
 for r in range(9-h):
  for c in range(9-w):
   m=0
   for rr,row in enumerate(rows):
    for cc,ch in enumerate(row):
     if ch=='1':m|=1<<((r+rr)*8+c+cc)
   ps.append(m)
 placements[s]=ps

def drop(b,m):
 nb=b|m; clear=0; lines=0
 for r in range(8):
  rm=255<<(8*r)
  if nb&rm==rm:clear|=rm;lines+=1
 for c in range(8):
  cm=0x0101010101010101<<c
  if nb&cm==cm:clear|=cm;lines+=1
 return nb&~clear,lines

def sstats(b,s):
 fits=clears=best=0
 for m in placements[s]:
  if not b&m:
   fits+=1;_,cl=drop(b,m)
   clears+=cl>0;best=max(best,cl)
 return fits,clears,best

def complete(b,tray):
 @lru_cache(None)
 def rec(bb,mask):
  if not mask:return True
  for k,s in enumerate(tray):
   if mask>>k&1:
    for m in placements[s]:
     if not bb&m:
      nb,_=drop(bb,m)
      if rec(nb,mask&~(1<<k)):return True
  return False
 return rec(b,7)

def safe(b,tray,skips):
 @lru_cache(None)
 def rec(bb,mask,sk):
  if not mask:return True
  for k,s in enumerate(tray):
   if mask>>k&1:
    for m in placements[s]:
     if not bb&m:
      nb,cl=drop(bb,m); nk=0 if cl else sk+1
      if nk<=2 and rec(nb,mask&~(1<<k),nk):return True
  return False
 return rec(b,7,skips)
rows=[];seen=set(); raw=[]
for ln,line in enumerate((ROOT/'runtime/blockbot_calibration/strict.jsonl').read_text(errors='ignore').splitlines(),1):
 try:o=json.loads(line)
 except:continue
 raw.append((ln,o))
 if o.get('mode')!='generator_observation':continue
 vals=str(o.get('pieces','')).split('|')
 if len(vals)!=3 or any(v not in idx for v in vals):continue
 sig=(str(o.get('boardBits')),tuple(vals),o.get('verified'),o.get('round'))
 if sig in seen:continue
 seen.add(sig);o['_line']=ln;rows.append(o)
W=sum(weights.values())
actual_shape=[]; base_shape=[]
obs_complete=obs_safe=obs_anyclear=0
baseline_fit=baseline_clear=baseline_best=0.0
one=[]
X=[];Y=[]
for o in rows:
 b=int(o['boardBits']);tray=o['pieces'].split('|');sk=int(o.get('skips',0) or 0)
 stats={s:sstats(b,s) for s in shapes}
 for s in tray:actual_shape.append(stats[s])
 baseline_fit+=3*sum(weights[s]*stats[s][0] for s in shapes)/W
 baseline_clear+=3*sum(weights[s]*stats[s][1] for s in shapes)/W
 baseline_best+=3*sum(weights[s]*stats[s][2] for s in shapes)/W
 obs_complete+=complete(b,tuple(tray));obs_safe+=safe(b,tuple(tray),sk)
 obs_anyclear+=any(stats[s][1]>0 for s in tray)
 yc=Counter(tray)
 for s in shapes:
  f,c,be=stats[s]
  X.append((o['_line'],s,math.log1p(f),math.log1p(c),be,math.log(weights[s]/W)))
  Y.append(yc[s])
 if '1' in tray:one.append({'line':o['_line'],'board':b,'tray':tray,'filled':int(o.get('filled',bin(b).count('1'))),'stats':stats['1'],'rankClear':1+sum(stats[s][1]>stats['1'][1] for s in shapes),'rankBest':1+sum(stats[s][2]>stats['1'][2] for s in shapes)})
# Conditional softmax fit with empirical prior offset.
beta=[0.0,0.0,0.0]
try:
 import numpy as np
 from scipy.optimize import minimize
 by={}
 for x,y in zip(X,Y):by.setdefault(x[0],[]).append((x,y))
 def fg(bb):
  loss=0.;grad=np.zeros(3)
  for items in by.values():
   feats=np.array([[q[0][2],q[0][3],q[0][4]] for q in items]); ys=np.array([q[1] for q in items],float); offs=np.array([q[0][5] for q in items])
   z=offs+feats@bb;z-=z.max();p=np.exp(z);p/=p.sum();n=ys.sum();loss-=ys@np.log(p+1e-300);grad-=feats.T@(ys-n*p)
  return loss,grad
 res=minimize(lambda b:fg(b),np.zeros(3),jac=True,method='BFGS')
 beta=res.x.tolist();ll_full=-res.fun;ll_null=-fg(np.zeros(3))[0]
except Exception as e:
 ll_full=ll_null=None
# Exact observed-tray tests above are retained. Counterfactual tray-mass
# evaluation is delegated to the optimized C++ simulator.
comp_mass=[float('nan')]; safe_mass=[float('nan')]
actual_n=len(actual_shape)
out={
 'catalog_shapes':len(shapes),'generator_observations':len(rows),'actual_pieces':actual_n,
 'observed_tray_complete_rate':obs_complete/len(rows),'observed_tray_combo_safe_rate':obs_safe/len(rows),'observed_tray_any_immediate_clear_rate':obs_anyclear/len(rows),
 'actual_mean_fits':sum(x[0] for x in actual_shape)/actual_n,'unconditional_expected_mean_fits':baseline_fit/actual_n,
 'actual_mean_clear_placements':sum(x[1] for x in actual_shape)/actual_n,'unconditional_expected_mean_clear_placements':baseline_clear/actual_n,
 'actual_mean_best_lines':sum(x[2] for x in actual_shape)/actual_n,'unconditional_expected_mean_best_lines':baseline_best/actual_n,
 'conditional_logit':{'features':['log1p_fits','log1p_clear_placements','best_lines'],'beta':beta,'ll_null':ll_null,'ll_full':ll_full,'delta_ll':None if ll_full is None else ll_full-ll_null},
 'model_random_tray_complete_mass_mean_sample':sum(comp_mass)/len(comp_mass),'model_random_tray_complete_mass_min_sample':min(comp_mass),
 'among_complete_trays_combo_safe_mass_mean_sample':sum(safe_mass)/len(safe_mass),'among_complete_trays_combo_safe_mass_min_sample':min(safe_mass),
 'one_by_one_observations':one,
 'conclusion':{
  'generator_filters_unplayable_trays':obs_complete==len(rows),
  'generator_guarantees_combo':False,
  'one_by_one_was_lured':bool(one and one[0]['stats'][1]>0)
 }
}
(ROOT/'generator_logic_final_analysis.json').write_text(json.dumps(out,indent=2)+'\n')
print(json.dumps(out,indent=2))
