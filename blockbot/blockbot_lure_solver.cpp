#include <algorithm>
#include <array>
#include <bit>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <numeric>
#include <sstream>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>
using namespace std;
using U=uint64_t;
static constexpr int N=8, MAX_SKIPS=2;
static constexpr double BASE_MOVE_SEC=0.3640142857142857;
static constexpr double CLEAR_DELAY_SEC=0.450;
struct Placement{U mask; int r,c;};
struct Shape{string key; vector<string> rows; vector<Placement> pl; int weight=1;};
struct TrayObs{array<int,3> p; int weight=1;};
vector<Shape> shapes; vector<TrayObs> trays; vector<int> expandedTrays;
unordered_map<string,int> shapeId;
static inline U cell(int r,int c){return U(1)<<(r*8+c);}
vector<string> split(const string&s,char d){vector<string>o; string x; stringstream ss(s); while(getline(ss,x,d))o.push_back(x); return o;}
void loadData(){
 ifstream f("/home/user/kimirmes/projects/watermark-research/blockbot_5743_retrained/blockbot_empirical_trays_merged.seed.tsv"); string line;
 vector<array<string,4>> pending;
 while(getline(f,line)){
  auto v=split(line,'\t'); if(v.empty())continue;
  if(v[0]=="S"){
   Shape s; s.key=v[1]; s.weight=stoi(v[2]); s.rows=split(s.key,'/');
   int h=(int)s.rows.size(),w=(int)s.rows[0].size();
   for(int r=0;r+h<=8;r++)for(int c=0;c+w<=8;c++){
    U m=0; for(int i=0;i<h;i++)for(int j=0;j<w;j++)if(s.rows[i][j]=='1')m|=cell(r+i,c+j);
    s.pl.push_back({m,r,c});
   }
   shapeId[s.key]=(int)shapes.size(); shapes.push_back(std::move(s));
  } else if(v[0]=="T") pending.push_back({v[1],v[2],v[3],v[4]});
 }
 for(auto &v:pending){TrayObs t{{shapeId.at(v[0]),shapeId.at(v[1]),shapeId.at(v[2])},stoi(v[3])}; int id=(int)trays.size(); trays.push_back(t); for(int k=0;k<t.weight;k++)expandedTrays.push_back(id);}
}
pair<U,int> dropB(U b,U m){
 U nb=b|m,clear=0; int lines=0;
 for(int r=0;r<8;r++){U rm=U(0xff)<<(8*r); if((nb&rm)==rm){clear|=rm;lines++;}}
 for(int c=0;c<8;c++){U cm=U(0x0101010101010101)<<c; if((nb&cm)==cm){clear|=cm;lines++;}}
 return {nb&~clear,lines};
}
double evalB(U b){
 int empty=64-popcount(b),isolated=0,transitions=0,near=0,fit3=0,fit23=0,fit5=0,almost=0;
 for(int r=0;r<8;r++)for(int c=0;c<8;c++)if(!(b&cell(r,c))){int freeN=0; if(r&&!(b&cell(r-1,c)))freeN++;if(r<7&&!(b&cell(r+1,c)))freeN++;if(c&&!(b&cell(r,c-1)))freeN++;if(c<7&&!(b&cell(r,c+1)))freeN++;if(freeN<=1)isolated++;}
 for(int r=0;r<8;r++){int n=popcount((b>>(8*r))&255);if(n>=6)near++;if(n==7)almost++;for(int c=1;c<8;c++)if(bool(b&cell(r,c))!=bool(b&cell(r,c-1)))transitions++;}
 for(int c=0;c<8;c++){int n=0;for(int r=0;r<8;r++)n+=bool(b&cell(r,c));if(n>=6)near++;if(n==7)almost++;for(int r=1;r<8;r++)if(bool(b&cell(r,c))!=bool(b&cell(r-1,c)))transitions++;}
 for(int r=0;r<=5;r++)for(int c=0;c<=5;c++){bool ok=1;for(int i=0;i<3;i++)for(int j=0;j<3;j++)if(b&cell(r+i,c+j))ok=0;if(ok)fit3++;}
 for(int r=0;r<=6;r++)for(int c=0;c<=5;c++){bool ok=1;for(int i=0;i<2;i++)for(int j=0;j<3;j++)if(b&cell(r+i,c+j))ok=0;if(ok)fit23++;}
 for(int r=0;r<8;r++)for(int c=0;c<=3;c++){bool ok=1;for(int j=0;j<5;j++)if(b&cell(r,c+j))ok=0;if(ok)fit5++;}
 for(int c=0;c<8;c++)for(int r=0;r<=3;r++){bool ok=1;for(int i=0;i<5;i++)if(b&cell(r+i,c))ok=0;if(ok)fit5++;}
 return empty*2.0-isolated*18.0-transitions*1.8+near*5.0+almost*4.0+fit3*5.0+fit23*1.8+fit5*3.0;
}
array<double,256> rowCover{},colCover{},rowProgress{},colProgress{};
void buildLineModel(){
 double total=0;for(auto&s:shapes)total+=s.weight;
 for(int h=1;h<256;h++){
  int holes=popcount((unsigned)h);
  for(auto&s:shapes){bool allR=0,allC=0;int bestR=0,bestC=0;int H=s.rows.size(),W=s.rows[0].size();
   for(int rr=0;rr<H;rr++){int raw=0;for(int cc=0;cc<W;cc++)if(s.rows[rr][cc]=='1')raw|=1<<cc;for(int off=0;off+W<=8;off++){int pat=raw<<off;if((pat&~h)==0){bestR=max(bestR,popcount((unsigned)pat));if(pat==h)allR=1;}}}
   for(int cc=0;cc<W;cc++){int raw=0;for(int rr=0;rr<H;rr++)if(s.rows[rr][cc]=='1')raw|=1<<rr;for(int off=0;off+H<=8;off++){int pat=raw<<off;if((pat&~h)==0){bestC=max(bestC,popcount((unsigned)pat));if(pat==h)allC=1;}}}
   rowCover[h]+=s.weight*allR;colCover[h]+=s.weight*allC;rowProgress[h]+=s.weight*double(bestR)/holes;colProgress[h]+=s.weight*double(bestC)/holes;
  }
  rowCover[h]/=total;colCover[h]/=total;rowProgress[h]/=total;colProgress[h]/=total;
 }
}
double proxyPrep(U b){double z=0;for(int r=0;r<8;r++){int occ=(b>>(8*r))&255,h=(~occ)&255,filled=popcount((unsigned)occ);if(h){double f=pow(filled/8.0,3);z+=f*(160*rowCover[h]+25*rowProgress[h]);}}for(int c=0;c<8;c++){int occ=0;for(int r=0;r<8;r++)if(b&cell(r,c))occ|=1<<r;int h=(~occ)&255,filled=popcount((unsigned)occ);if(h){double f=pow(filled/8.0,3);z+=f*(160*colCover[h]+25*colProgress[h]);}}return z;}
struct Step{int slot,pl,lines;};
struct Tail{bool ok=false;U board=0;int lines=0;vector<Step>seq;double score=-1e300;int first=0,trailing=0;};
struct Options{Tail no,yes,early;};
struct Key{U b;int mask;bool operator==(const Key&o)const{return b==o.b&&mask==o.mask;}};
struct KeyHash{size_t operator()(const Key&k)const{return hash<U>{}(k.b^(U(k.mask)*0x9e3779b97f4a7c15ULL));}};
bool better(const Tail&a,const Tail&b){if(!b.ok)return true;if(fabs(a.score-b.score)>1e-9)return a.score>b.score;if(a.first!=b.first)return a.first<b.first;if(a.lines!=b.lines)return a.lines>b.lines;return a.trailing<b.trailing;}
struct OptionSolver{
 const array<int,3>&tray; bool probabilistic; double evalWeight; unordered_map<Key,Options,KeyHash>memo;
 OptionSolver(const array<int,3>&t,bool p,double e):tray(t),probabilistic(p),evalWeight(e){}
 double terminal(U b){return probabilistic?proxyPrep(b)+evalWeight*evalB(b):evalB(b);}
 Options rec(U b,int mask){
  if(!mask){Options o;o.no.ok=true;o.no.board=b;o.no.score=terminal(b);return o;}
  Key k{b,mask};auto it=memo.find(k);if(it!=memo.end())return it->second;Options out;
  for(int slot=0;slot<3;slot++)if(mask&(1<<slot)){auto&s=shapes[tray[slot]];for(int pi=0;pi<(int)s.pl.size();pi++){auto&p=s.pl[pi];if(b&p.mask)continue;auto [nb,cl]=dropB(b,p.mask);Options ch=rec(nb,mask&~(1<<slot));array<Tail,2>ts{ch.no,ch.yes};for(auto&t:ts)if(t.ok){Tail x;x.ok=true;x.board=t.board;x.lines=cl+t.lines;x.score=t.score;x.seq.reserve(1+t.seq.size());x.seq.push_back({slot,pi,cl});x.seq.insert(x.seq.end(),t.seq.begin(),t.seq.end());x.first=cl?0:1+t.first;x.trailing=cl?(int)t.seq.size():t.trailing;if(x.lines){if(better(x,out.yes))out.yes=x;if(cl&&better(x,out.early))out.early=x;}else if(better(x,out.no))out.no=x;}}}
  memo.emplace(k,out);return out;
 }
};
struct Metrics{int points=0,linePoints=0,bonus=0,clearMoves=0,lines=0,streak=0,skips=0,breaks=0;};
Metrics metrics(const Tail&t,int streak,int skips){Metrics m;m.streak=streak;m.skips=skips;for(auto&s:t.seq){m.lines+=s.lines;if(s.lines){m.clearMoves++;m.linePoints+=10*s.lines;m.streak++;m.skips=0;if(m.streak>=2)m.bonus+=10*m.streak;}else{m.skips++;if(m.skips>MAX_SKIPS){if(m.streak)m.breaks++;m.streak=0;m.skips=0;}}}m.points=m.linePoints+m.bonus;return m;}
struct Prep{double pPiece=0,pTray=0,pIndependent=0,setup=0,expLines=0;};
unordered_map<U,Prep>prepMemo;
Prep prep(U b){auto it=prepMemo.find(b);if(it!=prepMemo.end())return it->second;vector<char>clearable(shapes.size());vector<int>legal(shapes.size()),maxLines(shapes.size());double totalPiece=0,clearW=0,lineW=0;for(int i=0;i<(int)shapes.size();i++){auto&s=shapes[i];totalPiece+=s.weight;for(auto&p:s.pl)if(!(b&p.mask)){legal[i]++;auto d=dropB(b,p.mask);maxLines[i]=max(maxLines[i],d.second);}if(maxLines[i]){clearable[i]=1;clearW+=s.weight;}lineW+=s.weight*maxLines[i];}double den=0,num=0;for(auto&t:trays){bool elig=true,clr=false;for(int x:t.p){if(!legal[x])elig=false;if(clearable[x])clr=true;}if(elig){den+=t.weight;if(clr)num+=t.weight;}}if(!den){for(auto&t:trays){den+=t.weight;bool clr=false;for(int x:t.p)clr|=clearable[x];if(clr)num+=t.weight;}}Prep p;p.pPiece=clearW/max(1.0,totalPiece);p.pTray=num/max(1.0,den);p.pIndependent=1-pow(1-p.pPiece,3);p.expLines=lineW/max(1.0,totalPiece);p.setup=min(1.0,proxyPrep(b)/500.0);prepMemo.emplace(b,p);return p;}
struct Strategy{string name;bool legacy,prepBoard;int horizon;double discount,ratePenalty,futureScale,prepWeight,setupBoost;bool exactPlan=false,independentProb=false;double terminalEvalWeight=.02,terminalProxyWeight=0,streakProxyScale=0;int comboMode=0;double comboSkipWeight=1e6;};
double futureValue(U b,int streak,int skips,const Strategy&s){if(s.horizon<=0){if(s.prepWeight==0)return 0;return s.prepWeight*prep(b).setup;}Prep p=prep(b);double pClear=s.independentProb?p.pIndependent:p.pTray;int budget=max(0,MAX_SKIPS-skips);double setup=min(0.35,p.setup*s.setupBoost);double q0=1-(1-pClear)*pow(1-setup,budget);double qFull=1-(1-pClear)*pow(1-setup,MAX_SKIPS);double surv=1,v=0,disc=1;for(int k=1;k<=s.horizon;k++){surv*=k==1?q0:qFull;int ns=streak+k;double reward=10+(ns>=2?10*ns:0)-s.ratePenalty*CLEAR_DELAY_SEC;v+=disc*surv*reward;disc*=s.discount;}return s.futureScale*v+s.prepWeight*100*p.setup;}
struct ExactKey{U b;int mask,streak,skips;bool operator==(const ExactKey&o)const{return b==o.b&&mask==o.mask&&streak==o.streak&&skips==o.skips;}};
struct ExactHash{size_t operator()(const ExactKey&k)const{U x=k.b^(U(k.mask)*0x9e3779b97f4a7c15ULL)^(U(k.streak)*0xbf58476d1ce4e5b9ULL)^(U(k.skips)*0x94d049bb133111ebULL);return hash<U>{}(x);}};
struct ExactPlan{bool ok=false;double utility=-1e300;U board=0;int lines=0;vector<Step>seq;};
struct ExactSolver{
 const array<int,3>&tray;const Strategy&s;unordered_map<ExactKey,ExactPlan,ExactHash>memo;
 ExactPlan rec(U b,int mask,int streak,int skips){
  if(!mask){ExactPlan z;z.ok=true;z.board=b;if(s.comboMode){z.utility=double(streak)*1e9-(streak>0?double(skips)*s.comboSkipWeight:0)+s.terminalProxyWeight*proxyPrep(b)+s.terminalEvalWeight*evalB(b);}else{z.utility=s.terminalProxyWeight*proxyPrep(b)*(1+s.streakProxyScale*max(0,streak))+s.terminalEvalWeight*evalB(b)+futureValue(b,streak,skips,s);}return z;}
  ExactKey key{b,mask,streak,skips};auto it=memo.find(key);if(it!=memo.end())return it->second;ExactPlan best;
  for(int slot=0;slot<3;slot++)if(mask&(1<<slot)){auto&sh=shapes[tray[slot]];for(int pi=0;pi<(int)sh.pl.size();pi++){auto&pl=sh.pl[pi];if(b&pl.mask)continue;auto d=dropB(b,pl.mask);int ns=streak,nk=skips,reward=0;if(d.second){ns++;nk=0;if(!s.comboMode)reward=10*d.second+(ns>=2?10*ns:0);}else{nk++;if(nk>MAX_SKIPS){ns=0;nk=0;}}ExactPlan ch=rec(d.first,mask&~(1<<slot),ns,nk);if(!ch.ok)continue;double u=(s.comboMode?0:reward-s.ratePenalty*CLEAR_DELAY_SEC*(d.second>0))+ch.utility;if(!best.ok||u>best.utility+1e-9){best.ok=true;best.utility=u;best.board=ch.board;best.lines=d.second+ch.lines;best.seq.clear();best.seq.push_back({slot,pi,d.second});best.seq.insert(best.seq.end(),ch.seq.begin(),ch.seq.end());}}}
  memo.emplace(key,best);return best;
 }
};
Tail choosePlan(U b,const array<int,3>&tray,int streak,int skips,const Strategy&s){if(s.exactPlan){ExactSolver ex{tray,s};ExactPlan p=ex.rec(b,7,streak,skips);Tail t;if(!p.ok)return t;t.ok=true;t.board=p.board;t.lines=p.lines;t.seq=p.seq;t.score=p.utility;return t;}OptionSolver sol(tray,s.prepBoard,s.terminalEvalWeight);Options o=sol.rec(b,7);if(s.legacy){double safe=max(o.no.ok?o.no.score:-1e300,o.yes.ok?o.yes.score:-1e300);int budget=max(0,MAX_SKIPS-skips);if(o.yes.ok&&o.yes.first<=budget&&o.yes.score>=safe-200)return o.yes;if(o.early.ok&&o.early.score>=safe-200)return o.early;return o.no.ok?o.no:o.yes;}vector<Tail>v;for(auto*x:{&o.no,&o.yes,&o.early})if(x->ok)v.push_back(*x);Tail best;double bu=-1e300;unordered_set<string>seen;for(auto&t:v){string sig;for(auto&q:t.seq)sig+=to_string(q.slot)+":"+to_string(q.pl)+",";if(!seen.insert(sig).second)continue;Metrics m=metrics(t,streak,skips);double u=m.points-s.ratePenalty*CLEAR_DELAY_SEC*m.clearMoves+futureValue(t.board,m.streak,m.skips,s);if(!best.ok||u>bu+1e-9||(fabs(u-bu)<1e-9&&t.score>best.score)){best=t;bu=u;}}return best;}
bool canRec(U b,const array<int,3>&tray,int mask,unordered_map<Key,char,KeyHash>&memo){if(!mask)return true;Key k{b,mask};auto it=memo.find(k);if(it!=memo.end())return it->second;for(int slot=0;slot<3;slot++)if(mask&(1<<slot))for(auto&p:shapes[tray[slot]].pl)if(!(b&p.mask)){auto d=dropB(b,p.mask);if(canRec(d.first,tray,mask&~(1<<slot),memo)){memo[k]=1;return true;}}memo[k]=0;return false;}
bool canComplete(U b,const array<int,3>&tray){unordered_map<Key,char,KeyHash>m;return canRec(b,tray,7,m);}
struct ComboSafeKey{U b;int mask,skips;bool operator==(const ComboSafeKey&o)const{return b==o.b&&mask==o.mask&&skips==o.skips;}};
struct ComboSafeHash{size_t operator()(const ComboSafeKey&k)const{return hash<U>{}(k.b^(U(k.mask)*0x9e3779b97f4a7c15ULL)^(U(k.skips)*0xbf58476d1ce4e5b9ULL));}};
bool comboSafeRec(U b,const array<int,3>&tray,int mask,int skips,unordered_map<ComboSafeKey,char,ComboSafeHash>&memo){
 if(!mask)return true;ComboSafeKey key{b,mask,skips};auto it=memo.find(key);if(it!=memo.end())return it->second;
 for(int slot=0;slot<3;slot++)if(mask&(1<<slot))for(auto&p:shapes[tray[slot]].pl)if(!(b&p.mask)){auto d=dropB(b,p.mask);int nk=d.second?0:skips+1;if(nk>MAX_SKIPS)continue;if(comboSafeRec(d.first,tray,mask&~(1<<slot),nk,memo)){memo[key]=1;return true;}}
 memo[key]=0;return false;
}
bool comboSafe(U b,const array<int,3>&tray,int skips){unordered_map<ComboSafeKey,char,ComboSafeHash>m;return comboSafeRec(b,tray,7,skips,m);}
string trayName(const array<int,3>&t){return shapes[t[0]].key+"|"+shapes[t[1]].key+"|"+shapes[t[2]].key;}
bool firstComboCounterexample(U b,int skips,array<int,3>&bad,int&admissible,int&tested){admissible=0;tested=0;for(int a=0;a<(int)shapes.size();a++)for(int c=a;c<(int)shapes.size();c++)for(int d=c;d<(int)shapes.size();d++){array<int,3>t{a,c,d};tested++;if(!canComplete(b,t))continue;admissible++;if(!comboSafe(b,t,skips)){bad=t;return true;}}return false;}
void printBoardBits(U b){for(int r=0;r<8;r++){for(int c=0;c<8;c++)cout<<((b&cell(r,c))?'1':'0');if(r<7)cout<<'/';}}
void runMathBasic(){
 int one=shapeId.at("1");array<int,3>mono{one,one,one};bool placeable=canComplete(0,mono),safe=comboSafe(0,mono,0);
 cout<<"MATH_COUNTEREXAMPLE board=empty skips=0 tray="<<trayName(mono)<<" complete="<<placeable<<" comboSafe="<<safe<<" reason=three_cells_cannot_clear_eight_cell_line\n";
 auto check=[&](const string&label,U board,int skips){array<int,3>bad{};int admissible=0,tested=0;auto begin=chrono::steady_clock::now();bool found=firstComboCounterexample(board,skips,bad,admissible,tested);double sec=chrono::duration<double>(chrono::steady_clock::now()-begin).count();cout<<"MATH_ONE_STEP label="<<label<<" board=";printBoardBits(board);cout<<" skips="<<skips<<" universalSafe="<<(!found)<<" tested="<<tested<<" admissibleBeforeWitness="<<admissible;if(found)cout<<" witness="<<trayName(bad)<<" complete="<<canComplete(board,bad)<<" comboSafe="<<comboSafe(board,bad,skips);cout<<" wallSec="<<fixed<<setprecision(3)<<sec<<"\n";};
 U prepared=0;for(int c=0;c<7;c++)prepared|=cell(0,c);check("row7",prepared,0);
 U dense=~U(0);for(int i=0;i<8;i++)dense&=~cell(i,i);for(int skips=0;skips<=2;skips++)check("diagonal_holes",dense,skips);
}
struct SplitMix{U x;U next(){U z=(x+=0x9e3779b97f4a7c15ULL);z=(z^(z>>30))*0xbf58476d1ce4e5b9ULL;z=(z^(z>>27))*0x94d049bb133111ebULL;return z^(z>>31);}};
bool drawTray(U b,SplitMix&r,array<int,3>&out,int&rejects){for(int a=0;a<128;a++){int id=expandedTrays[r.next()%expandedTrays.size()];auto t=trays[id].p;if(canComplete(b,t)){out=t;return true;}rejects++;}vector<int>ok;int total=0;for(int i=0;i<(int)trays.size();i++)if(canComplete(b,trays[i].p)){ok.push_back(i);total+=trays[i].weight;}if(!total)return false;int pick=r.next()%total;for(int id:ok){if(pick<trays[id].weight){out=trays[id].p;return true;}pick-=trays[id].weight;}return false;}
struct Game{int score=0,linePoints=0,bonus=0,moves=0,rounds=0,lines=0,clearMoves=0,maxCombo=0,breaks=0,rejects=0;double sec=0;bool failed=false;};
Game play(const Strategy&s,U seed,double duration,int moveLimit){SplitMix rng{seed};Game g;U b=0;int streak=0,skips=0;while(moveLimit>0 ? g.moves<moveLimit : g.sec<duration){array<int,3>tray;if(!drawTray(b,rng,tray,g.rejects)){g.failed=true;break;}Tail plan=choosePlan(b,tray,streak,skips,s);if(!plan.ok||plan.seq.size()!=3){g.failed=true;break;}for(auto&st:plan.seq){auto&p=shapes[tray[st.slot]].pl[st.pl];if(b&p.mask){g.failed=true;return g;}auto d=dropB(b,p.mask);b=d.first;g.moves++;g.lines+=d.second;g.sec+=BASE_MOVE_SEC;if(d.second){g.clearMoves++;g.linePoints+=10*d.second;streak++;skips=0;if(streak>=2)g.bonus+=10*streak;g.maxCombo=max(g.maxCombo,streak);g.sec+=CLEAR_DELAY_SEC;}else{skips++;if(skips>MAX_SKIPS){if(streak){g.breaks++;}streak=0;skips=0;}}}g.rounds++;}g.score=g.linePoints+g.bonus;return g;}
double quant(vector<double>v,double q){sort(v.begin(),v.end());return v[min(v.size()-1,(size_t)floor(q*(v.size()-1)))];}

