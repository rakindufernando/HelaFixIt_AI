from flask import jsonify


def success(data=None, message='Success', status=200):
    payload = {'success': True, 'message': message}
    if data is not None:
        payload['data'] = data
    return jsonify(payload), status


def error(message='Request failed', status=400, details=None):
    payload = {'success': False, 'message': message}
    if details is not None:
        payload['details'] = details
    return jsonify(payload), status
