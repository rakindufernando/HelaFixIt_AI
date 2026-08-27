from __future__ import annotations

import json
import re
import time
from datetime import datetime
from pathlib import Path

import joblib
from flask import current_app
from sklearn.metrics.pairwise import cosine_similarity

from database import get_connection, query_all, query_one
from services.language_service import detect_language
from services.settings_service import get_bool_setting, get_float_setting, get_int_setting

_MODEL_CACHE = None
_CONFIG_CACHE = None


def _load_json(path: Path, fallback):
    try:
        with path.open('r', encoding='utf-8') as handle:
            return json.load(handle)
    except Exception:
        return fallback


def _paths():
    root = Path(current_app.config['AI_ROOT'])
    return {
        'root': root,
        'models': root / 'Models',
        'rules': root / 'Rules',
        'evaluation': root / 'Evaluation',
    }


def load_models(force=False):
    global _MODEL_CACHE
    if _MODEL_CACHE is not None and not force:
        return _MODEL_CACHE
    p = _paths()['models']
    required = {
        'vectorizer': p / 'tfidf_vectorizer.joblib',
        'category_model': p / 'category_model.joblib',
        'priority_model': p / 'priority_model.joblib',
        'metadata': p / 'model_metadata.json',
    }
    missing = [str(x) for x in required.values() if not x.exists()]
    if missing:
        raise FileNotFoundError('AI model files are missing. Run AI-model/Training/train_models.py first.')
    _MODEL_CACHE = {
        'vectorizer': joblib.load(required['vectorizer']),
        'category_model': joblib.load(required['category_model']),
        'priority_model': joblib.load(required['priority_model']),
        'metadata': _load_json(required['metadata'], {}),
    }
    return _MODEL_CACHE


def load_configs(force=False):
    global _CONFIG_CACHE
    if _CONFIG_CACHE is not None and not force:
        return _CONFIG_CACHE
    p = _paths()['rules']
    _CONFIG_CACHE = {
        'risk': _load_json(p / 'risk_config.json', {}),
        'technician': _load_json(p / 'technician_rules.json', {}),
        'fallback_safety': _load_json(p / 'safety_rules.json', []),
        'issue_rules': _load_json(p / 'issue_rules.json', {}),
    }
    return _CONFIG_CACHE


def ai_status():
    try:
        models = load_models()
        metadata = models.get('metadata', {})
        return {
            'ready': True,
            'bundle': metadata.get('bundle_name', 'HelaFixIt Ticket Decision Bundle'),
            'version': metadata.get('version', 'unknown'),
            'datasetRows': metadata.get('dataset_rows'),
            'categoryAccuracy': metadata.get('category_accuracy'),
            'categoryMacroF1': metadata.get('category_macro_f1'),
            'priorityAccuracy': metadata.get('priority_accuracy'),
            'priorityMacroF1': metadata.get('priority_macro_f1'),
            'languageRecognitionAccuracy': metadata.get('language_recognition_accuracy'),
            'languageRecognitionValidationRows': metadata.get('language_recognition_validation_rows'),
        }
    except Exception as exc:
        return {'ready': False, 'error': str(exc)}


def _compose_text(ticket):
    values = [ticket.get('subject'), ticket.get('description')]
    if ticket.get('area_name'):
        values.append(f"Area {ticket['area_name']}")
    if ticket.get('asset_type'):
        values.append(f"Asset {ticket['asset_type']}")
    return '. '.join(str(v).strip() for v in values if v and str(v).strip())


def predict_ticket_text(text):
    models = load_models()
    X = models['vectorizer'].transform([text])
    category_model = models['category_model']
    priority_model = models['priority_model']
    category = str(category_model.predict(X)[0])
    priority = str(priority_model.predict(X)[0])
    category_confidence = float(max(category_model.predict_proba(X)[0]))
    priority_confidence = float(max(priority_model.predict_proba(X)[0]))
    return {
        'category': category,
        'priority': priority,
        'category_confidence': category_confidence,
        'priority_confidence': priority_confidence,
    }




def _normalise_for_rules(text):
    value = str(text or '').lower().replace('’', "'")
    value = re.sub(r'[^\w\u0D80-\u0DFF]+', ' ', value, flags=re.UNICODE)
    return re.sub(r'\s+', ' ', value).strip()


def _term_present(normalised_text, term):
    term_norm = _normalise_for_rules(term)
    if not term_norm:
        return False
    # Multi-word phrases are matched as phrases. Single words are matched on token boundaries.
    if ' ' in term_norm:
        return term_norm in normalised_text
    return bool(re.search(r'(?<!\w)' + re.escape(term_norm) + r'(?!\w)', normalised_text, flags=re.UNICODE))


