"""Temporary password workflow for HelaFixIt AI.

A System Admin issued temporary password is stored separately from the user's
normal password. The old normal password is not replaced. While an active
temporary password exists, only that temporary password can be used to sign in.
After sign in the user must set a new normal password.
"""

from datetime import datetime

from werkzeug.security import check_password_hash, generate_password_hash

from database import get_connection, query_one
from services.auth_service import (
    authenticate as normal_authenticate,
    change_password as normal_change_password,
    get_user_profile,
    normalize_role,
)
from utils.validators import normalize_email, validate_email, validate_password


_TABLE_READY = False


def ensure_temporary_password_table():
    global _TABLE_READY
    if _TABLE_READY:
        return
    connection = get_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                CREATE TABLE IF NOT EXISTS temporary_passwords (
                    temporary_password_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
                    user_id BIGINT UNSIGNED NOT NULL,
                    password_hash VARCHAR(255) NOT NULL,
                    expires_at DATETIME NOT NULL,
                    created_by BIGINT UNSIGNED NULL,
                    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    used_at DATETIME NULL,
                    CONSTRAINT fk_temp_password_user
                        FOREIGN KEY (user_id) REFERENCES users(user_id)
                        ON UPDATE CASCADE ON DELETE CASCADE,
                    CONSTRAINT fk_temp_password_created_by
                        FOREIGN KEY (created_by) REFERENCES users(user_id)
                        ON UPDATE CASCADE ON DELETE SET NULL,
                    UNIQUE KEY uq_temp_password_user (user_id),
                    KEY idx_temp_password_active (user_id, used_at, expires_at)
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
                """
            )
        connection.commit()
        _TABLE_READY = True
    finally:
        connection.close()


def has_active_temporary_password(user_id):
    """Return True only while the user has an unused, unexpired temporary password."""
    ensure_temporary_password_table()
    row = query_one(
        """
        SELECT temporary_password_id
        FROM temporary_passwords
        WHERE user_id=%s
          AND used_at IS NULL
          AND expires_at > NOW()
        LIMIT 1
        """,
        (user_id,),
    )
    return bool(row)


def _record_login_attempt(connection, user_id, email, success, ip_address, user_agent, reason=None):
    with connection.cursor() as cursor:
        cursor.execute(
            """
            INSERT INTO login_attempts
                (user_id, email_entered, was_successful, ip_address, user_agent, failure_reason)
            VALUES (%s, %s, %s, %s, %s, %s)
            """,
            (user_id, email, bool(success), ip_address, (user_agent or '')[:500], reason),
        )


def set_temporary_password(user_id, temporary_password, updated_by, lifetime_hours=24):
    """Issue a temporary password without replacing the normal password hash."""
    ensure_temporary_password_table()
    if int(user_id) == int(updated_by):
        return None, 'Use Change Password to update your own System Admin password.', 400
    valid, message = validate_password(temporary_password)
    if not valid:
        return None, message, 400

    connection = get_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                SELECT u.user_id,u.is_deleted,u.account_status,u.full_name,u.email
                FROM users u
                WHERE u.user_id=%s
                LIMIT 1
                FOR UPDATE
                """,
                (user_id,),
            )
            user = cursor.fetchone()
            if not user:
                connection.rollback()
                return None, 'User not found.', 404
            if user.get('is_deleted'):
                connection.rollback()
                return None, 'Restore the deleted account before issuing a temporary password.', 400
            if user.get('account_status') in {'Suspended', 'Disabled'}:
                connection.rollback()
                return None, 'Activate the account before issuing a temporary password.', 400

            password_hash = generate_password_hash(
                temporary_password, method='pbkdf2:sha256:600000'
            )
            cursor.execute(
                """
                INSERT INTO temporary_passwords
                    (user_id,password_hash,expires_at,created_by,created_at,used_at)
                VALUES(%s,%s,DATE_ADD(NOW(),INTERVAL %s HOUR),%s,NOW(),NULL)
                ON DUPLICATE KEY UPDATE
                    password_hash=VALUES(password_hash),
                    expires_at=VALUES(expires_at),
                    created_by=VALUES(created_by),
                    created_at=NOW(),
                    used_at=NULL
                """,
                (user_id, password_hash, int(lifetime_hours), updated_by),
            )
            # The normal password_hash is deliberately untouched.
            cursor.execute(
                """
                UPDATE users
                SET must_change_password=TRUE,
                    failed_login_count=0,
                    locked_until=NULL,
                    auth_version=auth_version+1,
                    account_status=IF(account_status='Locked','Active',account_status)
                WHERE user_id=%s
                """,
                (user_id,),
            )
            cursor.execute(
                'UPDATE password_reset_tokens SET used_at=NOW() WHERE user_id=%s AND used_at IS NULL',
                (user_id,),
            )
            cursor.execute(
                """
                INSERT INTO audit_logs(user_id,action_type,entity_type,entity_id,new_value,reason)
                VALUES(%s,'TEMPORARY_PASSWORD_ISSUED','User',%s,
                       JSON_OBJECT('expires_hours',%s),
                       'Temporary password issued by System Admin; normal password retained until user creates a new password')
                """,
                (updated_by, str(user_id), int(lifetime_hours)),
            )
        connection.commit()
        row = query_one(
            'SELECT expires_at FROM temporary_passwords WHERE user_id=%s LIMIT 1',
            (user_id,),
        ) or {}
        expires_at = row.get('expires_at')
        return {
            'id': int(user_id),
            'mustChangePassword': True,
            'temporaryPassword': True,
            'expiresAt': expires_at.isoformat() if expires_at else None,
        }, None, 200
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()


