from functools import wraps

from flask_jwt_extended import get_jwt_identity, verify_jwt_in_request

from database import query_one
from services.settings_service import get_bool_setting
from utils.responses import error


def roles_required(*allowed_roles):
    """Authorize protected routes using the current role stored in MariaDB.

    The JWT identifies the signed-in account, while the current account status and role
    are rechecked from the database for every protected request.
    """
    allowed = set(allowed_roles)

    def decorator(func):
        @wraps(func)
        def wrapper(*args, **kwargs):
            verify_jwt_in_request()
            user = query_one(
                """
                SELECT u.account_status,u.is_deleted,u.must_change_password,r.role_code
                FROM users u
                INNER JOIN roles r ON r.role_id=u.role_id
                WHERE u.user_id=%s AND r.active=TRUE
                LIMIT 1
                """,
                (int(get_jwt_identity()),),
            )
            if not user or user.get('is_deleted') or user.get('account_status') != 'Active':
                return error('This account is not active.', 403)
            if user.get('role_code') not in allowed:
                return error('You do not have permission to access this resource.', 403)
            if user.get('role_code') != 'system_admin' and get_bool_setting('maintenance_mode', False):
                return error('The system is temporarily in maintenance mode. Please try again later.', 503, {'maintenanceMode': True})
            if user.get('must_change_password'):
                return error('You must change your temporary password before using the system.', 428)
            return func(*args, **kwargs)
        return wrapper
    return decorator
