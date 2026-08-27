from __future__ import annotations

import re

# Simple rule-based language recognition used before the maintenance prediction stage.
# The rules focus on the four language styles supported by HelaFixIt AI.

SINHALA_RE = re.compile(r'[\u0D80-\u0DFF]')
LATIN_RE = re.compile(r'[A-Za-z]')

SINGLISH_CORE = {
    'eka', 'eke', 'eken', 'ekak', 'meka', 'meke', 'mekak', 'oyage', 'ape', 'mage',
    'wenawa', 'wenne', 'venawa', 'venne', 'thiyenawa', 'tiyenawa', 'thiyenne', 'tiyenne',
    'enawa', 'enne', 'yanawa', 'yanne', 'gannawa', 'ganawa', 'karanna', 'karanne',
    'balanna', 'balnna', 'danna', 'denna', 'kiyanna', 'hadanna', 'hadanawa', 'wada',
    'naha', 'na', 'baha', 'ba', 'puluwan', 'ikmanata', 'danma', 'poddak', 'godak',
    'watura', 'vatura', 'gini', 'giniyak', 'duma', 'gandha', 'kamaraya', 'kamarayak', 'kamare',
    'gedara', 'athule', 'pitata', 'langa', 'langata', 'uda', 'yata', 'hira', 'wela', 'kadila',
    'awul', 'panu', 'innawa', 'inna', 'wahanna', 'arinne', 'galanawa', 'galan', 'current',
    'karant', 'rath', 'unu', 'wage', 'nisa', 'namuth', 'habai', 'passe', 'idan', 'indala',
    'hawasa', 'ude', 'raa', 'ara', 'me', 'oya', 'ekaata', 'ekata', 'tika', 'tikak',
    'hari', 'kenek', 'ewanna', 'adui', 'kara', 'alladdi', 'lamayek', 'loku', 'aluth',
    'bimata', 'pahala', 'watila', 'watuna', 'pupurala', 'galawila', 'rath', 'unu', 'krnna',
    'kamarekin', 'kamarayen', 'kamaren', 'room eken', 'ekakin', 'ekata', 'ekin', 'langin', 'langata',
    'gandhak', 'gandak', 'gandhai', 'danne', 'penawa', 'pennawa', 'ahanawa', 'danenawa', 'danuna',
    'watenna', 'naginawa', 'pirila', 'gihin', 'giyama', 'wadinawa', 'wadinne', 'ayeth', 'aye',
}

# Multi-word patterns have stronger value because they represent Singlish grammar rather than a single borrowed word.
SINGLISH_PHRASES = {
    'wada naha': 4,
    'wada na': 4,
    'wenne naha': 4,
    'venne naha': 4,
    'thiyenawa': 3,
    'tiyenawa': 3,
    'hira wela': 4,
    'kadila wage': 3,
    'gini gannawa': 5,
    'gini ganawa': 5,
    'watura leak': 4,
    'vatura leak': 4,
    'leak wenawa': 4,
    'leak venawa': 4,
    'block wela': 4,
    'stuck wela': 4,
    'cool wenne': 4,
    'cool venne': 4,
    'spark wenawa': 4,
    'spark venawa': 4,
    'smell ekak': 3,
    'sound ekak': 3,
    'issue ekak': 3,
    'problem ekak': 3,
    'ikmanata balanna': 4,
    'danma balanna': 4,
    'check karanna': 3,
    'repair karanna': 3,
    'open wenne': 3,
    'close wenne': 3,
    'wahanna ba': 4,
    'arinne naha': 4,
    'current waduna': 5,
    'current wadinawa': 5,
    'panu godak': 4,
    'watura galanawa': 4,
    'vatura galanawa': 4,
    'bimata watila': 4,
    'pahala watuna': 4,
    'control nathi': 4,
    'pupurala watura': 4,
    'godak rath': 3,
    'kamarekin smoke': 5,
    'kamarayen smoke': 5,
    'smoke smell ekak': 5,
    'gas smell ekak': 5,
    'burning smell ekak': 5,
    'watura enawa': 3,
    'water enawa': 3,
    'galawila loose': 3,
    'watenna wage': 4,
}


