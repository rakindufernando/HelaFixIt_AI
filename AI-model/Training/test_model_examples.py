from pathlib import Path
import json
import re
import joblib

ROOT = Path(__file__).resolve().parents[1]
MODELS = ROOT / 'Models'
RULES = ROOT / 'Rules'
vectorizer = joblib.load(MODELS / 'tfidf_vectorizer.joblib')
category_model = joblib.load(MODELS / 'category_model.joblib')
priority_model = joblib.load(MODELS / 'priority_model.joblib')
safety_rules = json.loads((RULES / 'safety_rules.json').read_text(encoding='utf-8'))

examples = [
    'kamarayak gini gannawa',
    'Socket eken spark wenawa saha burning smell ekak enawa',
    'pipe eka pupurala watura galanawa',
    'lift eka ida idan bimata kadan watila',
    'ac eken duma enawa',
    'drain eken sewage overflow wenawa',
    'chemical eka floor eke spill wela',
    'snake ekak common area eke innawa',
    'fire exit door eka jam wela arinne naha',
    'fire alarm eka wada naha',
]

def find_rules(text):
    lower=text.lower();out=[]
    for rule in safety_rules:
        terms=[str(x).lower() for x in rule.get('terms',[]) if str(x).strip()]
        contexts=[str(x).lower() for x in rule.get('context_terms',[]) if str(x).strip()]
        excludes=[str(x).lower() for x in rule.get('exclude_terms',[]) if str(x).strip()]
        if any(t in lower for t in terms) and (not contexts or any(c in lower for c in contexts)) and not any(e in lower for e in excludes):
            out.append(rule)
    return out

def final_decision(raw_category, raw_priority, matches, text):
    rank={'Low':0,'Medium':1,'High':2,'Emergency':3}
    category=str(raw_category);priority=str(raw_priority);best_cat=None;best=-1
    for rule in matches:
        p=rule.get('minimum_priority')
        if p and rank.get(p,0)>rank.get(priority,0):priority=p
        c=rule.get('category_override')
        score=float(rule.get('minimum_risk') or 0)+float(rule.get('weight') or 0)/100
        if c and score>best:best_cat=c;best=score
    if best_cat:category=best_cat
    codes={r['code'] for r in matches}
    if codes & {'FIRE','SMOKE'} and not best_cat:
        electrical=['socket','switch','wire','wiring','current','electrical','electric','breaker','panel','plug','power','විදුලි','සොකට්','ස්විච්']
        category='Electrical' if any(t in text.lower() for t in electrical) else 'Other'
    min_risk=max([float(r.get('minimum_risk') or 0) for r in matches] or [0])
    return category,priority,min_risk

X=vectorizer.transform(examples)
cat_pred=category_model.predict(X);pri_pred=priority_model.predict(X)
cat_prob=category_model.predict_proba(X).max(axis=1);pri_prob=priority_model.predict_proba(X).max(axis=1)
for text,raw_cat,raw_pri,c,p in zip(examples,cat_pred,pri_pred,cat_prob,pri_prob):
    matches=find_rules(text)
    final_cat,final_pri,min_risk=final_decision(raw_cat,raw_pri,matches,text)
    print('\nTEXT:',text)
    print('MODEL CATEGORY:',raw_cat,f'({c:.1%} confidence)')
    print('MODEL PRIORITY:',raw_pri,f'({p:.1%} confidence)')
    print('SAFETY RULES:',', '.join(r['code'] for r in matches) if matches else 'None')
    print('FINAL CATEGORY:',final_cat)
    print('FINAL PRIORITY:',final_pri)
    if min_risk:print('MINIMUM SAFETY RISK:',f'{min_risk:.0f}/100')
