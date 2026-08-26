from __future__ import annotations

from werkzeug.security import generate_password_hash

from database import get_connection, query_all, query_one
from utils.validators import (
    clean_text, normalize_email, normalize_mobile, validate_email, validate_mobile,
    validate_name, validate_password, validate_unit_number,
)


def _request_row(row):
    return {
        'id': int(row['request_id']),
        'name': row['full_name'],
        'fullName': row['full_name'],
        'email': row['email'],
        'phone': row['phone'],
        'status': row['request_status'],
        'block': row.get('block_code') or '',
        'building': row.get('building_name') or '',
        'floor': row.get('floor_name') or '',
        'floorNumber': row.get('floor_number'),
        'unit': row.get('unit_number') or '',
        'unitNumber': row.get('unit_number') or '',
        'residentType': row.get('resident_type') or 'Other',
        'language': row.get('preferred_language') or 'English',
        'requestedAt': row['requested_at'].isoformat() if row.get('requested_at') else None,
        'reviewedAt': row['reviewed_at'].isoformat() if row.get('reviewed_at') else None,
        'reviewedBy': row.get('reviewer_name') or '',
        'reviewNote': row.get('review_note') or '',
        'createdUserId': int(row['created_user_id']) if row.get('created_user_id') else None,
    }


def registration_options():
    buildings = query_all(
        """
        SELECT b.building_id,b.block_code,b.name,b.complex_id,
               f.floor_id,f.floor_number,f.name AS floor_name
        FROM buildings b
        LEFT JOIN floors f ON f.building_id=b.building_id AND f.status='Active'
        WHERE b.status='Active'
        ORDER BY b.block_code,f.floor_number
        """
    )
    by_id = {}
    for row in buildings:
        bid = int(row['building_id'])
        if bid not in by_id:
            by_id[bid] = {
                'building_id': bid,
                'block_code': row['block_code'],
                'name': row['name'],
                'floors': [],
            }
        if row.get('floor_id'):
            by_id[bid]['floors'].append({
                'floor_id': int(row['floor_id']),
                'floor_number': int(row['floor_number']),
                'name': row['floor_name'],
            })
    return list(by_id.values())