def category_rule_hint(text):
    """Return a transparent category hint from multilingual maintenance terms.

    The statistical model remains the main classifier. This rule score is used to correct
    obvious domain wording and low-confidence predictions while keeping the decision logic transparent.
    """
    normalised = _normalise_for_rules(text)
    scored = []
    for category, config in (load_configs().get('issue_rules') or {}).items():
        weight = float(config.get('weight') or 1)
        matched = []
        for term in config.get('terms', []):
            if _term_present(normalised, term):
                matched.append(str(term))
        if matched:
            phrase_bonus = sum(1.5 for term in matched if ' ' in _normalise_for_rules(term))
            score = weight * len(matched) + phrase_bonus
            scored.append({'category': category, 'score': score, 'matched_terms': matched})
    scored.sort(key=lambda item: (-item['score'], -len(item['matched_terms']), item['category']))
    if not scored:
        return None
    best = scored[0]
    second = scored[1]['score'] if len(scored) > 1 else 0
    best['margin'] = round(best['score'] - second, 2)
    return best


def apply_category_rule_hint(prediction, text):
    result = dict(prediction)
    hint = category_rule_hint(text)
    if not hint:
        return result
    model_conf = float(result.get('category_confidence') or 0)
    strong_hint = hint['score'] >= 8 or hint['margin'] >= 4
    if hint['category'] != result.get('category') and (model_conf < 0.78 or strong_hint):
        result.setdefault('override_reasons', []).append(
            f"domain category rule to {hint['category']} using {', '.join(hint['matched_terms'][:4])}"
        )
        result['category'] = hint['category']
        result['category_confidence'] = max(model_conf, 0.90 if strong_hint else 0.82)
    result['category_rule_hint'] = hint
    return result


def _safety_rules_from_database():
    try:
        return query_all(
            """
            SELECT sr.safety_rule_id, sr.rule_code, sr.keyword_or_pattern, sr.match_type, sr.language_type,
                   sr.score_weight, sr.severity, sr.warning_message, sr.resident_action,
                   ic.name AS category_name
            FROM safety_rules sr
            LEFT JOIN issue_categories ic ON ic.category_id=sr.category_id
            WHERE sr.active=TRUE
            ORDER BY sr.score_weight DESC, sr.safety_rule_id
            """
        )
    except Exception:
        return []


def detect_safety(text, language):
    lower = (text or '').lower()
    normalised = _normalise_for_rules(text)
    matches_by_code = {}

    # Database rules are checked first so administrators can maintain additional project rules.
    for rule in _safety_rules_from_database():
        rule_lang = rule.get('language_type') or 'Any'
        if rule_lang not in ('Any', language, 'Mixed') and language != 'Mixed':
            continue
        pattern = str(rule.get('keyword_or_pattern') or '').strip()
        if not pattern:
            continue
        try:
            if rule.get('match_type') == 'Regex':
                is_match = bool(re.search(pattern, text or '', flags=re.IGNORECASE))
            else:
                is_match = pattern.lower() in lower
        except re.error:
            is_match = pattern.lower() in lower
        if is_match:
            severity = rule.get('severity') or 'High'
            severity_defaults = {
                'Low': ('Low', 20),
                'Medium': ('Medium', 40),
                'High': ('High', 70),
                'Critical': ('Emergency', 90),
            }
            minimum_priority, minimum_risk = severity_defaults.get(severity, ('High', 70))
            item = {
                'code': rule['rule_code'],
                'weight': float(rule['score_weight']),
                'severity': severity,
                'warning': rule['warning_message'],
                'resident_action': rule.get('resident_action'),
                'minimum_priority': minimum_priority,
                'minimum_risk': minimum_risk,
                'category_override': rule.get('category_name'),
            }
            current = matches_by_code.get(item['code'])
            if current is None or item['weight'] > current['weight']:
                matches_by_code[item['code']] = item

    # Local multilingual rules cover the complete maintenance scope and add priority/risk safeguards.
    for rule in load_configs()['fallback_safety']:
        terms = [str(term).strip() for term in rule.get('terms', []) if str(term).strip()]
        context_terms = [str(term).strip() for term in rule.get('context_terms', []) if str(term).strip()]
        exclude_terms = [str(term).strip() for term in rule.get('exclude_terms', []) if str(term).strip()]
        term_match = any(_term_present(normalised, term) for term in terms)
        context_match = not context_terms or any(_term_present(normalised, term) for term in context_terms)
        excluded = any(_term_present(normalised, term) for term in exclude_terms)
        if term_match and context_match and not excluded:
            item = {
                'code': rule.get('code'),
                'weight': float(rule.get('weight', 0)),
                'severity': rule.get('severity', 'High'),
                'warning': rule.get('warning', ''),
                'resident_action': None,
                'minimum_priority': rule.get('minimum_priority'),
                'minimum_risk': rule.get('minimum_risk'),
                'category_override': rule.get('category_override'),
            }
            current = matches_by_code.get(item['code'])
            if current is None:
                matches_by_code[item['code']] = item
            else:
                # Keep the strongest weight but always retain the local safety safeguards.
                current['weight'] = max(float(current.get('weight', 0)), item['weight'])
                current['severity'] = item.get('severity') or current.get('severity')
                current['warning'] = item.get('warning') or current.get('warning')
                current['minimum_priority'] = item.get('minimum_priority')
                current['minimum_risk'] = item.get('minimum_risk')
                current['category_override'] = item.get('category_override')

    priority_rank = {'Low': 0, 'Medium': 1, 'High': 2, 'Emergency': 3}
    matched = sorted(
        matches_by_code.values(),
        key=lambda x: (priority_rank.get(x.get('minimum_priority'), -1), float(x.get('minimum_risk') or 0), float(x.get('weight') or 0)),
        reverse=True,
    )
    warning = None
    if matched:
        strongest = matched[0]
        warning = strongest['warning']
        if strongest.get('resident_action'):
            warning = f"{warning} {strongest['resident_action']}"
    return {
        'flag': bool(matched),
        'rules': matched,
        'warning': warning or 'No immediate safety hazard wording was detected. Continue to follow normal maintenance precautions.',
        'weight_total': sum(float(x.get('weight') or 0) for x in matched),
        'highest_severity': matched[0]['severity'] if matched else None,
    }


