import hashlib
import secrets

from flask import current_app
from werkzeug.security import check_password_hash, generate_password_hash

from database import get_connection, query_all, query_one
from utils.validators import (
    clean_text, normalize_email, normalize_mobile, validate_email, validate_mobile,
    validate_name, validate_password, validate_unit_number,
)

DB_TO_FRONTEND_ROLE = {
    'resident': 'resident',
    'apartment_admin': 'admin',
    'technician': 'technician',
    'system_admin': 'systemAdmin',
}
FRONTEND_TO_DB_ROLE = {
    'resident': 'resident',
    'admin': 'apartment_admin',
    'apartment_admin': 'apartment_admin',
    'technician': 'technician',
    'systemAdmin': 'system_admin',
    'system_admin': 'system_admin',
}


def normalize_role(role):
    return FRONTEND_TO_DB_ROLE.get(role, role)


def frontend_role(role):
    return DB_TO_FRONTEND_ROLE.get(role, role)


def _frontend_user(row):
    role_code = row['role_code']
    front_role = frontend_role(role_code)
    user_id = int(row['user_id'])

    block = ''
    floor = ''
    apartment = ''
    technician_id = ''

    if role_code == 'resident':
        block = row.get('resident_block') or ''
        floor_number = row.get('resident_floor_number')
        if floor_number is not None:
            floor = 'Ground' if int(floor_number) == 0 else ('Basement' if int(floor_number) < 0 else str(floor_number))
        apartment = row.get('resident_unit_number') or ''
    elif role_code == 'apartment_admin':
        block = row.get('admin_block') or ''
        floor = ''
    elif role_code == 'technician':
        block = row.get('technician_block') or ''
        tech_id = row.get('technician_id')
        if tech_id:
            technician_id = f"TEC-{int(tech_id):02d}"
    elif role_code == 'system_admin':
        block = ''

    result = {
        'id': f"USR-{user_id:03d}",
        'dbId': user_id,
        'name': row['full_name'],
        'email': row['email'],
        'phone': row.get('phone') or '',
        'role': front_role,
        'roleCode': role_code,
        'block': block,
        'floor': floor,
        'apartment': apartment,
        'status': row['account_status'],
        'mustChangePassword': bool(row.get('must_change_password')),
        'emailVerified': bool(row.get('email_verified')),
    }
    if technician_id:
        result['technicianId'] = technician_id
        result['availability'] = row.get('technician_availability') or ''
    return result


def get_user_profile(user_id):
    row = query_one(
        """
        SELECT
            u.user_id, u.full_name, u.email, u.phone, u.account_status, u.email_verified,
            u.must_change_password, u.is_deleted,
            r.role_code, r.role_name,
            rp.resident_id,
            rb.block_code AS resident_block,
            rf.floor_number AS resident_floor_number,
            COALESCE(ru.unit_number, rp.unit_number) AS resident_unit_number,
            ap.admin_id,
            ab.block_code AS admin_block,
            tp.technician_id,
            tp.employee_code,
            tp.availability AS technician_availability,
            tb.block_code AS technician_block
        FROM users u
        INNER JOIN roles r ON r.role_id = u.role_id
        LEFT JOIN resident_profiles rp ON rp.user_id = u.user_id
        LEFT JOIN buildings rb ON rb.building_id = rp.building_id
        LEFT JOIN floors rf ON rf.floor_id = rp.floor_id
        LEFT JOIN units ru ON ru.unit_id = rp.unit_id
        LEFT JOIN apartment_admin_profiles ap ON ap.user_id = u.user_id
        LEFT JOIN buildings ab ON ab.building_id = ap.primary_building_id
        LEFT JOIN technician_profiles tp ON tp.user_id = u.user_id
        LEFT JOIN buildings tb ON tb.building_id = tp.assigned_building_id
        WHERE u.user_id = %s
        LIMIT 1
        """,
        (user_id,),
    )
    return _frontend_user(row) if row else None


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