bool drawComboGuaranteedTray(U b,int skips,SplitMix&r,array<int,3>&out,int&rejects){
 for(int a=0;a<512;a++){int id=expandedTrays[r.next()%expandedTrays.size()];auto t=trays[id].p;if(canComplete(b,t)&&comboSafe(b,t,skips)){out=t;return true;}rejects++;}
 vector<int>ok;int total=0;for(int i=0;i<(int)trays.size();i++)if(canComplete(b,trays[i].p)&&comboSafe(b,trays[i].p,skips)){ok.push_back(i);total+=trays[i].weight;}
 if(!total)return false;int pick=r.next()%total;for(int id:ok){if(pick<trays[id].weight){out=trays[id].p;return true;}pick-=trays[id].weight;}return false;
}
long long fullPlanCountRec(U b,const array<int,3>&tray,int mask,int skips,bool safeOnly,long long cap){
 if(!mask)return 1;long long total=0;
 for(int slot=0;slot<3;slot++)if(mask&(1<<slot))for(auto&p:shapes[tray[slot]].pl)if(!(b&p.mask)){
  auto d=dropB(b,p.mask);int nk=d.second?0:skips+1;if(safeOnly&&nk>MAX_SKIPS)continue;
  total+=fullPlanCountRec(d.first,tray,mask&~(1<<slot),d.second?0:nk,safeOnly,cap);
  if(total>=cap)return cap;
 }
 return total;
}
string jsonEscape(const string&s){string o;for(char c:s){if(c=='\\'||c=='\"')o+='\\';o+=c;}return o;}
void runGraphProbe(int games,int moveLimit,U seed,const string&path){
 ofstream out(path);Strategy policy={"graph_combo_blend_p100",false,true,0,0,0,0,0,0,true,true,1,1.0,0,1,1000000};
 long long transitions=0,failed=0,totalRejects=0;unordered_set<U>boards;unordered_set<string>states;
 for(int g=0;g<games;g++){
  SplitMix rng{seed+U(g)*0x9e3779b97f4a7c15ULL};U b=0;int streak=1,skips=0,moves=0,round=0,rejects=0;
  while(moves<moveLimit){array<int,3>tray;if(!drawComboGuaranteedTray(b,skips,rng,tray,rejects)){failed++;break;}
   U before=b;int beforeActive=streak>0,beforeSkips=skips;Tail plan=choosePlan(b,tray,streak,skips,policy);if(!plan.ok||plan.seq.size()!=3){failed++;break;}
   long long legal=fullPlanCountRec(before,tray,7,beforeSkips,false,1000000),safe=fullPlanCountRec(before,tray,7,beforeSkips,true,1000000);
   string seq="";for(auto&st:plan.seq){auto&p=shapes[tray[st.slot]].pl[st.pl];auto d=dropB(b,p.mask);b=d.first;moves++;if(d.second){streak++;skips=0;}else{skips++;if(skips>MAX_SKIPS){streak=0;skips=0;}}if(!seq.empty())seq+=';';seq+=to_string(st.slot)+":"+to_string(p.r)+":"+to_string(p.c)+":"+to_string(d.second);}
   string bs=to_string(before)+":"+to_string(beforeActive)+":"+to_string(beforeSkips),as=to_string(b)+":"+to_string(streak>0)+":"+to_string(skips);states.insert(bs);states.insert(as);boards.insert(before);boards.insert(b);
   out<<"{\"game\":"<<g<<",\"round\":"<<round<<",\"before\":"<<before<<",\"active\":"<<beforeActive<<",\"skips\":"<<beforeSkips<<",\"tray\":\""<<jsonEscape(trayName(tray))<<"\",\"seq\":\""<<seq<<"\",\"after\":"<<b<<",\"afterActive\":"<<(streak>0)<<",\"afterSkips\":"<<skips<<",\"filled\":"<<popcount(before)<<",\"legalPlans\":"<<legal<<",\"safePlans\":"<<safe<<",\"proxy\":"<<fixed<<setprecision(6)<<proxyPrep(before)<<"}\n";
   transitions++;round++;
  }
  totalRejects+=rejects;
 }
 out.close();cout<<"GRAPH_PROBE games="<<games<<" moves="<<moveLimit<<" transitions="<<transitions<<" states="<<states.size()<<" boards="<<boards.size()<<" failed="<<failed<<" rejects="<<totalRejects<<" path="<<path<<"\n";
}

