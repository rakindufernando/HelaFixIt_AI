from __future__ import annotations

import csv
import json
import re
import sys
from pathlib import Path

import joblib

ROOT = Path(__file__).resolve().parents[1]
BACKEND = ROOT.parent / 'Backend'
if str(BACKEND) not in sys.path:
    sys.path.insert(0, str(BACKEND))
from services.language_service import detect_language
MODELS = ROOT / 'Models'
RULES = ROOT / 'Rules'
DATA = ROOT / 'Data' / 'validation_cases.csv'
OUTPUT = ROOT / 'Evaluation' / 'validation_case_results.csv'

vectorizer = joblib.load(MODELS / 'tfidf_vectorizer.joblib')
category_model = joblib.load(MODELS / 'category_model.joblib')
priority_model = joblib.load(MODELS / 'priority_model.joblib')
safety_rules = json.loads((RULES / 'safety_rules.json').read_text(encoding='utf-8'))
issue_rules = json.loads((RULES / 'issue_rules.json').read_text(encoding='utf-8'))

SINGLISH_MARKERS = {
    'eka','eke','eken','ekak','wenawa','wadinawa','waduna','naha','baha','ba','watura','vatura','galanawa','gannawa','ganawa',
    'gini','giniyak','duma','kamaraya','kamarayak','kamare','karanna','krnna','langa','langata','godak','ikmanata','balanna','balnna',
    'athule','hira','wela','thiyenawa','tiyenawa','enawa','yanawa','kadila','awul','panu','innawa','wahanna','arinne','cool','poddak','pitata',
    'danma','gandha','wenne','venne','yanna','pahala','bimata','watila','watuna','galawila','pupurala','rath','wage'
}
STRONG_SINGLISH = {'gini','giniyak','watura','vatura','kamarayak','kamare','thiyenawa','tiyenawa','wenawa','venawa','gannawa','ganawa','waduna','hira','bimata','pahala'}

def normalise(text: str) -> str:
    value=str(text or '').lower().replace('’', "'")
    value=re.sub(r'[^\w\u0D80-\u0DFF]+',' ',value,flags=re.UNICODE)
    return re.sub(r'\s+',' ',value).strip()

def term_present(normalised_text: str, term: str) -> bool:
    t=normalise(term)
    if not t:return False
    if ' ' in t:return t in normalised_text
    return bool(re.search(r'(?<!\w)'+re.escape(t)+r'(?!\w)',normalised_text,flags=re.UNICODE))

def match_rules(text: str):
    n=normalise(text)
    matches=[]
    for rule in safety_rules:
        terms=[str(x) for x in rule.get('terms',[]) if str(x).strip()]
        contexts=[str(x) for x in rule.get('context_terms',[]) if str(x).strip()]
        excludes=[str(x) for x in rule.get('exclude_terms',[]) if str(x).strip()]
        if any(term_present(n,t) for t in terms) and (not contexts or any(term_present(n,c) for c in contexts)) and not any(term_present(n,e) for e in excludes):
            matches.append(rule)
    return matches

def category_hint(text: str):
    n=normalise(text);scored=[]
    for category,cfg in issue_rules.items():
        matched=[t for t in cfg.get('terms',[]) if term_present(n,t)]
        if matched:
            score=float(cfg.get('weight') or 1)*len(matched)+sum(1.5 for t in matched if ' ' in normalise(t))
            scored.append((score,len(matched),category,matched))
    scored.sort(reverse=True)
    return scored[0] if scored else None

def apply_overrides(category, priority, text, matches, category_confidence=1.0):
    hint=category_hint(text)
    if hint:
        score,count,hint_category,matched=hint
        if hint_category != category and (category_confidence < 0.78 or score >= 8):
            category=hint_category
    rank={'Low':0,'Medium':1,'High':2,'Emergency':3}
    selected=priority
    best_cat=None;best_score=-1
    for rule in matches:
        p=rule.get('minimum_priority')
        if p and rank.get(p,0)>rank.get(selected,0):selected=p
        c=rule.get('category_override')
        score=float(rule.get('minimum_risk') or 0)+float(rule.get('weight') or 0)/100
        if c and score>best_score:best_cat=c;best_score=score
    if best_cat:category=best_cat
    codes={r['code'] for r in matches}
    if codes & {'FIRE','SMOKE'} and not best_cat:
        electrical=['socket','switch','wire','wiring','current','electrical','electric','breaker','panel','plug','power','විදුලි','සොකට්','ස්විච්']
        category='Electrical' if any(t in text.lower() for t in electrical) else 'Fire and Safety'
    return category,selected

def main():
    rows=list(csv.DictReader(DATA.open('r',encoding='utf-8-sig',newline='')))
    X=vectorizer.transform([r['ticket_text'] for r in rows])
    raw_categories=category_model.predict(X);raw_priorities=priority_model.predict(X)
    category_probabilities=category_model.predict_proba(X)
    results=[];passed=0
    for row,raw_cat,raw_pri,cat_probs in zip(rows,raw_categories,raw_priorities,category_probabilities):
        language=detect_language(row['ticket_text'])
        matches=match_rules(row['ticket_text'])
        category,priority=apply_overrides(str(raw_cat),str(raw_pri),row['ticket_text'],matches,float(max(cat_probs)))
        codes=[r['code'] for r in matches]
        priority_ok = {'Low':0,'Medium':1,'High':2,'Emergency':3}.get(priority, -1) >= {'Low':0,'Medium':1,'High':2,'Emergency':3}.get(row['expected_priority'], -1)
        expected_safety=(row.get('expected_safety') or 'NONE').strip()
        safety_ok=(not codes) if expected_safety=='NONE' else expected_safety in codes
        ok=(language==row['expected_language'] and category==row['expected_category'] and priority_ok and safety_ok)
        passed+=int(ok)
        results.append({**row,'predicted_language':language,'raw_category':str(raw_cat),'predicted_category':category,'raw_priority':str(raw_pri),'predicted_priority':priority,'detected_safety':'|'.join(codes) if codes else 'NONE','result':'PASS' if ok else 'CHECK'})
    OUTPUT.parent.mkdir(parents=True,exist_ok=True)
    with OUTPUT.open('w',encoding='utf-8-sig',newline='') as f:
        w=csv.DictWriter(f,fieldnames=results[0].keys());w.writeheader();w.writerows(results)
    total=len(results);rate=passed/total if total else 0
    summary=ROOT/'Evaluation'/'validation_summary.txt'
    summary.write_text(f'HelaFixIt AI focused safety validation\nPassed: {passed}/{total}\nPass rate: {rate:.1%}\n',encoding='utf-8')
    print(f'Validation cases passed: {passed}/{total} ({rate:.1%})')
    print(f'Results saved to: {OUTPUT}')
    if passed!=total:print('Review rows marked CHECK before final evaluation.')

if __name__=='__main__':main()