def authenticate(email, password, selected_role, ip_address=None, user_agent=None):
    """Authenticate with a temporary password when one is active, otherwise normal auth."""
    ensure_temporary_password_table()
    email = normalize_email(email)
    db_role = normalize_role(selected_role)
    if not validate_email(email) or not password:
        return None, 'Enter a valid email address and password.', 400

    # Fast check for an active temporary password. If there is none, keep the
    # original authentication behaviour unchanged.
    lookup = query_one(
        """
        SELECT u.user_id,u.account_status,u.is_deleted,u.locked_until,u.auth_version,
               r.role_code,r.active AS role_active,
               tp.password_hash AS temporary_password_hash,tp.expires_at,tp.used_at
        FROM users u
        INNER JOIN roles r ON r.role_id=u.role_id
        LEFT JOIN temporary_passwords tp ON tp.user_id=u.user_id AND tp.used_at IS NULL
        WHERE LOWER(u.email)=%s
        LIMIT 1
        """,
        (email,),
    )
    if not lookup or not lookup.get('temporary_password_hash'):
        return normal_authenticate(email, password, selected_role, ip_address, user_agent)

    if lookup['role_code'] != db_role:
        return None, 'Invalid email, password, or selected role.', 401
    if lookup.get('is_deleted') or not lookup.get('role_active') or lookup.get('account_status') != 'Active':
        return None, 'This account is not active. Contact the system administrator.', 403

    now = datetime.now()
    if lookup.get('locked_until') and lookup['locked_until'] > now:
        return None, 'Account temporarily locked after repeated failed logins. Try again later.', 423
    if not lookup.get('expires_at') or lookup['expires_at'] <= now:
        return None, 'The temporary password has expired. Use Forgot Password to request another reset.', 401

    connection = get_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                SELECT u.user_id,u.failed_login_count,u.locked_until,u.account_status,u.is_deleted,
                       u.auth_version,r.role_code,r.active AS role_active,
                       tp.password_hash AS temporary_password_hash,tp.expires_at
                FROM users u
                INNER JOIN roles r ON r.role_id=u.role_id
                INNER JOIN temporary_passwords tp ON tp.user_id=u.user_id AND tp.used_at IS NULL
                WHERE LOWER(u.email)=%s
                LIMIT 1
                FOR UPDATE
                """,
                (email,),
            )
            user = cursor.fetchone()
            if not user:
                connection.rollback()
                return None, 'Invalid email, password, or selected role.', 401
            if user['role_code'] != db_role:
                _record_login_attempt(connection, user['user_id'], email, False, ip_address, user_agent, 'Incorrect role selected')
                connection.commit()
                return None, 'Invalid email, password, or selected role.', 401
            if user.get('is_deleted') or not user.get('role_active') or user.get('account_status') != 'Active':
                _record_login_attempt(connection, user['user_id'], email, False, ip_address, user_agent, 'Inactive account')
                connection.commit()
                return None, 'This account is not active. Contact the system administrator.', 403

            cursor.execute('SELECT NOW() AS now_value')
            now_value = cursor.fetchone()['now_value']
            if user.get('locked_until') and user['locked_until'] > now_value:
                connection.rollback()
                return None, 'Account temporarily locked after repeated failed logins. Try again later.', 423
            if user.get('expires_at') <= now_value:
                connection.rollback()
                return None, 'The temporary password has expired. Use Forgot Password to request another reset.', 401

            if not check_password_hash(user['temporary_password_hash'], password):
                failed_count = int(user.get('failed_login_count') or 0) + 1
                if failed_count >= 5:
                    cursor.execute(
                        "UPDATE users SET failed_login_count=0,locked_until=DATE_ADD(NOW(),INTERVAL 15 MINUTE) WHERE user_id=%s",
                        (user['user_id'],),
                    )
                    reason = 'Invalid temporary password. Account locked for 15 minutes.'
                else:
                    cursor.execute(
                        'UPDATE users SET failed_login_count=%s WHERE user_id=%s',
                        (failed_count, user['user_id']),
                    )
                    reason = 'Invalid temporary password'
                _record_login_attempt(connection, user['user_id'], email, False, ip_address, user_agent, reason)
                connection.commit()
                return None, 'Invalid email, temporary password, or selected role.', 401

            cursor.execute(
                """
                UPDATE users
                SET failed_login_count=0,locked_until=NULL,last_login_at=NOW(),must_change_password=TRUE
                WHERE user_id=%s
                """,
                (user['user_id'],),
            )
            _record_login_attempt(connection, user['user_id'], email, True, ip_address, user_agent, 'Temporary password login')
        connection.commit()
        profile = get_user_profile(user['user_id'])
        return {
            'user_id': int(user['user_id']),
            'role_code': user['role_code'],
            'user': profile,
            'must_change_password': True,
            'temporary_password_login': True,
            'auth_version': int(user.get('auth_version') or 1),
        }, None, 200
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()


def change_password(user_id, current_password, new_password, ip_address=None, user_agent=None):
    """Replace an active temporary password with a new normal password."""
    ensure_temporary_password_table()
    temp = query_one(
        """
        SELECT tp.password_hash,tp.expires_at,u.must_change_password
        FROM temporary_passwords tp
        INNER JOIN users u ON u.user_id=tp.user_id
        WHERE tp.user_id=%s AND tp.used_at IS NULL
        LIMIT 1
        """,
        (user_id,),
    )
    if not temp:
        return normal_change_password(user_id, current_password, new_password, ip_address, user_agent)

    valid, message = validate_password(new_password)
    if not valid:
        return False, message
    if not current_password:
        return False, 'Enter the temporary password issued by the System Admin.'

    connection = get_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                SELECT u.password_hash,u.is_deleted,u.must_change_password,
                       tp.temporary_password_id,tp.password_hash AS temporary_password_hash,tp.expires_at
                FROM users u
                INNER JOIN temporary_passwords tp ON tp.user_id=u.user_id AND tp.used_at IS NULL
                WHERE u.user_id=%s
                LIMIT 1
                FOR UPDATE
                """,
                (user_id,),
            )
            row = cursor.fetchone()
            if not row or row.get('is_deleted'):
                connection.rollback()
                return False, 'User account could not be found.'

            cursor.execute('SELECT NOW() AS now_value')
            now_value = cursor.fetchone()['now_value']
            if row.get('expires_at') <= now_value:
                connection.rollback()
                return False, 'The temporary password has expired. Use Forgot Password to request another reset.'
            if not check_password_hash(row['temporary_password_hash'], current_password):
                connection.rollback()
                return False, 'Temporary password is incorrect.'
            if check_password_hash(row['temporary_password_hash'], new_password):
                connection.rollback()
                return False, 'Choose a new password that is different from the temporary password.'
            if row.get('password_hash') and check_password_hash(row['password_hash'], new_password):
                connection.rollback()
                return False, 'Choose a new password that is different from your previous password.'

            new_hash = generate_password_hash(new_password, method='pbkdf2:sha256:600000')
            cursor.execute(
                """
                UPDATE users
                SET password_hash=%s,
                    must_change_password=FALSE,
                    failed_login_count=0,
                    locked_until=NULL,
                    last_password_change_at=NOW(),
                    auth_version=auth_version+1
                WHERE user_id=%s
                """,
                (new_hash, user_id),
            )
            cursor.execute(
                'UPDATE temporary_passwords SET used_at=NOW() WHERE temporary_password_id=%s',
                (row['temporary_password_id'],),
            )
            cursor.execute(
                """
                INSERT INTO audit_logs(user_id,action_type,entity_type,entity_id,reason,ip_address,user_agent)
                VALUES(%s,'TEMPORARY_PASSWORD_REPLACED','User',%s,
                       'User created a new normal password after temporary password sign in',%s,%s)
                """,
                (user_id, str(user_id), ip_address, (user_agent or '')[:500]),
            )
        connection.commit()
        return True, 'New password created successfully. Sign in again with your new password.'
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()