struct SteeringPartial{U b=0;int mask=0,streak=0,skips=0,lines=0;bool preserved=false;vector<Step>seq;};
struct SteeringStateKey{U b;int mask,streak,skips;bool preserved;bool operator==(const SteeringStateKey&o)const{return b==o.b&&mask==o.mask&&streak==o.streak&&skips==o.skips&&preserved==o.preserved;}};
struct SteeringStateHash{size_t operator()(const SteeringStateKey&k)const{return hash<U>{}(k.b^(U(k.mask)*0x9e3779b97f4a7c15ULL)^(U(k.streak)*0xbf58476d1ce4e5b9ULL)^(U(k.skips)*0x94d049bb133111ebULL)^(U(k.preserved)*0xd6e8feb86659fd93ULL));}};
vector<SteeringPartial> steeringOutcomes(U board,const array<int,3>&tray,int streak,int skips){
 vector<SteeringPartial> layer{{board,7,streak,skips,0,streak>0,{}}};const size_t BEAM=8000;
 for(int depth=0;depth<3;depth++){
  unordered_map<SteeringStateKey,SteeringPartial,SteeringStateHash> next;
  for(auto&cur:layer)for(int slot=0;slot<3;slot++)if(cur.mask&(1<<slot))for(int pi=0;pi<(int)shapes[tray[slot]].pl.size();pi++){
   auto&pl=shapes[tray[slot]].pl[pi];if(cur.b&pl.mask)continue;auto d=dropB(cur.b,pl.mask);
   SteeringPartial z=cur;z.b=d.first;z.mask&=~(1<<slot);z.lines+=d.second;z.seq.push_back({slot,pi,d.second});
   if(d.second){z.streak++;z.skips=0;}else{z.skips++;if(z.skips>MAX_SKIPS){z.preserved=false;z.streak=0;z.skips=0;}}
   SteeringStateKey key{z.b,z.mask,z.streak,z.skips,z.preserved};auto it=next.find(key);if(it==next.end())next.emplace(key,std::move(z));
  }
  layer.clear();layer.reserve(next.size());for(auto&kv:next)layer.push_back(std::move(kv.second));
  if(layer.size()>BEAM){sort(layer.begin(),layer.end(),[](auto&a,auto&b){bool aa=a.streak>0,bb=b.streak>0;if(aa!=bb)return aa>bb;if(a.streak!=b.streak)return a.streak>b.streak;double ea=evalB(a.b)+proxyPrep(a.b),eb=evalB(b.b)+proxyPrep(b.b);if(abs(ea-eb)>1e-9)return ea>eb;return a.skips<b.skips;});layer.resize(BEAM);}
 }
 return layer;
}
struct SteeringProfile{double rho=0,lcb=0,pFirst=0;int den=0,safe=0,first=0;};
bool anyImmediateClear(U b,const array<int,3>&tray){for(int i=0;i<3;i++)for(auto&p:shapes[tray[i]].pl)if(!(b&p.mask)&&dropB(b,p.mask).second>0)return true;return false;}
SteeringProfile steeringProfile(U b,int skips){SteeringProfile p;for(auto&t:trays)if(canComplete(b,t.p)){p.den+=t.weight;if(comboSafe(b,t.p,skips))p.safe+=t.weight;if(anyImmediateClear(b,t.p))p.first+=t.weight;}if(p.den){p.rho=double(p.safe)/p.den;p.pFirst=double(p.first)/p.den;double z=1.96,n=p.den,ph=p.rho;p.lcb=(ph+z*z/(2*n)-z*sqrt((ph*(1-ph)+z*z/(4*n))/n))/(1+z*z/n);}return p;}

