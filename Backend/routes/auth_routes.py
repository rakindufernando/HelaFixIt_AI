from flask import Blueprint, request
from flask_jwt_extended import create_access_token, get_jwt, get_jwt_identity, jwt_required

from database import get_connection, query_one
from services.settings_service import get_bool_setting, get_int_setting, get_string_setting
from services.auth_service import create_password_reset, get_user_profile, update_basic_profile
from services.temporary_password_service import authenticate, change_password, has_active_temporary_password
from services.registration_service import get_registration_status, registration_options, submit_registration_request
from utils.responses import error, success

auth_bp = Blueprint('auth', __name__, url_prefix='/api/auth')


def client_ip():
    forwarded = request.headers.get('X-Forwarded-For', '')
    return (forwarded.split(',')[0].strip() if forwarded else (request.remote_addr or ''))[:45]


@auth_bp.post('/login')
def login():
    payload = request.get_json(silent=True) or {}
    result, message, status = authenticate(
        payload.get('email'), payload.get('password'), payload.get('role'),
        client_ip(), request.headers.get('User-Agent', '')
    )
    if not result:
        return error(message, status)
    if result.get('role_code') != 'system_admin' and get_bool_setting('maintenance_mode', False):
        return error(
            'The system is temporarily in maintenance mode. Please try again later.',
            503,
            {'maintenanceMode': True},
        )
    token = create_access_token(identity=str(result['user_id']), additional_claims={
        'role': result['role_code'],
        'frontend_role': result['user']['role'],
        'email': result['user']['email'],
        'auth_version': int(result.get('auth_version') or 1),
    })
    return success({
        'access_token': token,
        'user': result['user'],
        'must_change_password': bool(result.get('must_change_password')),
        'temporary_password_login': bool(result.get('temporary_password_login')),
    }, 'Login successful.')


@auth_bp.post('/register')
def register():
    if get_bool_setting('maintenance_mode', False):
        return error(
            'Resident registration is temporarily unavailable while the system is under maintenance.',
            503,
            {'maintenanceMode': True},
        )
    payload = request.get_json(silent=True) or {}
    result, message, status = submit_registration_request(
        payload, client_ip(), request.headers.get('User-Agent', '')
    )
    if not result:
        return error(message, status)
    return success({'registration': result}, message or 'Registration request submitted for approval.', status)


@auth_bp.get('/registration-status')
def registration_status():
    data = get_registration_status(request.args.get('email', ''))
    if not data:
        return error('No registration request was found for this email address.', 404)
    public_status = {
        'status': data.get('status'),
        'requestedAt': data.get('requestedAt'),
        'reviewedAt': data.get('reviewedAt'),
    }
    return success({'registration': public_status}, 'Registration status loaded.')


@auth_bp.get('/public-settings')
def public_settings():
    return success({
        'systemName': get_string_setting('system_name', 'HelaFixIt AI'),
        'apartmentName': get_string_setting('apartment_name', 'Apartment Maintenance'),
        'defaultLanguage': get_string_setting('default_language', 'English'),
        'registrationEnabled': get_bool_setting('allow_registration', True),
        'maintenanceMode': get_bool_setting('maintenance_mode', False),
    }, 'Public system settings loaded.')


@auth_bp.get('/registration-options')
def get_registration_options():
    return success({
        'buildings': registration_options(),
        'defaultLanguage': get_string_setting('default_language', 'English'),
        'registrationEnabled': get_bool_setting('allow_registration', True),
    }, 'Registration locations loaded.')


@auth_bp.get('/me')
@jwt_required()
def me():
    user = get_user_profile(get_jwt_identity())
    if not user:
        return error('User account could not be found.', 404)
    if user['status'] != 'Active':
        return error('This account is not active.', 403)
    if user.get('role') != 'systemAdmin' and get_bool_setting('maintenance_mode', False):
        return error(
            'The system is temporarily in maintenance mode. Please try again later.',
            503,
            {'maintenanceMode': True},
        )
    user['temporaryPasswordActive'] = has_active_temporary_password(int(get_jwt_identity()))
    return success({'user': user}, 'Authenticated user loaded.')


@auth_bp.get('/notification-summary')
@jwt_required()
def notification_summary():
    user_id = int(get_jwt_identity())
    retention = get_int_setting('notification_retention_days', 90, 7, 365)
    connection = get_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute(
                f"DELETE FROM notifications WHERE user_id=%s AND read_at IS NOT NULL "
                f"AND created_at < DATE_SUB(NOW(), INTERVAL {retention} DAY)",
                (user_id,),
            )
        connection.commit()
    finally:
        connection.close()
    row = query_one(
        """
        SELECT COUNT(*) AS unread
        FROM notifications
        WHERE user_id=%s AND channel='In App' AND read_at IS NULL
        """,
        (user_id,),
    ) or {'unread': 0}
    return success({
        'unread': int(row.get('unread') or 0),
        'browserAlerts': get_bool_setting('browser_alerts', True),
    }, 'Notification summary loaded.')


@auth_bp.put('/profile')
@jwt_required()
def update_profile():
    payload = request.get_json(silent=True) or {}
    result, message, status = update_basic_profile(
        int(get_jwt_identity()), payload.get('name'), payload.get('phone')
    )
    if not result:
        return error(message, status)
    return success({'user': result}, 'Profile updated.')


@auth_bp.post('/logout')
@jwt_required()
def logout():
    claims = get_jwt()
    user_id = int(get_jwt_identity())
    connection = get_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute(
                "INSERT IGNORE INTO revoked_tokens(user_id,token_jti,token_type,expires_at,reason) "
                "VALUES(%s,%s,'Access',FROM_UNIXTIME(%s),'User logout')",
                (user_id, claims.get('jti'), claims.get('exp')),
            )
        connection.commit()
    finally:
        connection.close()
    return success(message='Logged out successfully.')


@auth_bp.post('/forgot-password')
def forgot_password():
    payload = request.get_json(silent=True) or {}
    result = create_password_reset(payload.get('email'), client_ip())
    return success(result, result['message'])


@auth_bp.post('/reset-password')
def complete_reset_password():
    # Compatibility endpoint only. The final local workflow uses a System Admin
    # issued temporary password and then /change-password. Import lazily so an
    # older auth_service without token-reset support cannot stop Flask startup.
    try:
        from services.auth_service import reset_password as legacy_reset_password
    except ImportError:
        return error(
            'Password reset links are not used in this system. Ask the System Admin to issue a temporary password, then sign in and create a new password.',
            410,
        )

    payload = request.get_json(silent=True) or {}
    ok, message = legacy_reset_password(
        payload.get('token'), payload.get('password'),
        client_ip(), request.headers.get('User-Agent', '')
    )
    if not ok:
        return error(message, 400)
    return success(message=message)


@auth_bp.post('/change-password')
@jwt_required()
def change_own_password():
    payload = request.get_json(silent=True) or {}
    ok, message = change_password(
        int(get_jwt_identity()), payload.get('current_password'), payload.get('new_password'),
        client_ip(), request.headers.get('User-Agent', '')
    )
    if not ok:
        return error(message, 400)
    return success(message=message)