def apply_safety_overrides(prediction, safety, text):
    result = dict(prediction)
    reasons = list(result.get('override_reasons', []))
    priority_rank = {'Low': 0, 'Medium': 1, 'High': 2, 'Emergency': 3}

    # Every matched safety rule may define a minimum priority and a category correction.
    selected_priority = result.get('priority', 'Low')
    selected_category = None
    selected_category_score = -1.0
    for rule in safety.get('rules', []):
        minimum_priority = rule.get('minimum_priority')
        if minimum_priority and priority_rank.get(minimum_priority, 0) > priority_rank.get(selected_priority, 0):
            selected_priority = minimum_priority
        category_override = rule.get('category_override')
        category_score = float(rule.get('minimum_risk') or 0) + float(rule.get('weight') or 0) / 100.0
        if category_override and category_score > selected_category_score:
            selected_category = category_override
            selected_category_score = category_score

    if selected_priority != result.get('priority'):
        reasons.append(f'safety priority override to {selected_priority}')
        result['priority'] = selected_priority
        result['priority_confidence'] = max(float(result.get('priority_confidence', 0)), 0.97 if selected_priority == 'Emergency' else 0.93)

    if selected_category and selected_category != result.get('category'):
        reasons.append(f'safety category override to {selected_category}')
        result['category'] = selected_category
        result['category_confidence'] = max(float(result.get('category_confidence', 0)), 0.95)

    # General fire or smoke wording is handled as Fire and Safety unless a more specific
    # safety rule above already identified the originating maintenance system.
    codes = {item.get('code') for item in safety.get('rules', [])}
    if codes & {'FIRE', 'SMOKE'} and not selected_category:
        if result.get('category') != 'Fire and Safety':
            reasons.append('fire/smoke category override to Fire and Safety')
            result['category'] = 'Fire and Safety'
            result['category_confidence'] = max(float(result.get('category_confidence', 0)), 0.96)

    result['override_reasons'] = reasons
    return result



def apply_context_priority_rules(prediction, safety, text):
    result = dict(prediction)
    if safety.get('flag'):
        return result

    lower = (text or '').lower()
    low_cues = [
        'slow drip', 'poddak leak', 'slightly loose', 'display is dim', 'display eka dim',
        'routine sweeping', 'routine cleaning', 'notice board', 'minor issue', 'small number of',
        'one bulb is out', 'slightly weak', 'loose fitting', 'ලූස්', 'සුළු', 'පොඩි ලීක්', 'පිරිසිදු කරන්න ඕනේ'
    ]
    high_cues = [
        'main security door cannot be locked', 'main door lock eka kadila', 'cannot be locked',
        'heavy leak', 'large leak', 'water everywhere', 'several residents', 'worse quickly',
        'severe mechanical sound', 'large nest', 'infestation', 'may fall', 'broken glass',
        'large slippery spill', 'security risk', 'ප්‍රධාන දොර ලොක් කරන්න බැහැ', 'විශාල ලීක්'
    ]
    medium_cues = [
        'blocked', 'block wela', 'not flowing', 'yanne naha', 'not cooling', 'cool wenne naha',
        'many cockroaches', 'panu godak', 'පළිබෝධ', 'කැරපොත්ත', 'normal use', 'not working',
        'wada naha', 'cannot be used normally', 'door will not close', 'wahanna ba',
        'වැඩ කරන්නේ නැහැ', 'සිසිල් කරන්නේ නැහැ', 'බ්ලොක් වෙලා'
    ]

    selected = None
    if any(cue in lower for cue in high_cues):
        selected = 'High'
    elif any(cue in lower for cue in medium_cues):
        selected = 'Medium'
    elif any(cue in lower for cue in low_cues):
        selected = 'Low'

    if selected:
        result['priority'] = selected
        result['priority_confidence'] = max(float(result.get('priority_confidence', 0)), 0.90)
        result.setdefault('override_reasons', []).append(f'context priority rule to {selected}')
    elif result.get('priority') == 'Emergency':
        # An emergency prediction without recognised emergency wording is sent for high-priority review.
        result['priority'] = 'High'
        result['priority_confidence'] = min(float(result.get('priority_confidence', 0)), 0.70)
        result.setdefault('override_reasons', []).append('emergency prediction requires supporting safety context')

    return result

