from __future__ import annotations

import json

from database import query_one


def _row(key):
    return query_one(
        "SELECT setting_value,value_type FROM system_settings WHERE setting_key=%s LIMIT 1",
        (key,),
    )


def get_setting(key, default=None):
    row = _row(key)
    if not row:
        return default
    value = row.get('setting_value')
    value_type = row.get('value_type')
    try:
        if value_type == 'Boolean':
            return str(value).strip().lower() in {'1', 'true', 'yes', 'on'}
        if value_type == 'Integer':
            return int(value)
        if value_type == 'Decimal':
            return float(value)
        if value_type == 'JSON':
            return json.loads(value)
    except Exception:
        return default
    return value if value is not None else default


def get_bool_setting(key, default=False):
    value = get_setting(key, default)
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in {'1', 'true', 'yes', 'on'}


def get_int_setting(key, default=0, minimum=None, maximum=None):
    try:
        value = int(get_setting(key, default))
    except Exception:
        value = int(default)
    if minimum is not None:
        value = max(int(minimum), value)
    if maximum is not None:
        value = min(int(maximum), value)
    return value


def get_float_setting(key, default=0.0, minimum=None, maximum=None):
    try:
        value = float(get_setting(key, default))
    except Exception:
        value = float(default)
    if minimum is not None:
        value = max(float(minimum), value)
    if maximum is not None:
        value = min(float(maximum), value)
    return value


def get_string_setting(key, default=''):
    value = get_setting(key, default)
    return str(value if value is not None else default)


def allowed_image_extensions():
    raw = get_setting('allowed_image_types', 'jpg,jpeg,png,webp')
    if isinstance(raw, list):
        values = raw
    else:
        values = str(raw or '').split(',')
    allowed = {'jpg', 'jpeg', 'png', 'webp'}
    result = []
    for item in values:
        ext = str(item).strip().lower().lstrip('.')
        if ext in allowed and ext not in result:
            result.append(ext)
    return result or ['jpg', 'jpeg', 'png', 'webp']