# English grammar words are used to distinguish a full English sentence from a Singlish sentence that contains English technical nouns.
ENGLISH_GRAMMAR = {
    'the', 'is', 'are', 'was', 'were', 'has', 'have', 'had', 'there', 'this', 'that', 'these',
    'those', 'please', 'can', 'could', 'would', 'should', 'from', 'near', 'inside', 'outside',
    'under', 'above', 'between', 'because', 'when', 'while', 'after', 'before', 'since', 'for',
    'with', 'without', 'and', 'but', 'not', 'does', 'do', 'did', 'cannot', 'needs', 'need',
    'today', 'yesterday', 'immediately',
}

SINGLISH_SUFFIX_PATTERNS = [
    r'\b\w+(?:wenawa|venawa|gannawa|ganawa|karanawa|karanna|karanne|thiyenawa|tiyenawa)\b',
    r'\b\w+(?:wela|wage|nisa|passe|idan)\b',
]


def _normalise_latin(text: str) -> str:
    value = text.lower()
    value = re.sub(r"[^a-z0-9\s']", ' ', value)
    value = re.sub(r'\s+', ' ', value).strip()
    return value


def detect_language_details(text: str) -> dict:
    value = str(text or '').strip()
    if not value:
        return {'language': 'English', 'singlish_score': 0, 'english_score': 0, 'reason': 'empty text'}

    sinhala_chars = len(SINHALA_RE.findall(value))
    latin_chars = len(LATIN_RE.findall(value))

    if sinhala_chars and latin_chars:
        latin_tokens = re.findall(r'[A-Za-z]+', value.lower())
        neutral_tokens = {'a', 'b', 'c', 'd'}
        meaningful_latin = [token for token in latin_tokens if token not in neutral_tokens]
        if not meaningful_latin:
            return {
                'language': 'Sinhala',
                'singlish_score': 0,
                'english_score': 0,
                'reason': 'Sinhala text with only a building block identifier in Latin script',
            }
        return {
            'language': 'Mixed',
            'singlish_score': 0,
            'english_score': 0,
            'reason': 'Sinhala and meaningful Latin wording are both present',
        }
    if sinhala_chars:
        return {
            'language': 'Sinhala',
            'singlish_score': 0,
            'english_score': 0,
            'reason': 'Sinhala script is present without Latin text',
        }

    lower = _normalise_latin(value)
    tokens = lower.split()
    token_set = set(tokens)

    singlish_score = 0
    core_hits = token_set & SINGLISH_CORE
    for token in core_hits:
        if token in {'me', 'one', 'current'}:
            singlish_score += 1
        elif token in {'eka', 'eke', 'eken', 'ekak', 'meka', 'watura', 'vatura', 'wenawa', 'venawa', 'thiyenawa', 'tiyenawa'}:
            singlish_score += 3
        else:
            singlish_score += 2

    phrase_hits = []
    for phrase, weight in SINGLISH_PHRASES.items():
        if phrase in lower:
            singlish_score += weight
            phrase_hits.append(phrase)

    for pattern in SINGLISH_SUFFIX_PATTERNS:
        if re.search(pattern, lower):
            singlish_score += 2

    english_hits = token_set & ENGLISH_GRAMMAR
    english_score = len(english_hits) * 2

    # Strong English sentence structure adds a small extra score.
    if re.search(r'\b(the|this|there|please)\b.*\b(is|are|has|have|needs|need|cannot|does|not)\b', lower):
        english_score += 3

    # Latin-only mixed wording is recognised when both English sentence structure and Singlish grammar are strong.
    if singlish_score >= 4 and english_score >= 4 and len(english_hits) >= 2:
        language = 'Mixed'
        reason = 'English sentence structure and Singlish grammar are both present'
    elif singlish_score >= 4 or (singlish_score >= 3 and bool(token_set & {'eka', 'eke', 'eken', 'ekak', 'meka'})):
        language = 'Singlish'
        reason = 'Singlish grammar or transliterated Sinhala markers are present'
    elif singlish_score >= 2 and len(core_hits) >= 2:
        language = 'Singlish'
        reason = 'Multiple Singlish markers are present'
    else:
        language = 'English'
        reason = 'No strong Sinhala or Singlish pattern was detected'

    return {
        'language': language,
        'singlish_score': singlish_score,
        'english_score': english_score,
        'reason': reason,
        'singlish_markers': sorted(core_hits),
        'singlish_phrases': phrase_hits,
        'english_markers': sorted(english_hits),
    }


def detect_language(text: str) -> str:
    return detect_language_details(text)['language']