def _duplicate_check(ticket, text):
    models = load_models()
    risk_cfg = load_configs()['risk']
    threshold = get_float_setting('duplicate_similarity_threshold', risk_cfg.get('duplicate_threshold', 0.70), 0.0, 1.0)
    rows = query_all(
        """
        SELECT mt.ticket_id, mt.ticket_number, mt.subject, mt.description, mt.asset_type,
               mt.floor_id, mt.area_id, a.name AS area_name
        FROM maintenance_tickets mt
        LEFT JOIN areas a ON a.area_id=mt.area_id
        WHERE mt.ticket_id<>%s AND mt.building_id=%s
          AND mt.current_status NOT IN ('Resolved','Closed','Cancelled')
        ORDER BY mt.submitted_at DESC LIMIT 60
        """,
        (ticket['ticket_id'], ticket['building_id']),
    )
    if not rows:
        return {'flag': False, 'ticket_id': None, 'ticket_number': None, 'similarity': None, 'location_score': None}
    candidate_texts = [_compose_text(r) for r in rows]
    matrix = models['vectorizer'].transform([text] + candidate_texts)
    similarities = cosine_similarity(matrix[0:1], matrix[1:]).ravel()
    best = None
    for row, similarity in zip(rows, similarities):
        location_score = 0.0
        if row.get('floor_id') == ticket.get('floor_id'):
            location_score += 0.5
        if row.get('area_id') and row.get('area_id') == ticket.get('area_id'):
            location_score += 0.5
        adjusted = min(1.0, float(similarity) + (0.06 * location_score))
        if best is None or adjusted > best['similarity']:
            best = {
                'flag': adjusted >= threshold,
                'ticket_id': int(row['ticket_id']),
                'ticket_number': row['ticket_number'],
                'similarity': adjusted,
                'location_score': location_score,
            }
    return best or {'flag': False, 'ticket_id': None, 'ticket_number': None, 'similarity': None, 'location_score': None}


def _category_record(category_name):
    row = query_one(
        "SELECT category_id,name,default_skill_id,severity_weight FROM issue_categories WHERE name=%s AND active=TRUE LIMIT 1",
        (category_name,),
    )
    if row:
        return row
    return query_one(
        "SELECT category_id,name,default_skill_id,severity_weight FROM issue_categories WHERE name='Other' AND active=TRUE LIMIT 1"
    )


def _history_count(ticket, category_id):
    row = query_one(
        """
        SELECT COUNT(*) AS count_value FROM maintenance_tickets
        WHERE ticket_id<>%s AND building_id=%s AND current_category_id=%s
          AND (%s IS NULL OR area_id=%s)
          AND submitted_at >= DATE_SUB(NOW(), INTERVAL 90 DAY)
        """,
        (ticket['ticket_id'], ticket['building_id'], category_id, ticket.get('area_id'), ticket.get('area_id')),
    )
    return int(row['count_value'] or 0) if row else 0