struct SteeringChoice{bool ok=false;SteeringPartial plan;SteeringProfile profile;int outcomes=0,candidates=0;};
SteeringChoice chooseSteeringSim(U board,const array<int,3>&tray,int streak,int skips){
 SteeringChoice out;auto all=steeringOutcomes(board,tray,streak,skips);out.outcomes=all.size();if(all.empty())return out;
 bool preserve=streak>0&&any_of(all.begin(),all.end(),[](auto&x){return x.preserved;});vector<SteeringPartial*> eligible;for(auto&x:all)if(!preserve||x.preserved)eligible.push_back(&x);
 vector<SteeringPartial*> cand;if(eligible.size()<=384)cand=eligible;else{
  auto addTop=[&](auto cmp){auto v=eligible;sort(v.begin(),v.end(),cmp);for(int i=0;i<96&&i<(int)v.size();i++)cand.push_back(v[i]);};
  addTop([](auto*a,auto*b){return evalB(a->b)+proxyPrep(a->b)>evalB(b->b)+proxyPrep(b->b);});
  addTop([](auto*a,auto*b){return proxyPrep(a->b)>proxyPrep(b->b);});
  addTop([](auto*a,auto*b){if(a->skips!=b->skips)return a->skips<b->skips;return evalB(a->b)>evalB(b->b);});
  addTop([](auto*a,auto*b){return popcount(a->b)>popcount(b->b);});sort(cand.begin(),cand.end());cand.erase(unique(cand.begin(),cand.end()),cand.end());
 }
 out.candidates=cand.size();SteeringPartial*best=nullptr;SteeringProfile bp;
 for(auto*x:cand){auto q=steeringProfile(x->b,x->skips);bool take=!best;if(best){bool perfect=q.rho>=0.995,bperfect=bp.rho>=0.995;int gain=x->streak-streak,bgain=best->streak-streak;if(perfect!=bperfect)take=perfect;else if(perfect){if(gain!=bgain)take=gain>bgain;else if(abs(q.pFirst-bp.pFirst)>1e-12)take=q.pFirst>bp.pFirst;else if(abs(q.lcb-bp.lcb)>1e-12)take=q.lcb>bp.lcb;else if(x->skips!=best->skips)take=x->skips<best->skips;else take=evalB(x->b)+proxyPrep(x->b)>evalB(best->b)+proxyPrep(best->b);}else{if(abs(q.lcb-bp.lcb)>1e-12)take=q.lcb>bp.lcb;else if(gain!=bgain)take=gain>bgain;else if(abs(q.pFirst-bp.pFirst)>1e-12)take=q.pFirst>bp.pFirst;else if(x->skips!=best->skips)take=x->skips<best->skips;else take=evalB(x->b)+proxyPrep(x->b)>evalB(best->b)+proxyPrep(best->b);}}if(take){best=x;bp=q;}}
 if(best){out.ok=true;out.plan=*best;out.profile=bp;}return out;
}
struct MillionGame{bool reached=false,failed=false;long long score=0;int moves=0,rounds=0,lines=0,clearMoves=0,breaks=0,maxCombo=0,comboAtTarget=0,rejects=0;double gameSec=0,cpuSec=0,sumRho=0;int rhoN=0;};
MillionGame playSteeringMillion(U seed,long long target,int moveLimit=20000){
 auto begin=chrono::steady_clock::now();SplitMix rng{seed};MillionGame g;U b=0;int streak=0,skips=0;
 while((target>0 ? g.score<target : g.moves<moveLimit)&&g.moves<moveLimit){array<int,3>tray;if(!drawTray(b,rng,tray,g.rejects)){g.failed=true;break;}auto ch=chooseSteeringSim(b,tray,streak,skips);if(!ch.ok){g.failed=true;break;}g.sumRho+=ch.profile.rho;g.rhoN++;
  for(auto&st:ch.plan.seq){auto&p=shapes[tray[st.slot]].pl[st.pl];if(b&p.mask){g.failed=true;break;}auto d=dropB(b,p.mask);b=d.first;g.moves++;g.lines+=d.second;g.gameSec+=BASE_MOVE_SEC;if(d.second){g.clearMoves++;streak++;skips=0;g.score+=10LL*d.second;if(streak>=2)g.score+=10LL*streak;g.maxCombo=max(g.maxCombo,streak);g.gameSec+=CLEAR_DELAY_SEC;}else{skips++;if(skips>MAX_SKIPS){if(streak)g.breaks++;streak=0;skips=0;}}if((target>0&&g.score>=target)||(target<=0&&g.moves>=moveLimit)){g.reached=true;g.comboAtTarget=streak;break;}}
  g.rounds++;if(g.failed)break;
 }
 g.cpuSec=chrono::duration<double>(chrono::steady_clock::now()-begin).count();return g;
}
void runMillionBench(int games,long long target,U seed,const string&path,int moveLimit=20000){
 ofstream out(path);vector<double>maxC,atC,times,moves,rounds,breaks,rhos;double cpu=0;int reached=0,failed=0;
 for(int i=0;i<games;i++){auto g=playSteeringMillion(seed+U(i)*0x9e3779b97f4a7c15ULL,target,moveLimit);reached+=g.reached;failed+=g.failed;cpu+=g.cpuSec;maxC.push_back(g.maxCombo);atC.push_back(g.comboAtTarget);times.push_back(g.gameSec);moves.push_back(g.moves);rounds.push_back(g.rounds);breaks.push_back(g.breaks);rhos.push_back(g.rhoN?g.sumRho/g.rhoN:0);out<<i<<'\t'<<g.reached<<'\t'<<g.score<<'\t'<<g.moves<<'\t'<<g.rounds<<'\t'<<g.lines<<'\t'<<g.clearMoves<<'\t'<<g.maxCombo<<'\t'<<g.comboAtTarget<<'\t'<<g.breaks<<'\t'<<fixed<<setprecision(3)<<g.gameSec<<'\t'<<g.cpuSec<<'\t'<<(g.rhoN?g.sumRho/g.rhoN:0)<<'\n';out.flush();cerr<<"MILLION_PROGRESS "<<(i+1)<<'/'<<games<<" reached="<<g.reached<<" maxCombo="<<g.maxCombo<<" gameSec="<<g.gameSec<<" cpuSec="<<g.cpuSec<<"\n";}
 auto mean=[](const vector<double>&v){return accumulate(v.begin(),v.end(),0.0)/max<size_t>(1,v.size());};
 cout<<fixed<<setprecision(3)<<"MILLION_SUMMARY games="<<games<<" reached="<<reached<<" failed="<<failed<<" target="<<target<<" meanMaxCombo="<<mean(maxC)<<" p10MaxCombo="<<quant(maxC,.1)<<" medianMaxCombo="<<quant(maxC,.5)<<" p90MaxCombo="<<quant(maxC,.9)<<" meanComboAtTarget="<<mean(atC)<<" medianComboAtTarget="<<quant(atC,.5)<<" meanBreaks="<<mean(breaks)<<" noBreakRate="<<count(breaks.begin(),breaks.end(),0.0)/double(games)<<" meanMoves="<<mean(moves)<<" meanRounds="<<mean(rounds)<<" meanGameSec="<<mean(times)<<" medianGameSec="<<quant(times,.5)<<" p10GameSec="<<quant(times,.1)<<" p90GameSec="<<quant(times,.9)<<" meanRho="<<mean(rhos)<<" cpuSec="<<cpu<<" path="<<path<<"\n";
}
struct LureKey{U b;int mask;bool operator==(const LureKey&o)const{return b==o.b&&mask==o.mask;}};
struct LureKeyHash{size_t operator()(const LureKey&k)const{return hash<U>{}(k.b^(U(k.mask)*0x9e3779b97f4a7c15ULL));}};
struct LureProfile{double score=0,progress=0,baitProgress=0,conditionalMargin=0;int targetFits=0,targetClear=0,targetBest=0,targetExclusive=0,targetExclusiveBest=0,competitorShapes=0,competitorClear=0,competitorBest=0,fitShapes=0;};
bool lureRelevant(int sid,int target){return sid==target||shapes[sid].weight<=1;}
void lureShapeStats(U b,int sid,int&fits,int&clears,int&best,double&progress,double&bestGain){
 fits=clears=best=0;progress=0;bestGain=-10;int beforeEmpty=64-popcount(b);
 for(auto&p:shapes[sid].pl){
  if(b&p.mask)continue;fits++;auto d=dropB(b,p.mask);
  if(d.second){clears++;best=max(best,d.second);}bestGain=max(bestGain,double((64-popcount(d.first))-beforeEmpty));
  for(int r=0;r<8;r++){int n=popcount((b>>(8*r))&255),add=popcount((p.mask>>(8*r))&255),v=n+add;if(v<8)progress=max(progress,double(v));}
  for(int c=0;c<8;c++){int n=0,add=0;for(int r=0;r<8;r++){n+=bool(b&cell(r,c));add+=bool(p.mask&cell(r,c));}int v=n+add;if(v<8)progress=max(progress,double(v));}
 }
}
double conditionalShapeScore(int sid,int fits,int clears,int best,double bestGain,double progress){
 int cells=0;for(auto&r:shapes[sid].rows)cells+=count(r.begin(),r.end(),'1');
 return -.13325*log1p(fits)-.26834*log1p(clears)+.30890*best+.01924*bestGain+.02240*progress+.02938*cells;
}
double singleBaitProgress(U b){
 double best=-1e30;
 for(int r=0;r<8;r++)for(int c=0;c<8;c++)if(!(b&cell(r,c))){
  int rf=popcount((b>>(8*r))&255),cf=0,ring=0,otherAlmost=0;
  for(int rr=0;rr<8;rr++)cf+=bool(b&cell(rr,c));
  for(int dr=-1;dr<=1;dr++)for(int dc=-1;dc<=1;dc++)if(dr||dc){int rr=r+dr,cc=c+dc;if(rr>=0&&rr<8&&cc>=0&&cc<8&&b&cell(rr,cc))ring++;}
  for(int rr=0;rr<8;rr++)if(rr!=r&&popcount((b>>(8*rr))&255)==7)otherAlmost++;
  for(int cc=0;cc<8;cc++)if(cc!=c){int n=0;for(int rr=0;rr<8;rr++)n+=bool(b&cell(rr,cc));if(n==7)otherAlmost++;}
  double q=20.0*(rf+cf)+12.0*ring-80.0*otherAlmost;
  if(rf==7)q+=250;if(cf==7)q+=250;if(rf==7&&cf==7)q+=2000;if(ring==8)q+=800;if(rf==7&&cf==7&&ring==8)q+=10000;
  best=max(best,q);
 }
 return best;
}
U criticalTargetMask(U b,U placement){
 U full=b|placement,critical=0;
 for(int r=0;r<8;r++){U rm=U(255)<<(8*r);if((full&rm)==rm)critical|=placement&rm;}
 for(int c=0;c<8;c++){U cm=U(0x0101010101010101)<<c;if((full&cm)==cm)critical|=placement&cm;}
 return critical;
}
LureProfile lureProfile(U b,int target){
 LureProfile q;double targetConditional=-1e30,bestCompetitorConditional=-1e30;
 for(int sid=0;sid<(int)shapes.size();sid++)if(lureRelevant(sid,target)){
  int fits=0,clears=0,best=0;double progress=0,bestGain=-10;lureShapeStats(b,sid,fits,clears,best,progress,bestGain);
  if(fits)q.fitShapes++;double cs=conditionalShapeScore(sid,fits,clears,best,bestGain,progress);
  if(sid==target){q.targetFits=fits;q.targetClear=clears;q.targetBest=best;q.progress=progress;targetConditional=cs;}
  else{bestCompetitorConditional=max(bestCompetitorConditional,cs);if(clears){q.competitorShapes++;q.competitorClear+=clears;q.competitorBest=max(q.competitorBest,best);}}
 }
 for(auto&tp:shapes[target].pl){
  if(b&tp.mask)continue;auto td=dropB(b,tp.mask);if(!td.second)continue;U critical=criticalTargetMask(b,tp.mask);bool alternate=false;
  for(int sid=0;sid<(int)shapes.size()&&!alternate;sid++)if(sid!=target&&lureRelevant(sid,target))for(auto&cp:shapes[sid].pl){
   if(b&cp.mask)continue;auto cd=dropB(b,cp.mask);if(cd.second&&(cp.mask&critical)==critical){alternate=true;break;}
  }
  if(!alternate){q.targetExclusive++;q.targetExclusiveBest=max(q.targetExclusiveBest,td.second);}
 }
 q.baitProgress=shapes[target].key=="1"?singleBaitProgress(b):q.progress*100.0;
 q.conditionalMargin=targetConditional-bestCompetitorConditional;
 int relevant=0;for(int sid=0;sid<(int)shapes.size();sid++)relevant+=lureRelevant(sid,target);int safeFloor=max(20,relevant*3/4);
 q.score=double(q.targetExclusiveBest)*1e12+double(q.targetExclusive)*1e11+double(q.targetBest)*2e10
        -double(q.competitorBest)*5e9-double(q.competitorShapes)*2e8-double(q.competitorClear)*2e6
        +q.baitProgress*1e6+q.conditionalMargin*1e8+double(q.fitShapes)*1e5+evalB(b);
 if(q.fitShapes<safeFloor)q.score-=double(safeFloor-q.fitShapes)*2e11;
 return q;
}
double quickLure(U b,int target){
 int f=0,c=0,best=0;double p=0,g=-10;lureShapeStats(b,target,f,c,best,p,g);
 double bait=shapes[target].key=="1"?singleBaitProgress(b):p*100.0;
 return best*2e10+bait*1e6+conditionalShapeScore(target,f,c,best,g,p)*1e8+evalB(b);
}
vector<SteeringPartial> lureOutcomes(U board,const array<int,3>&tray,int target){
 vector<SteeringPartial> layer{{board,7,0,0,0,false,{}}};const size_t BEAM=6000;
 for(int depth=0;depth<3;depth++){
  unordered_map<LureKey,SteeringPartial,LureKeyHash> next;
  for(auto&cur:layer)for(int slot=0;slot<3;slot++)if(cur.mask&(1<<slot))for(int pi=0;pi<(int)shapes[tray[slot]].pl.size();pi++){
   auto&pl=shapes[tray[slot]].pl[pi];if(cur.b&pl.mask)continue;auto d=dropB(cur.b,pl.mask);
   SteeringPartial z=cur;z.b=d.first;z.mask&=~(1<<slot);z.lines+=d.second;z.seq.push_back({slot,pi,d.second});
   LureKey key{z.b,z.mask};if(next.find(key)==next.end())next.emplace(key,std::move(z));
  }
  layer.clear();layer.reserve(next.size());for(auto&kv:next)layer.push_back(std::move(kv.second));
  if(layer.size()>BEAM){sort(layer.begin(),layer.end(),[&](auto&a,auto&b){return quickLure(a.b,target)>quickLure(b.b,target);});layer.resize(BEAM);}
 }
 return layer;
}
int runLureSolve(int argc,char**argv){
 U board=0;string pieces,targetKey;
 for(int i=1;i<argc;i++){string a=argv[i];if(a=="--board"&&i+1<argc)board=stoull(argv[++i]);else if(a=="--pieces"&&i+1<argc)pieces=argv[++i];else if(a=="--target"&&i+1<argc)targetKey=argv[++i];}
 auto ti=shapeId.find(targetKey);if(ti==shapeId.end()){cout<<"FAIL target\n";return 2;}int target=ti->second;
 auto ks=split(pieces,'|');if(ks.size()!=3){cout<<"FAIL pieces\n";return 2;}for(auto&k:ks)if(!shapeId.count(k)){cout<<"FAIL unknown_piece\n";return 2;}
 array<int,3>tray{shapeId.at(ks[0]),shapeId.at(ks[1]),shapeId.at(ks[2])};auto begin=chrono::steady_clock::now();
 auto all=lureOutcomes(board,tray,target);if(all.empty()){cout<<"FAIL no_plan\n";return 3;}
 if(all.size()>2500){sort(all.begin(),all.end(),[&](auto&a,auto&b){return quickLure(a.b,target)>quickLure(b.b,target);});all.resize(2500);}
 SteeringPartial*best=nullptr;LureProfile bp;for(auto&x:all){auto p=lureProfile(x.b,target);if(!best||p.score>bp.score){best=&x;bp=p;}}
 if(!best){cout<<"FAIL no_candidate\n";return 4;}double ms=chrono::duration<double,milli>(chrono::steady_clock::now()-begin).count();
 cout<<fixed<<setprecision(3)<<"OK mode=exclusive_lure target="<<targetKey<<" targetFits="<<bp.targetFits<<" targetClear="<<bp.targetClear<<" targetBest="<<bp.targetBest<<" exclusive="<<bp.targetExclusive<<" exclusiveBest="<<bp.targetExclusiveBest<<" competitorShapes="<<bp.competitorShapes<<" competitorClear="<<bp.competitorClear<<" competitorBest="<<bp.competitorBest<<" fitShapes="<<bp.fitShapes<<" baitProgress="<<bp.baitProgress<<" conditionalMargin="<<bp.conditionalMargin<<" lureScore="<<bp.score<<" outcomes="<<all.size()<<" board="<<best->b<<" ms="<<ms<<" seq=";
 for(int i=0;i<(int)best->seq.size();i++){auto&s=best->seq[i];auto&p=shapes[tray[s.slot]].pl[s.pl];if(i)cout<<';';cout<<s.slot<<':'<<p.r<<':'<<p.c<<':'<<s.lines;}cout<<"\n";return 0;
}
int runSteeringSolve(int argc,char**argv){
 U board=0;int streak=0,skips=0;string pieces;
 for(int i=1;i<argc;i++){string a=argv[i];if(a=="--board"&&i+1<argc)board=stoull(argv[++i]);else if(a=="--pieces"&&i+1<argc)pieces=argv[++i];else if(a=="--streak"&&i+1<argc)streak=stoi(argv[++i]);else if(a=="--skips"&&i+1<argc)skips=stoi(argv[++i]);}
 auto ks=split(pieces,'|');if(ks.size()!=3){cout<<"FAIL pieces\n";return 2;}array<int,3>tray{shapeId.at(ks[0]),shapeId.at(ks[1]),shapeId.at(ks[2])};
 auto begin=chrono::steady_clock::now();auto all=steeringOutcomes(board,tray,streak,skips);if(all.empty()){cout<<"FAIL no_plan\n";return 3;}
 bool preserve=streak>0&&any_of(all.begin(),all.end(),[](auto&x){return x.preserved;});vector<SteeringPartial*> eligible;for(auto&x:all)if(!preserve||x.preserved)eligible.push_back(&x);
 // Diverse shortlist: exact profile for all small sets; otherwise combine rankings.
 vector<SteeringPartial*> cand;if(eligible.size()<=384)cand=eligible;else{
  auto addTop=[&](auto cmp){auto v=eligible;sort(v.begin(),v.end(),cmp);for(int i=0;i<96&&i<(int)v.size();i++)cand.push_back(v[i]);};
  addTop([](auto*a,auto*b){return evalB(a->b)+proxyPrep(a->b)>evalB(b->b)+proxyPrep(b->b);});
  addTop([](auto*a,auto*b){return proxyPrep(a->b)>proxyPrep(b->b);});
  addTop([](auto*a,auto*b){if(a->skips!=b->skips)return a->skips<b->skips;return evalB(a->b)>evalB(b->b);});
  addTop([](auto*a,auto*b){return popcount(a->b)>popcount(b->b);});
  sort(cand.begin(),cand.end());cand.erase(unique(cand.begin(),cand.end()),cand.end());
 }
 SteeringPartial*best=nullptr;SteeringProfile bp;for(auto*x:cand){auto p=steeringProfile(x->b,x->skips);bool take=!best;if(best){bool perfect=p.rho>=0.995,bperfect=bp.rho>=0.995;int gain=x->streak-streak,bgain=best->streak-streak;if(perfect!=bperfect)take=perfect;else if(perfect){if(gain!=bgain)take=gain>bgain;else if(abs(p.pFirst-bp.pFirst)>1e-12)take=p.pFirst>bp.pFirst;else if(abs(p.lcb-bp.lcb)>1e-12)take=p.lcb>bp.lcb;else if(x->skips!=best->skips)take=x->skips<best->skips;else take=evalB(x->b)+proxyPrep(x->b)>evalB(best->b)+proxyPrep(best->b);}else{if(abs(p.lcb-bp.lcb)>1e-12)take=p.lcb>bp.lcb;else if(gain!=bgain)take=gain>bgain;else if(abs(p.pFirst-bp.pFirst)>1e-12)take=p.pFirst>bp.pFirst;else if(x->skips!=best->skips)take=x->skips<best->skips;else take=evalB(x->b)+proxyPrep(x->b)>evalB(best->b)+proxyPrep(best->b);}}if(take){best=x;bp=p;}}
 if(!best){cout<<"FAIL no_candidate\n";return 4;}double ms=chrono::duration<double,milli>(chrono::steady_clock::now()-begin).count();
 cout<<fixed<<setprecision(6)<<"OK rho="<<bp.rho<<" lcb="<<bp.lcb<<" pfirst="<<bp.pFirst<<" den="<<bp.den<<" safe="<<bp.safe<<" outcomes="<<all.size()<<" candidates="<<cand.size()<<" board="<<best->b<<" streak="<<best->streak<<" skips="<<best->skips<<" ms="<<ms<<" seq=";
 for(int i=0;i<(int)best->seq.size();i++){auto&s=best->seq[i];auto&p=shapes[tray[s.slot]].pl[s.pl];if(i)cout<<';';cout<<s.slot<<':'<<p.r<<':'<<p.c<<':'<<s.lines;}cout<<"\n";return 0;
}
int main(int argc,char**argv){loadData();buildLineModel();for(int i=1;i<argc;i++)if(string(argv[i])=="--solve-lure")return runLureSolve(argc,argv);for(int i=1;i<argc;i++)if(string(argv[i])=="--million-bench"){int g=30,moveLimit=20000;long long target=1000000;U seed=987654321;string path="/tmp/blockbot_million_games.tsv";for(int j=1;j<argc;j++){string a=argv[j];if(a=="--games"&&j+1<argc)g=stoi(argv[++j]);else if(a=="--target"&&j+1<argc)target=stoll(argv[++j]);else if(a=="--moves"&&j+1<argc){moveLimit=stoi(argv[++j]);target=0;}else if(a=="--seed"&&j+1<argc)seed=stoull(argv[++j]);else if(a=="--out"&&j+1<argc)path=argv[++j];}runMillionBench(g,target,seed,path,moveLimit);return 0;}for(int i=1;i<argc;i++)if(string(argv[i])=="--solve-steering")return runSteeringSolve(argc,argv);for(int i=1;i<argc;i++)if(string(argv[i])=="--math-check-basic"){runMathBasic();return 0;}for(int i=1;i<argc;i++)if(string(argv[i])=="--graph-probe"){int g=20,m=600;U z=424242;string p="/tmp/blockbot_combo_graph.jsonl";for(int j=1;j<argc;j++){string a=argv[j];if(a=="--games"&&j+1<argc)g=stoi(argv[++j]);else if(a=="--move-limit"&&j+1<argc)m=stoi(argv[++j]);else if(a=="--seed"&&j+1<argc)z=stoull(argv[++j]);else if(a=="--graph-out"&&j+1<argc)p=argv[++j];}runGraphProbe(g,m,z,p);return 0;}int games=100,only=-1,moveLimit=0;double duration=120;U seed=0xC0B01234ULL;for(int i=1;i<argc;i++){string a=argv[i];if(a=="--games"&&i+1<argc)games=stoi(argv[++i]);else if(a=="--duration"&&i+1<argc)duration=stod(argv[++i]);else if(a=="--move-limit"&&i+1<argc)moveLimit=stoi(argv[++i]);else if(a=="--strat"&&i+1<argc)only=stoi(argv[++i]);else if(a=="--seed"&&i+1<argc)seed=stoull(argv[++i]);}
 vector<Strategy>ss={
  {"production_legacy",true,false,0,0,0,0,0,0},
  {"points_evalB",false,false,0,0,0,0,0,0},
  {"points_proxy",false,true,0,0,0,0,0,0},
  {"prob_h2_s10_r0",false,true,2,.90,0,.10,0,.15},
  {"prob_h4_s10_r0",false,true,4,.92,0,.10,0,.15},
  {"prob_h4_s25_r0",false,true,4,.92,0,.25,0,.15},
  {"prob_h6_s25_r0",false,true,6,.94,0,.25,0,.18},
  {"prob_h6_s50_r0",false,true,6,.94,0,.50,0,.18},
  {"prob_h8_s25_r0",false,true,8,.95,0,.25,0,.20},
  {"prob_h4_s25_r20",false,true,4,.92,20,.25,0,.15},
  {"prob_h4_s25_r60",false,true,4,.92,60,.25,0,.15},
  {"prob_h6_s10_r20",false,true,6,.94,20,.10,0,.18},
  {"points_proxy_r20",false,true,0,0,20,0,0,0},
  {"points_proxy_r60",false,true,0,0,60,0,0,0},
  {"points_proxy_pure",false,true,0,0,0,0,0,0,false,false,0,0},
  {"prob_h4_s25_pure",false,true,4,.92,0,.25,0,.15,false,false,0,0},
  {"prob_h4_s25_independent",false,true,4,.92,0,.25,0,.15,false,true,0,0},
  {"exact_points_w000",false,true,0,0,0,0,0,0,true,true,0,0},
  {"exact_points_w005",false,true,0,0,0,0,0,0,true,true,0,.05},
  {"exact_points_w010",false,true,0,0,0,0,0,0,true,true,0,.10},
  {"exact_points_w025",false,true,0,0,0,0,0,0,true,true,0,.25},
  {"exact_points_w050",false,true,0,0,0,0,0,0,true,true,0,.50},
  {"exact_points_w100",false,true,0,0,0,0,0,0,true,true,0,1.00},
  {"exact_points_w003",false,true,0,0,0,0,0,0,true,true,0,.03},
  {"exact_points_w004",false,true,0,0,0,0,0,0,true,true,0,.04},
  {"exact_points_w006",false,true,0,0,0,0,0,0,true,true,0,.06},
  {"exact_points_w0075",false,true,0,0,0,0,0,0,true,true,0,.075},
  {"exact_points_w0125",false,true,0,0,0,0,0,0,true,true,0,.125},
  {"exact_points_w015",false,true,0,0,0,0,0,0,true,true,0,.15},
  {"exact_points_w005_r20",false,true,0,0,20,0,0,0,true,true,0,.05},
  {"exact_points_w005_r60",false,true,0,0,60,0,0,0,true,true,0,.05},
  {"exact_points_w010_r20",false,true,0,0,20,0,0,0,true,true,0,.10},
  {"exact_points_w010_r60",false,true,0,0,60,0,0,0,true,true,0,.10},
  {"exact_points_w005_s0025",false,true,0,0,0,0,0,0,true,true,0,.05,.0025},
  {"exact_points_w005_s005",false,true,0,0,0,0,0,0,true,true,0,.05,.005},
  {"exact_points_w005_s010",false,true,0,0,0,0,0,0,true,true,0,.05,.010},
  {"exact_points_w010_s005",false,true,0,0,0,0,0,0,true,true,0,.10,.005},
  {"exact_points_w011",false,true,0,0,0,0,0,0,true,true,0,.11},
  {"exact_points_w012",false,true,0,0,0,0,0,0,true,true,0,.12},
  {"exact_points_w013",false,true,0,0,0,0,0,0,true,true,0,.13},
  {"exact_points_w014",false,true,0,0,0,0,0,0,true,true,0,.14},
  {"exact_points_w016",false,true,0,0,0,0,0,0,true,true,0,.16},
  {"exact_points_w0175",false,true,0,0,0,0,0,0,true,true,0,.175},
  {"exact_points_w019",false,true,0,0,0,0,0,0,true,true,0,.19},
  {"exact_points_w020",false,true,0,0,0,0,0,0,true,true,0,.20},
  {"exact_points_w0225",false,true,0,0,0,0,0,0,true,true,0,.225},
  {"exact_points_w0125_r20",false,true,0,0,20,0,0,0,true,true,0,.125},
  {"exact_points_w015_r20",false,true,0,0,20,0,0,0,true,true,0,.15},
  {"exact_points_w015_r40",false,true,0,0,40,0,0,0,true,true,0,.15},
  {"exact_points_w015_r60",false,true,0,0,60,0,0,0,true,true,0,.15},
  {"exact_points_w0175_r20",false,true,0,0,20,0,0,0,true,true,0,.175},
  {"exact_points_w015_s001",false,true,0,0,0,0,0,0,true,true,0,.15,.001},
  {"exact_points_w015_s0025",false,true,0,0,0,0,0,0,true,true,0,.15,.0025},
  {"exact_points_w015_s005",false,true,0,0,0,0,0,0,true,true,0,.15,.005},
  {"combo_lex_proxy",false,true,0,0,0,0,0,0,true,true,0,1,0,1,1000000},
  {"combo_balanced_proxy",false,true,0,0,0,0,0,0,true,true,0,100,0,1,10000},
  {"combo_proxy_no_skip",false,true,0,0,0,0,0,0,true,true,0,1000,0,1,0},
  {"combo_lex_no_prep",false,true,0,0,0,0,0,0,true,true,0,0,0,1,1000000},
  {"combo_lex_evalB",false,true,0,0,0,0,0,0,true,true,1,0,0,1,1000000},
  {"combo_blend_p010",false,true,0,0,0,0,0,0,true,true,1,.10,0,1,1000000},
  {"combo_blend_p025",false,true,0,0,0,0,0,0,true,true,1,.25,0,1,1000000},
  {"combo_blend_p050",false,true,0,0,0,0,0,0,true,true,1,.50,0,1,1000000},
  {"combo_blend_p100",false,true,0,0,0,0,0,0,true,true,1,1.0,0,1,1000000},
  {"combo_blend_p200",false,true,0,0,0,0,0,0,true,true,1,2.0,0,1,1000000},
  {"combo_blend_p500",false,true,0,0,0,0,0,0,true,true,1,5.0,0,1,1000000},
  {"combo_blend_p1000",false,true,0,0,0,0,0,0,true,true,1,10.0,0,1,1000000},
  {"combo_blend_p025_bal",false,true,0,0,0,0,0,0,true,true,1,.25,0,1,10000},
  {"combo_blend_p100_bal",false,true,0,0,0,0,0,0,true,true,1,1.0,0,1,10000}
 }; bool scoreOK=false;{int st=0,lp=0,bo=0;for(int cl:{1,1,2}){lp+=10*cl;st++;if(st>=2)bo+=10*st;}scoreOK=lp==40&&bo==50;}
 array<int,3>first=trays[0].p;cout<<"SELFTEST shapes="<<shapes.size()<<" trays="<<trays.size()<<" observations="<<expandedTrays.size()<<" emptySolvable="<<canComplete(0,first)<<" score="<<scoreOK<<" baseMove="<<BASE_MOVE_SEC<<" clearDelay="<<CLEAR_DELAY_SEC<<"\n";
 cout<<"strategy games meanScore p10Score medianScore p90Score scorePerMin meanMoves meanLines meanClear meanMaxCombo breaks rejects failed wallSec p10Combo medianCombo p90Combo\n";
 for(int si=0;si<(int)ss.size();si++){if(only>=0&&si!=only)continue;auto start=chrono::steady_clock::now();vector<double>scores,comboArr;double tscore=0,tm=0,tl=0,tc=0,tmax=0,tbreak=0,trej=0;int failed=0;for(int g=0;g<games;g++){Game x=play(ss[si],seed+g*0x9e3779b97f4a7c15ULL,duration,moveLimit);scores.push_back(x.score);comboArr.push_back(x.maxCombo);tscore+=x.score;tm+=x.moves;tl+=x.lines;tc+=x.clearMoves;tmax+=x.maxCombo;tbreak+=x.breaks;trej+=x.rejects;failed+=x.failed;}double wall=chrono::duration<double>(chrono::steady_clock::now()-start).count();cout<<fixed<<setprecision(2)<<ss[si].name<<" "<<games<<" "<<tscore/games<<" "<<quant(scores,.1)<<" "<<quant(scores,.5)<<" "<<quant(scores,.9)<<" "<<(tscore/games)/(duration/60)<<" "<<tm/games<<" "<<tl/games<<" "<<tc/games<<" "<<tmax/games<<" "<<tbreak/games<<" "<<trej/games<<" "<<failed<<" "<<wall<<" "<<quant(comboArr,.1)<<" "<<quant(comboArr,.5)<<" "<<quant(comboArr,.9)<<"\n";}
}
