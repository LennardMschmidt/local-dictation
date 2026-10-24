import json,sys,re,collections
# score.py <results.tsv> <refs.json> [<terms.json>] [-v]
# A terms entry is a list of phrases that must appear, or {"must": [...], "mustNot": [...]}.
refs=json.load(open(sys.argv[2])); terms=json.load(open(sys.argv[3])) if len(sys.argv)>3 and sys.argv[3]!='-v' else {}
def norm(t):
    # Writing variants that mean the same count as equal: 14:30 and 14.30, 12.000 and 12,000,
    # € and Euro, % and Prozent.
    t=t.lower().replace("tl;dv","tldv").replace("€"," euro ").replace("%"," prozent ")
    t=re.sub(r"(?<=\d):(?=\d)",".",t); t=re.sub(r"(?<=\d)[.,](?=\d{3}(?!\d))","",t)
    return re.findall(r"[a-zäöüß0-9]+(?:['.][a-zäöüß0-9]+)*",t)
def wer(r,h):
    r,h=norm(r),norm(h); d=list(range(len(h)+1))
    for i in range(1,len(r)+1):
        p=d[:]; d[0]=i
        for j in range(1,len(h)+1): d[j]=min(p[j]+1,d[j-1]+1,p[j-1]+(r[i-1]!=h[j-1]))
    return d[len(h)],len(r)
rows=collections.defaultdict(lambda:{'err':0,'words':0,'asr':0.0,'clean':0.0,'audio':0.0,'terms':0,'termsok':0,'bad':0,'n':0})
missed=collections.defaultdict(list)
out=collections.defaultdict(dict)
for line in open(sys.argv[1]):
    eng,js=line.rstrip('\n').split('\t',1); d=json.loads(js); f=d['file'].split('/')[-1]
    if f not in refs: continue
    for kind in ('raw','text'):
        e,n=wer(refs[f],d[kind]); r=rows[(eng,kind)]; r['err']+=e; r['words']+=n
        if kind=='text':
            entry=terms.get(f,[]); entry=entry if isinstance(entry,dict) else {'must':entry}
            for t in entry.get('must',[]):
                ok=t.lower() in d['text'].lower(); r['terms']+=1; r['termsok']+=ok
                if not ok: missed[(eng,f)].append(t)
            for t in entry.get('mustNot',[]):
                if re.search(r'(?<!\w)'+re.escape(t.lower())+r'(?!\w)',d['text'].lower()): r['bad']+=1; missed[(eng,f)].append('NOT '+t)
            r['clean']+=d.get('cleanup_seconds',0)
    r=rows[(eng,'raw')]; r['asr']+=d['transcription_seconds']; r['audio']+=d['audio_seconds']; r['n']+=1
    out[f][eng]=d['text']
print('%-22s %8s %8s %10s %9s %8s %8s'%('engine','WER raw','WER text','terms ok','forbidden','ASR s','clean s'))
for eng in sorted({k[0] for k in rows}):
    a=rows[(eng,'raw')]; b=rows[(eng,'text')]
    print('%-22s %7.1f%% %7.1f%% %10s %9d %8.1f %8.1f'%(eng,100*a['err']/max(1,a['words']),100*b['err']/max(1,b['words']),
        f"{b['termsok']}/{b['terms']}" if b['terms'] else '-', b['bad'], a['asr'], b['clean']))
if '-v' in sys.argv:
    for f in sorted(out):
        print('\n==',f,'|',refs[f][:90])
        for eng,t in sorted(out[f].items()):
            print('  %-20s %s'%(eng,t[:160].replace(chr(10),' / ')))
            if missed[(eng,f)]: print('  %-20s missing or forbidden: %s'%('',', '.join(missed[(eng,f)])))