def calculate_risk(priority, safety, category_row, ticket, duplicate, history_count):
    cfg = load_configs()['risk']
    score = float(cfg.get('priority_base', {}).get(priority, 20))
    factors = [{'factor': 'Predicted priority', 'value': priority, 'points': score}]

    safety_points = min(float(cfg.get('safety_cap', 24)), safety['weight_total'] * float(cfg.get('safety_multiplier', 0.55)))
    if safety_points:
        score += safety_points
        factors.append({'factor': 'Safety hazard wording', 'value': [x['code'] for x in safety['rules']], 'points': round(safety_points, 2)})

    category_points = min(float(cfg.get('category_cap', 8)), float(category_row.get('severity_weight') or 0) * float(cfg.get('category_multiplier', 0.35)))
    score += category_points
    factors.append({'factor': 'Issue category severity', 'value': category_row.get('name'), 'points': round(category_points, 2)})

    location_text = ' '.join(str(x or '') for x in [ticket.get('area_name'), ticket.get('floor_name')]).lower()
    location_points = 0.0
    location_reason = None
    for key, value in cfg.get('location_weights', {}).items():
        if key.lower() in location_text and float(value) > location_points:
            location_points = float(value)
            location_reason = key
    if location_points:
        score += location_points
        factors.append({'factor': 'Location context', 'value': location_reason, 'points': location_points})

    duplicate_points = 0.0
    if duplicate.get('flag') and duplicate.get('similarity') is not None:
        for threshold_text, points in sorted(cfg.get('duplicate_weights', {}).items(), key=lambda x: float(x[0]), reverse=True):
            if duplicate['similarity'] >= float(threshold_text):
                duplicate_points = float(points)
                break
        if duplicate_points:
            score += duplicate_points
            factors.append({'factor': 'Similar active ticket', 'value': duplicate.get('ticket_number'), 'points': duplicate_points})

    history_points = min(float(cfg.get('history_cap', 5)), history_count * float(cfg.get('history_per_ticket', 1.5)))
    if history_points:
        score += history_points
        factors.append({'factor': 'Recent similar issue history', 'value': history_count, 'points': round(history_points, 2)})

    now = datetime.now()
    if safety['flag'] and (now.hour >= 19 or now.hour < 7):
        points = float(cfg.get('after_hours_safety_bonus', 4))
        score += points
        factors.append({'factor': 'After-hours safety context', 'value': now.strftime('%H:%M'), 'points': points})
    if safety['flag'] and now.weekday() >= 5:
        points = float(cfg.get('weekend_safety_bonus', 3))
        score += points
        factors.append({'factor': 'Weekend safety context', 'value': now.strftime('%A'), 'points': points})

    # Apply the strongest rule-specific minimum risk after the normal weighted score.
    minimum_risk = 0.0
    minimum_codes = []
    for rule in safety.get('rules', []):
        value = float(rule.get('minimum_risk') or 0)
        if value > minimum_risk:
            minimum_risk = value
            minimum_codes = [rule.get('code')]
        elif value and value == minimum_risk:
            minimum_codes.append(rule.get('code'))
    if minimum_risk and score < minimum_risk:
        factors.append({'factor': 'Safety minimum', 'value': sorted(set(minimum_codes)), 'points': round(minimum_risk - score, 2)})
        score = minimum_risk

    score = max(0.0, min(100.0, round(score, 2)))
    medium_threshold = get_int_setting('medium_risk_threshold', 31, 1, 100)
    high_threshold = get_int_setting('high_risk_threshold', 61, medium_threshold, 100)
    emergency_threshold = get_int_setting('emergency_risk_threshold', 86, high_threshold, 100)
    if score < medium_threshold:
        level = 'Low'
    elif score < high_threshold:
        level = 'Medium'
    elif score < emergency_threshold:
        level = 'High'
    else:
        level = 'Critical'
    return score, level, factors


def recommend_technician(ticket, category_id, emergency=False):
    """Return the best suitable technician for a category.

    The selection is intentionally simple and explainable. It uses verified category skill
    mappings, technician availability, remaining capacity, same-building preference, rating
    and emergency eligibility. Emergency tickets first look for an available emergency
    technician, then a busy emergency technician who still has capacity.
    """
    if not category_id:
        return None

    sql = """
        SELECT tp.technician_id,tp.user_id,tp.availability,tp.current_workload,tp.max_active_jobs,
               tp.emergency_eligible,tp.assigned_building_id,tp.rating,u.full_name,
               s.skill_id,s.skill_name,csm.match_weight,csm.is_primary,ts.skill_level
        FROM category_skill_mappings csm
        INNER JOIN skills s ON s.skill_id=csm.skill_id AND s.active=TRUE
        INNER JOIN technician_skills ts ON ts.skill_id=csm.skill_id AND ts.verified=TRUE
        INNER JOIN technician_profiles tp ON tp.technician_id=ts.technician_id
        INNER JOIN users u ON u.user_id=tp.user_id
        WHERE csm.category_id=%s AND csm.active=TRUE
          AND tp.active=TRUE AND u.account_status='Active'
          AND tp.availability NOT IN ('Off Duty','On Leave')
          AND tp.current_workload < tp.max_active_jobs
    """
    rows = query_all(sql, (category_id,))
    if not rows:
        return None

    weights = load_configs()['technician'].get('score_weights', {})
    level_points = {'Basic': 0.80, 'Intermediate': 0.90, 'Advanced': 1.00, 'Expert': 1.05}
    ranked = []
    for row in rows:
        # Emergency work must only go to technicians approved for emergency response.
        if emergency and not row.get('emergency_eligible'):
            continue
        mapping_strength = max(0.0, min(1.0, float(row.get('match_weight') or 0) / 100.0))
        skill_component = float(weights.get('skill_match', 45)) * mapping_strength * level_points.get(row.get('skill_level'), 0.90)
        score = skill_component
        availability_score = float(weights.get('available', 20))
        if row['availability'] == 'Available':
            score += availability_score
        elif row['availability'] == 'Busy':
            score += availability_score * (0.30 if emergency else 0.35)
        load_ratio = float(row['current_workload']) / max(1.0, float(row['max_active_jobs']))
        score += float(weights.get('workload', 15)) * max(0.0, 1.0 - load_ratio)
        if row.get('assigned_building_id') == ticket.get('building_id'):
            score += float(weights.get('same_building', 8))
        rating = float(row.get('rating') or 0)
        score += float(weights.get('rating', 7)) * min(1.0, rating / 5.0)
        if row.get('emergency_eligible'):
            score += float(weights.get('emergency_eligible', 5))
        if row.get('is_primary'):
            score += 3.0
        ranked.append({
            'technician_id': int(row['technician_id']),
            'user_id': int(row['user_id']),
            'name': row['full_name'],
            'skill_id': int(row['skill_id']),
            'skill_name': row['skill_name'],
            'score': round(min(100.0, score), 2),
            'availability': row['availability'],
            'workload': int(row['current_workload']),
            'max_jobs': int(row['max_active_jobs']),
            'emergency_eligible': bool(row.get('emergency_eligible')),
            'primary_skill': bool(row.get('is_primary')),
        })
    if not ranked:
        return None

    # For emergency tickets, an available technician is preferred. A busy technician with
    # remaining capacity is used only when no suitable available technician exists.
    if emergency:
        available = [item for item in ranked if item['availability'] == 'Available']
        pool = available if available else [item for item in ranked if item['availability'] == 'Busy']
    else:
        pool = ranked
    if not pool:
        return None
    pool.sort(key=lambda x: (-x['score'], x['workload'], 0 if x['availability']=='Available' else 1, x['name']))
    return pool[0]

