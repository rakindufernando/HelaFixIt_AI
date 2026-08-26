import re
import unicodedata

EMAIL_RE = re.compile(r'^[A-Za-z0-9.!#$%&\'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$')
EMPLOYEE_CODE_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9_-]{1,49}$')
UNIT_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9 ./_-]{0,39}$')


def clean_text(value, max_length=None):
    value = (value or '').strip()
    if max_length is not None:
        value = value[:max_length]
    return value


def normalize_email(value):
    return clean_text(value, 190).lower()


def validate_email(value):
    value = normalize_email(value)
    return bool(value and len(value) <= 190 and EMAIL_RE.fullmatch(value))


def normalize_mobile(value):
    """Normalize common Sri Lankan mobile formats to +947XXXXXXXX."""
    raw = clean_text(value, 40)
    if not raw:
        return ''
    compact = re.sub(r'[\s().-]+', '', raw)
    if compact.startswith('0094'):
        compact = '+94' + compact[4:]
    elif compact.startswith('94') and not compact.startswith('+94'):
        compact = '+' + compact
    elif compact.startswith('0'):
        compact = '+94' + compact[1:]
    elif compact.startswith('7') and len(compact) == 9:
        compact = '+94' + compact
    return compact


def validate_mobile(value, required=False):
    normalized = normalize_mobile(value)
    if not normalized:
        return not required
    return bool(re.fullmatch(r'\+947\d{8}', normalized))


def validate_name(value):
    value = clean_text(value, 150)
    if len(value) < 2 or len(value) > 150:
        return False
    allowed_punctuation = {" ", "-", "'", "."}
    def is_name_character(ch):
        category = unicodedata.category(ch)
        return category.startswith('L') or category.startswith('M') or ch in allowed_punctuation
    if not any(unicodedata.category(ch).startswith('L') for ch in value):
        return False
    return all(is_name_character(ch) for ch in value)


def validate_password(value):
    if not value or len(value) < 8:
        return False, 'Password must contain at least 8 characters.'
    if len(value) > 64:
        return False, 'Password must not exceed 64 characters.'
    if not re.search(r'[A-Za-z]', value):
        return False, 'Password must contain at least one letter.'
    if not re.search(r'\d', value):
        return False, 'Password must contain at least one number.'
    return True, ''


def validate_unit_number(value):
    value = clean_text(value, 40)
    return not value or bool(UNIT_RE.fullmatch(value))


def validate_employee_code(value):
    value = clean_text(value, 50)
    return not value or bool(EMPLOYEE_CODE_RE.fullmatch(value))


def validate_plain_text(value, minimum=0, maximum=255):
    value = clean_text(value, maximum)
    if len(value) < minimum:
        return False
    return not any(ord(ch) < 32 and ch not in '\t\n\r' for ch in value)


def validate_int_range(value, minimum, maximum):
    try:
        number = int(value)
    except (TypeError, ValueError):
        return False
    return minimum <= number <= maximum