def authenticate(email, password, selected_role, ip_address=None, user_agent=None):
    email = normalize_email(email)
    db_role = normalize_role(selected_role)
    if not validate_email(email) or not password:
        return None, 'Enter a valid email address and password.', 400

    connection = get_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                SELECT u.*, r.role_code, r.active AS role_active
                FROM users u
                INNER JOIN roles r ON r.role_id = u.role_id
                WHERE LOWER(u.email) = %s
                LIMIT 1
                FOR UPDATE
                """,
                (email,),
            )
            user = cursor.fetchone()

            if not user:
                cursor.execute("SELECT request_status FROM resident_registration_requests WHERE LOWER(email)=%s ORDER BY requested_at DESC LIMIT 1", (email,))
                registration = cursor.fetchone()
                _record_login_attempt(connection, None, email, False, ip_address, user_agent, 'Account not found')
                connection.commit()
                if registration and registration['request_status'] == 'Pending':
                    return None, 'Your resident registration request is waiting for approval.', 403
                if registration and registration['request_status'] == 'Rejected':
                    return None, 'Your resident registration request was not approved. Contact apartment management for more information.', 403
                return None, 'Invalid email, password, or selected role.', 401

            user_id = user['user_id']
            if user['role_code'] != db_role:
                _record_login_attempt(connection, user_id, email, False, ip_address, user_agent, 'Incorrect role selected')
                connection.commit()
                return None, 'Invalid email, password, or selected role.', 401

            if user.get('is_deleted') or not user['role_active'] or user['account_status'] != 'Active':
                _record_login_attempt(connection, user_id, email, False, ip_address, user_agent, f"Account status {user['account_status']}")
                connection.commit()
                return None, 'This account is not active. Contact the system administrator.', 403

            cursor.execute('SELECT NOW() AS now_value')
            now_value = cursor.fetchone()['now_value']
            if user.get('locked_until') and user['locked_until'] > now_value:
                _record_login_attempt(connection, user_id, email, False, ip_address, user_agent, 'Account temporarily locked')
                connection.commit()
                return None, 'Account temporarily locked after repeated failed logins. Try again later.', 423

            if not check_password_hash(user['password_hash'], password):
                failed_count = int(user.get('failed_login_count') or 0) + 1
                if failed_count >= 5:
                    cursor.execute(
                        """
                        UPDATE users
                        SET failed_login_count = 0,
                            locked_until = DATE_ADD(NOW(), INTERVAL 15 MINUTE)
                        WHERE user_id = %s
                        """,
                        (user_id,),
                    )
                    reason = 'Invalid password. Account locked for 15 minutes.'
                else:
                    cursor.execute(
                        'UPDATE users SET failed_login_count = %s WHERE user_id = %s',
                        (failed_count, user_id),
                    )
                    reason = 'Invalid password'
                _record_login_attempt(connection, user_id, email, False, ip_address, user_agent, reason)
                connection.commit()
                return None, 'Invalid email, password, or selected role.', 401

            cursor.execute(
                """
                UPDATE users
                SET failed_login_count = 0,
                    locked_until = NULL,
                    last_login_at = NOW()
                WHERE user_id = %s
                """,
                (user_id,),
            )
            _record_login_attempt(connection, user_id, email, True, ip_address, user_agent)
            connection.commit()
            return {
                'user_id': int(user_id),
                'role_code': user['role_code'],
                'user': get_user_profile(user_id),
                'must_change_password': bool(user.get('must_change_password')),
                'auth_version': int(user.get('auth_version') or 1),
            }, None, 200
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()


def registration_options():
    buildings = query_all(
        """
        SELECT building_id, block_code, name
        FROM buildings
        WHERE status = 'Active'
        ORDER BY block_code
        """
    )
    floors = query_all(
        """
        SELECT floor_id, building_id, floor_number, name
        FROM floors
        WHERE status = 'Active'
        ORDER BY building_id, floor_number
        """
    )
    by_building = {}
    for floor in floors:
        by_building.setdefault(int(floor['building_id']), []).append({
            'floor_id': int(floor['floor_id']),
            'floor_number': int(floor['floor_number']),
            'name': floor['name'],
        })
    return [
        {
            'building_id': int(building['building_id']),
            'block_code': building['block_code'],
            'name': building['name'],
            'floors': by_building.get(int(building['building_id']), []),
        }
        for building in buildings
    ]


def register_resident(payload, ip_address=None, user_agent=None):
    """Resident accounts are created only after an approved registration request."""
    return None, 'Resident registration requires administrator approval.', 403

def create_password_reset(email, ip_address=None):
    """Create a durable Forgot Password request for System Admin review.

    The generated token is never exposed to the browser. The token row is used
    only as a pending reset-request record until a System Admin issues a
    temporary password. This keeps the request visible even if notifications
    are read or dismissed.
    """
    email = normalize_email(email)
    generic_message = 'If the email exists, a password reset request has been sent to the System Admin.'
    if not validate_email(email):
        return {'message': generic_message}

    user = query_one(
        "SELECT user_id FROM users WHERE LOWER(email)=%s AND account_status='Active' AND is_deleted=FALSE LIMIT 1",
        (email,),
    )
    if not user:
        return {'message': generic_message}

    user_id = int(user['user_id'])
    raw_marker = secrets.token_urlsafe(32)
    token_hash = hashlib.sha256(raw_marker.encode('utf-8')).hexdigest()

    connection = get_connection()
    try:
        with connection.cursor() as cursor:
            # Only one pending request is needed for each user. Older unused
            # requests are closed before the new request is recorded.
            cursor.execute(
                'UPDATE password_reset_tokens SET used_at=NOW() WHERE user_id=%s AND used_at IS NULL',
                (user_id,),
            )
            cursor.execute(
                """
                INSERT INTO password_reset_tokens(user_id,token_hash,expires_at,requested_ip)
                VALUES(%s,%s,DATE_ADD(NOW(),INTERVAL 24 HOUR),%s)
                """,
                (user_id, token_hash, ip_address),
            )
            cursor.execute(
                """
                INSERT INTO notifications(user_id,event_type,channel,title,message,delivery_status)
                SELECT u.user_id,'Password Reset Request','In App','Password reset request',
                       CONCAT('Password reset requested for ',%s,'. Verify the account and issue a temporary password from User Management.'),
                       'Delivered'
                FROM users u
                INNER JOIN roles r ON r.role_id=u.role_id
                WHERE u.account_status='Active'
                  AND u.is_deleted=FALSE
                  AND r.role_code='system_admin'
                """,
                (email,),
            )
            cursor.execute(
                """
                INSERT INTO audit_logs(user_id,action_type,entity_type,entity_id,reason,ip_address)
                VALUES(%s,'PASSWORD_RESET_REQUESTED','User',%s,'Forgot Password request submitted',%s)
                """,
                (user_id, str(user_id), ip_address),
            )
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()

    return {'message': generic_message}


def update_basic_profile(user_id, full_name, phone):
    full_name = clean_text(full_name, 150)
    phone = normalize_mobile(phone)
    if not validate_name(full_name):
        return None, 'Enter a valid full name.', 400
    if not validate_mobile(phone, required=True):
        return None, 'Enter a valid Sri Lankan mobile number such as 0771234567 or +94771234567.', 400
    connection = get_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute(
                "UPDATE users SET full_name=%s, phone=%s WHERE user_id=%s AND is_deleted=FALSE",
                (full_name, phone, user_id),
            )
            if cursor.rowcount == 0:
                connection.rollback()
                return None, 'User account could not be found.', 404
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()
    return get_user_profile(user_id), None, 200


def change_password(user_id, current_password, new_password, ip_address=None, user_agent=None):
    valid, message = validate_password(new_password)
    if not valid:
        return False, message
    if not current_password:
        return False, 'Enter your current password.'
    connection = get_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute("SELECT password_hash,is_deleted FROM users WHERE user_id=%s FOR UPDATE", (user_id,))
            row = cursor.fetchone()
            if not row or row.get('is_deleted'):
                return False, 'User account could not be found.'
            if not check_password_hash(row['password_hash'], current_password):
                return False, 'Current password is incorrect.'
            if check_password_hash(row['password_hash'], new_password):
                return False, 'Choose a new password that is different from the current password.'
            password_hash = generate_password_hash(new_password, method='pbkdf2:sha256:600000')
            cursor.execute(
                "UPDATE users SET password_hash=%s,must_change_password=FALSE,failed_login_count=0,locked_until=NULL,last_password_change_at=NOW(),auth_version=auth_version+1 WHERE user_id=%s",
                (password_hash, user_id),
            )
            cursor.execute(
                "INSERT INTO audit_logs(user_id,action_type,entity_type,entity_id,reason,ip_address,user_agent) VALUES(%s,'PASSWORD_CHANGED','User',%s,'User changed password',%s,%s)",
                (user_id, str(user_id), ip_address, (user_agent or '')[:500]),
            )
        connection.commit()
        return True, 'Password changed successfully. Sign in again with your new password.'
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()