def _ensure_model_version(connection, metadata):
    metrics = {
        'category_accuracy': metadata.get('category_accuracy'),
        'category_macro_f1': metadata.get('category_macro_f1'),
        'priority_accuracy': metadata.get('priority_accuracy'),
        'priority_macro_f1': metadata.get('priority_macro_f1'),
        'dataset_rows': metadata.get('dataset_rows'),
    }
    labels = {
        'categories': metadata.get('category_labels', []),
        'priorities': metadata.get('priority_labels', []),
    }
    name = metadata.get('bundle_name', 'HelaFixIt Ticket Decision Bundle')
    version = metadata.get('version', '1.0.0')
    with connection.cursor() as cursor:
        cursor.execute("UPDATE model_versions SET is_active=FALSE WHERE model_name=%s", (name,))
        cursor.execute(
            """
            INSERT INTO model_versions(model_name,version,artifact_path,metrics_json,label_mapping_json,
                                       training_data_version,notes,is_active)
            VALUES(%s,%s,'../AI-model/Models/',%s,%s,%s,%s,TRUE)
            ON DUPLICATE KEY UPDATE artifact_path=VALUES(artifact_path),metrics_json=VALUES(metrics_json),
                label_mapping_json=VALUES(label_mapping_json),training_data_version=VALUES(training_data_version),
                notes=VALUES(notes),is_active=TRUE
            """,
            (name, version, json.dumps(metrics), json.dumps(labels), metadata.get('training_data_version'),
             'Locally trained TF-IDF and Logistic Regression models used by the Flask application.'),
        )
        cursor.execute("SELECT model_version_id FROM model_versions WHERE model_name=%s AND version=%s LIMIT 1", (name, version))
        return int(cursor.fetchone()['model_version_id'])