def submit_registration_request(payload, ip_address=None, user_agent=None):
    full_name = clean_text(payload.get('full_name'), 150)
    email = normalize_email(payload.get('email'))
    phone = normalize_mobile(payload.get('phone'))
    block_code = clean_text(payload.get('block'), 50)
    floor_value = str(payload.get('floor', '')).strip()
    unit_number = clean_text(payload.get('unit_number'), 40)
    resident_type = clean_text(payload.get('resident_type'), 20) or 'Other'
    preferred_language = clean_text(payload.get('preferred_language'), 20) or 'English'
    password = payload.get('password') or ''

    if not full_name or not phone or not block_code or not floor_value:
        return None, 'Complete all required resident and apartment fields.', 400
    if not validate_name(full_name):
        return None, 'Enter a valid full name using letters, spaces, apostrophes, periods or hyphens.', 400
    if not validate_email(email):
        return None, 'Enter a valid email address.', 400
    if not validate_mobile(phone, required=True):
        return None, 'Enter a valid Sri Lankan mobile number such as 0771234567 or +94771234567.', 400
    if not validate_unit_number(unit_number):
        return None, 'Enter a valid apartment or unit number.', 400
    valid_password, password_message = validate_password(password)
    if not valid_password:
        return None, password_message, 400
    if resident_type not in {'Owner','Tenant','Family','Other'}:
        resident_type = 'Other'
    if preferred_language not in {'English','Sinhala','Singlish','Mixed'}:
        preferred_language = 'English'

    try:
        floor_number = int(floor_value)
    except ValueError:
        if floor_value.lower() in {'ground','ground floor'}:
            floor_number = 0
        elif floor_value.lower() in {'basement','b1'}:
            floor_number = -1
        else:
            return None, 'Select a valid configured floor.', 400

    connection = get_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute("SELECT setting_value FROM system_settings WHERE setting_key='allow_registration' LIMIT 1")
            setting = cursor.fetchone()
            if setting and str(setting['setting_value']).lower() not in {'1','true','yes','on'}:
                connection.rollback()
                return None, 'Resident registration is currently unavailable.', 403

            cursor.execute('SELECT user_id FROM users WHERE LOWER(email)=%s LIMIT 1', (email,))
            if cursor.fetchone():
                connection.rollback()
                return None, 'An account already exists with this email address.', 409

            cursor.execute(
                "SELECT request_id,request_status FROM resident_registration_requests WHERE LOWER(email)=%s AND request_status='Pending' LIMIT 1",
                (email,),
            )
            pending = cursor.fetchone()
            if pending:
                connection.rollback()
                return {'request_id': int(pending['request_id']), 'status': 'Pending'}, 'A registration request for this email is already waiting for approval.', 200

            cursor.execute(
                """
                SELECT b.building_id,b.complex_id,f.floor_id
                FROM buildings b JOIN floors f ON f.building_id=b.building_id
                WHERE b.block_code=%s AND b.status='Active' AND f.floor_number=%s AND f.status='Active'
                LIMIT 1
                """,
                (block_code, floor_number),
            )
            location = cursor.fetchone()
            if not location:
                connection.rollback()
                return None, 'The selected building and floor are not configured in the system.', 400

            unit_id = None
            if unit_number:
                cursor.execute(
                    "SELECT unit_id FROM units WHERE floor_id=%s AND unit_number=%s AND status='Active' LIMIT 1",
                    (location['floor_id'], unit_number),
                )
                unit = cursor.fetchone()
                if unit:
                    unit_id = unit['unit_id']

            password_hash = generate_password_hash(password, method='pbkdf2:sha256:600000')
            cursor.execute(
                """
                INSERT INTO resident_registration_requests
                    (full_name,email,phone,complex_id,building_id,floor_id,unit_id,unit_number,
                     resident_type,preferred_language,contact_preference,password_hash,request_status,
                     source_ip,user_agent)
                VALUES(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,'In App',%s,'Pending',%s,%s)
                """,
                (full_name,email,phone,location['complex_id'],location['building_id'],location['floor_id'],unit_id,
                 unit_number or None,resident_type,preferred_language,password_hash,(ip_address or '')[:45],(user_agent or '')[:500]),
            )
            request_id = cursor.lastrowid

            # Notify System Admins and only Apartment Admins responsible for the selected building.
            cursor.execute(
                """
                INSERT INTO notifications(user_id,event_type,channel,title,message,delivery_status)
                SELECT DISTINCT u.user_id,'Registration Request','In App','Resident registration request',
                       CONCAT(%s,' requested a resident account for ',%s,'.'),'Delivered'
                FROM users u
                JOIN roles r ON r.role_id=u.role_id
                LEFT JOIN apartment_admin_profiles ap ON ap.user_id=u.user_id
                WHERE u.account_status='Active'
                  AND (r.role_code='system_admin'
                       OR (r.role_code='apartment_admin' AND ap.active=TRUE AND ap.primary_building_id=%s))
                """,
                (full_name, block_code, location['building_id']),
            )
        connection.commit()
        return {'request_id': int(request_id), 'status': 'Pending'}, None, 202
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()


def get_registration_status(email):
    email = normalize_email(email)
    if not validate_email(email):
        return None
    row = query_one(
        """
        SELECT rr.*,b.block_code,b.name AS building_name,f.name AS floor_name,f.floor_number,u.full_name AS reviewer_name
        FROM resident_registration_requests rr
        JOIN buildings b ON b.building_id=rr.building_id
        JOIN floors f ON f.floor_id=rr.floor_id
        LEFT JOIN users u ON u.user_id=rr.reviewed_by
        WHERE LOWER(rr.email)=%s
        ORDER BY rr.requested_at DESC LIMIT 1
        """,
        (email,),
    )
    return _request_row(row) if row else None


def list_registration_requests(status='Pending', reviewer_user_id=None, reviewer_role=None):
    params = []
    where = ['1=1']
    if status:
        where.append('rr.request_status=%s')
        params.append(status)
    if reviewer_role == 'apartment_admin' and reviewer_user_id:
        admin = query_one('SELECT primary_building_id FROM apartment_admin_profiles WHERE user_id=%s AND active=TRUE LIMIT 1', (reviewer_user_id,))
        if not admin or not admin.get('primary_building_id'):
            return []
        where.append('rr.building_id=%s')
        params.append(admin['primary_building_id'])
    rows = query_all(
        f"""
        SELECT rr.*,b.block_code,b.name AS building_name,f.name AS floor_name,f.floor_number,u.full_name AS reviewer_name
        FROM resident_registration_requests rr
        JOIN buildings b ON b.building_id=rr.building_id
        JOIN floors f ON f.floor_id=rr.floor_id
        LEFT JOIN users u ON u.user_id=rr.reviewed_by
        WHERE {' AND '.join(where)}
        ORDER BY CASE rr.request_status WHEN 'Pending' THEN 0 ELSE 1 END, rr.requested_at DESC
        """,
        tuple(params),
    )
    return [_request_row(r) for r in rows]