def analyse_ticket(ticket_id, initiated_by=None, ip_address=None, user_agent=None):
    start = time.perf_counter()
    ticket = query_one(
        """
        SELECT mt.*,b.complex_id,b.block_code,f.name AS floor_name,a.name AS area_name,
               rp.user_id AS resident_user_id
        FROM maintenance_tickets mt
        INNER JOIN buildings b ON b.building_id=mt.building_id
        INNER JOIN floors f ON f.floor_id=mt.floor_id
        LEFT JOIN areas a ON a.area_id=mt.area_id
        INNER JOIN resident_profiles rp ON rp.resident_id=mt.resident_id
        WHERE mt.ticket_id=%s LIMIT 1
        """,
        (ticket_id,),
    )
    if not ticket:
        return None, 'Ticket not found.'

    text = _compose_text(ticket)
    prediction = predict_ticket_text(text)
    prediction = apply_category_rule_hint(prediction, text)
    language = detect_language(text)
    safety = detect_safety(text, language)
    prediction = apply_safety_overrides(prediction, safety, text)
    prediction = apply_context_priority_rules(prediction, safety, text)
    category = _category_record(prediction['category'])
    duplicate = _duplicate_check(ticket, text)
    history_count = _history_count(ticket, category['category_id'])
    risk_score, risk_level, risk_factors = calculate_risk(
        prediction['priority'], safety, category, ticket, duplicate, history_count
    )
    cfg = load_configs()['risk']
    manual_threshold = get_float_setting('low_confidence_threshold', cfg.get('manual_review_confidence', 0.58), 0.0, 1.0)
    manual_review = prediction['category_confidence'] < manual_threshold or prediction['priority_confidence'] < manual_threshold or safety['flag']
    auto_enabled = get_bool_setting('auto_emergency_assignment', True)
    emergency_condition = prediction['priority'] in cfg.get('auto_assignment_priorities', ['Emergency']) or risk_level in cfg.get('auto_assignment_risk_levels', ['Critical'])
    auto_required = bool(auto_enabled and emergency_condition)
    recommendation = recommend_technician(ticket, category.get('category_id'), emergency=emergency_condition)
    processing_ms = int((time.perf_counter() - start) * 1000)
    metadata = load_models()['metadata']

    connection = get_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute("SELECT current_status,ticket_number FROM maintenance_tickets WHERE ticket_id=%s FOR UPDATE", (ticket_id,))
            locked = cursor.fetchone()
            if not locked:
                connection.rollback(); return None, 'Ticket not found.'
            old_status = locked['current_status']
            model_version_id = _ensure_model_version(connection, metadata)
            cursor.execute("UPDATE ai_predictions SET is_current=FALSE WHERE ticket_id=%s AND is_current=TRUE", (ticket_id,))
            cursor.execute(
                """
                INSERT INTO ai_predictions(
                    ticket_id,model_version_id,predicted_category_id,category_confidence,predicted_priority,
                    priority_confidence,risk_score,risk_level,risk_factors,safety_flag,safety_warning,
                    safety_trigger_codes,duplicate_flag,duplicate_ticket_id,duplicate_similarity,recommended_skill_id,
                    recommended_technician_id,technician_score,auto_assignment_required,manual_review_required,
                    review_status,is_current,rule_version,processing_time_ms
                ) VALUES(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,TRUE,%s,%s)
                """,
                (
                    ticket_id, model_version_id, category['category_id'], prediction['category_confidence'], prediction['priority'],
                    prediction['priority_confidence'], risk_score, risk_level, json.dumps(risk_factors), safety['flag'], safety['warning'],
                    json.dumps([x['code'] for x in safety['rules']]), duplicate['flag'], duplicate.get('ticket_id') if duplicate.get('flag') else None,
                    duplicate.get('similarity') if duplicate.get('flag') else None, recommendation.get('skill_id') if recommendation else category.get('default_skill_id'),
                    recommendation.get('technician_id') if recommendation else None, recommendation.get('score') if recommendation else None,
                    auto_required, manual_review, 'Auto Accepted' if auto_required and not manual_review else 'Pending',
                    cfg.get('version', '1.0.0'), processing_ms,
                ),
            )
            prediction_id = cursor.lastrowid

            if duplicate.get('flag'):
                cursor.execute("DELETE FROM duplicate_matches WHERE source_ticket_id=%s AND match_status='Pending'", (ticket_id,))
                cursor.execute(
                    """
                    INSERT INTO duplicate_matches(source_ticket_id,matched_ticket_id,similarity_score,location_match_score,match_status)
                    VALUES(%s,%s,%s,%s,'Pending')
                    ON DUPLICATE KEY UPDATE similarity_score=VALUES(similarity_score),location_match_score=VALUES(location_match_score),
                        match_status='Pending',reviewed_by=NULL,review_notes=NULL,reviewed_at=NULL
                    """,
                    (ticket_id, duplicate['ticket_id'], duplicate['similarity'], duplicate.get('location_score')),
                )

            protected_statuses = {'Assigned','Accepted','In Progress','On Hold','Resolved','Closed','Cancelled'}
            new_status = old_status if old_status in protected_statuses else 'Awaiting Review'
            assigned_name = None
            cursor.execute(
                """
                SELECT ta.assignment_id,tu.full_name AS technician_name
                FROM ticket_assignments ta
                INNER JOIN technician_profiles tp ON tp.technician_id=ta.technician_id
                INNER JOIN users tu ON tu.user_id=tp.user_id
                WHERE ta.ticket_id=%s AND ta.is_current=TRUE LIMIT 1
                """,
                (ticket_id,),
            )
            existing_assignment = cursor.fetchone()
            if existing_assignment:
                assigned_name = existing_assignment['technician_name']

            if auto_required and not existing_assignment and old_status not in protected_statuses:
                if recommendation:
                    cursor.execute(
                        """
                        INSERT INTO ticket_assignments(ticket_id,technician_id,prediction_id,assignment_method,assigned_by,
                                                       assignment_status,assignment_score,assignment_reason,is_current)
                        VALUES(%s,%s,%s,'Auto Emergency',NULL,'Assigned',%s,%s,TRUE)
                        """,
                        (ticket_id, recommendation['technician_id'], prediction_id, recommendation['score'],
                         'Automatic emergency assignment based on required skill, availability, workload and emergency eligibility.'),
                    )
                    new_status = 'Auto Assigned'
                    assigned_name = recommendation['name']
                    cursor.execute(
                        """
                        INSERT INTO notifications(user_id,ticket_id,event_type,channel,title,message,delivery_status)
                        VALUES(%s,%s,'Emergency Assignment','In App','Emergency maintenance job',%s,'Delivered')
                        """,
                        (recommendation['user_id'], ticket_id, f"{locked['ticket_number']} was automatically assigned to you as an emergency job."),
                    )
                else:
                    new_status = 'Urgent Unassigned'

            cursor.execute(
                """
                UPDATE maintenance_tickets
                SET language_type=%s,current_category_id=%s,current_priority=%s,current_risk_score=%s,
                    current_risk_level=%s,current_status=%s,safety_flag=%s,duplicate_flag=%s,
                    manual_review_required=%s,analysed_at=NOW()
                WHERE ticket_id=%s
                """,
                (language, category['category_id'], prediction['priority'], risk_score, risk_level, new_status,
                 safety['flag'], duplicate['flag'], manual_review, ticket_id),
            )
            note = f"Local AI analysis completed. Category {category['name']}, priority {prediction['priority']}, risk {risk_score}/100 ({risk_level})."
            if assigned_name and not existing_assignment:
                note += f" Emergency auto assignment selected {assigned_name}."
            elif existing_assignment:
                note += f" Existing assignment to {assigned_name} was preserved."
            elif auto_required:
                note += ' No suitable emergency technician was available, so the apartment admin was alerted.'
            cursor.execute(
                """
                INSERT INTO ticket_updates(ticket_id,updated_by,update_type,status_from,status_to,note,resident_visible)
                VALUES(%s,%s,'AI Analysis',%s,%s,%s,TRUE)
                """,
                (ticket_id, initiated_by, old_status, new_status, note[:2000]),
            )
            cursor.execute(
                """
                INSERT INTO notifications(user_id,ticket_id,event_type,channel,title,message,delivery_status)
                VALUES(%s,%s,'AI Analysis','In App','Ticket analysis completed',%s,'Delivered')
                """,
                (ticket['resident_user_id'], ticket_id,
                 f"{locked['ticket_number']} was analysed as {category['name']} with {prediction['priority']} priority and risk {risk_score}/100."),
            )
            cursor.execute(
                """
                SELECT DISTINCT u.user_id
                FROM users u
                INNER JOIN roles r ON r.role_id=u.role_id
                INNER JOIN apartment_admin_profiles ap ON ap.user_id=u.user_id
                WHERE u.complex_id=%s
                  AND r.role_code='apartment_admin'
                  AND u.account_status='Active'
                  AND ap.active=TRUE
                  AND ap.primary_building_id=%s
                """,
                (ticket['complex_id'], ticket['building_id']),
            )
            for admin in cursor.fetchall():
                title = 'Emergency ticket requires attention' if auto_required else 'AI ticket review ready'
                message = f"{locked['ticket_number']} analysed as {category['name']} / {prediction['priority']} / risk {risk_score}."
                if assigned_name:
                    message += f" Auto assigned to {assigned_name}."
                elif auto_required:
                    message += ' No emergency technician was available.'
                cursor.execute(
                    """
                    INSERT INTO notifications(user_id,ticket_id,event_type,channel,title,message,delivery_status)
                    VALUES(%s,%s,%s,'In App',%s,%s,'Delivered')
                    """,
                    (admin['user_id'], ticket_id, 'Emergency AI Analysis' if auto_required else 'AI Analysis', title, message[:1000]),
                )
            cursor.execute(
                """
                INSERT INTO audit_logs(user_id,action_type,entity_type,entity_id,new_value,reason,ip_address,user_agent)
                VALUES(%s,'AI Analysis','maintenance_tickets',%s,%s,%s,%s,%s)
                """,
                (initiated_by, str(ticket_id), json.dumps({
                    'category': category['name'], 'priority': prediction['priority'], 'risk_score': risk_score,
                    'risk_level': risk_level, 'duplicate': duplicate.get('ticket_number') if duplicate.get('flag') else None,
                    'recommended_technician': recommendation.get('technician_id') if recommendation else None,
                    'auto_assignment': auto_required,
                }), 'Local HelaFixIt AI ticket decision process.', (ip_address or '')[:45], (user_agent or '')[:500]),
            )
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()

    return {
        'ticket_id': int(ticket_id),
        'ticket_number': locked['ticket_number'],
        'category': category['name'],
        'priority': prediction['priority'],
        'category_confidence': round(prediction['category_confidence'], 5),
        'priority_confidence': round(prediction['priority_confidence'], 5),
        'risk_score': risk_score,
        'risk_level': risk_level,
        'language': language,
        'safety_flag': safety['flag'],
        'safety_warning': safety['warning'],
        'duplicate': duplicate,
        'recommended_technician': recommendation,
        'auto_assignment_required': auto_required,
        'status': new_status,
        'processing_time_ms': processing_ms,
    }, None


def analyse_ticket_number(ticket_number, initiated_by=None, ip_address=None, user_agent=None):
    row = query_one("SELECT ticket_id FROM maintenance_tickets WHERE ticket_number=%s LIMIT 1", (ticket_number,))
    if not row:
        return None, 'Ticket not found.'
    return analyse_ticket(int(row['ticket_id']), initiated_by, ip_address, user_agent)