def review_registration_request(request_id, reviewer_user_id, reviewer_role, action, note=''):
    action = (action or '').strip().lower()
    note = clean_text(note, 1000)
    if action not in {'approve','reject'}:
        return None, 'Select approve or reject.', 400

    connection = get_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                SELECT rr.*,b.block_code
                FROM resident_registration_requests rr
                JOIN buildings b ON b.building_id=rr.building_id
                WHERE rr.request_id=%s FOR UPDATE
                """,
                (request_id,),
            )
            req = cursor.fetchone()
            if not req:
                connection.rollback(); return None, 'Registration request not found.', 404
            if req['request_status'] != 'Pending':
                connection.rollback(); return None, 'This registration request has already been reviewed.', 409

            if reviewer_role == 'apartment_admin':
                cursor.execute('SELECT primary_building_id FROM apartment_admin_profiles WHERE user_id=%s AND active=TRUE LIMIT 1', (reviewer_user_id,))
                admin = cursor.fetchone()
                if not admin or not admin.get('primary_building_id'):
                    connection.rollback(); return None, 'No apartment building is assigned to this administrator.', 403
                if int(admin['primary_building_id']) != int(req['building_id']):
                    connection.rollback(); return None, 'This request belongs to another building.', 403

            if action == 'reject':
                cursor.execute(
                    "UPDATE resident_registration_requests SET request_status='Rejected',reviewed_by=%s,reviewed_at=NOW(),review_note=%s WHERE request_id=%s",
                    (reviewer_user_id, note or 'Registration request rejected.', request_id),
                )
                cursor.execute(
                    "INSERT INTO audit_logs(user_id,action_type,entity_type,entity_id,reason) VALUES(%s,'REGISTRATION_REJECTED','resident_registration_requests',%s,%s)",
                    (reviewer_user_id, str(request_id), note or 'Registration request rejected.'),
                )
                connection.commit()
                return {'id': int(request_id), 'status': 'Rejected'}, None, 200

            cursor.execute('SELECT user_id FROM users WHERE LOWER(email)=%s LIMIT 1', (req['email'].lower(),))
            if cursor.fetchone():
                connection.rollback(); return None, 'An account already exists with this email address.', 409
            cursor.execute("SELECT role_id FROM roles WHERE role_code='resident' AND active=TRUE LIMIT 1")
            role = cursor.fetchone()
            if not role:
                connection.rollback(); return None, 'Resident role is not available.', 500

            cursor.execute(
                """
                INSERT INTO users(role_id,complex_id,full_name,email,phone,password_hash,account_status,email_verified,created_by,last_password_change_at)
                VALUES(%s,%s,%s,%s,%s,%s,'Active',TRUE,%s,NOW())
                """,
                (role['role_id'],req['complex_id'],req['full_name'],req['email'],req['phone'],req['password_hash'],reviewer_user_id),
            )
            user_id = cursor.lastrowid
            cursor.execute(
                """
                INSERT INTO resident_profiles(user_id,building_id,floor_id,unit_id,unit_number,resident_type,preferred_language,contact_preference,profile_status)
                VALUES(%s,%s,%s,%s,%s,%s,%s,%s,'Active')
                """,
                (user_id,req['building_id'],req['floor_id'],req['unit_id'],req['unit_number'],req['resident_type'],req['preferred_language'],req['contact_preference']),
            )
            cursor.execute('INSERT INTO notification_preferences(user_id) VALUES(%s)', (user_id,))
            cursor.execute(
                "UPDATE resident_registration_requests SET request_status='Approved',reviewed_by=%s,reviewed_at=NOW(),review_note=%s,created_user_id=%s WHERE request_id=%s",
                (reviewer_user_id, note or 'Registration approved.', user_id, request_id),
            )
            cursor.execute(
                "INSERT INTO notifications(user_id,event_type,channel,title,message,delivery_status) VALUES(%s,'Registration Approved','In App','Resident account approved','Your resident account has been approved. You can now sign in.','Delivered')",
                (user_id,),
            )
            cursor.execute(
                "INSERT INTO audit_logs(user_id,action_type,entity_type,entity_id,new_value,reason) VALUES(%s,'REGISTRATION_APPROVED','resident_registration_requests',%s,JSON_OBJECT('created_user_id',%s),%s)",
                (reviewer_user_id,str(request_id),user_id,note or 'Registration approved.'),
            )
        connection.commit()
        return {'id': int(request_id), 'status': 'Approved', 'user_id': int(user_id)}, None, 201
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()
