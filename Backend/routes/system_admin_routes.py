from flask import Blueprint, jsonify, request
from flask_jwt_extended import get_jwt_identity

from database import get_connection, query_all, query_one
from services.registration_service import list_registration_requests, review_registration_request
from services.stage5_service import (
    backup_records, create_unit, replace_technician_skills, set_area_status, set_building_status,
    set_category_status, set_floor_status, set_safety_rule_status, set_skill_status,
    set_unit_status, technician_skill_assignments, update_area, update_building,
    update_category, update_floor, update_safety_rule, update_skill, update_unit,
)
from services.ticket_service import list_notifications, mark_notifications_read
from services.system_admin_service import (
    audit_logs, buildings, categories, create_area, create_building, create_category,
    create_floor, create_safety_rule, create_skill, create_user, dashboard, export_data_snapshot,
    get_user_details, list_users, locations, restore_user, roles, safety_rules, settings,
    set_email_verified, skills, unlock_user, update_settings, update_user, user_options,
    delete_user,
)
from services.temporary_password_service import set_temporary_password
from utils.auth_decorators import roles_required
from utils.responses import error, success
from utils.validators import clean_text, normalize_mobile, validate_mobile, validate_name

system_admin_bp = Blueprint('system_admin', __name__, url_prefix='/api/system-admin')


def _payload():
    return request.get_json(silent=True) or {}


def _mutation_result(result, message, status, success_message):
    if not result:
        return error(message, status)
    return success(result, success_message, status)


def _status_value(payload):
    value = payload.get('active')
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in {'1', 'true', 'yes', 'on', 'active'}


def _category_data():
    rows = query_all(
        """
        SELECT c.category_id,c.category_code,c.name,c.default_skill_id,c.default_priority,
               c.severity_weight,c.description,c.active,s.skill_name AS technician
        FROM issue_categories c
        LEFT JOIN skills s ON s.skill_id=c.default_skill_id
        ORDER BY c.category_id
        """
    )
    return [{
        'id': int(r['category_id']), 'code': r['category_code'], 'name': r['name'],
        'skillId': int(r['default_skill_id']) if r.get('default_skill_id') else None,
        'priority': r['default_priority'], 'riskWeight': float(r['severity_weight']),
        'description': r.get('description') or '', 'technician': r.get('technician') or 'General Maintenance',
        'active': bool(r['active']),
    } for r in rows]


def _building_data():
    base = {int(x['id']): x for x in buildings()}
    rows = query_all('SELECT building_id,address_label FROM buildings')
    for row in rows:
        item = base.get(int(row['building_id']))
        if item is not None:
            item['address'] = row.get('address_label') or ''
    return list(base.values())


def _safety_rule_data():
    rows = query_all(
        """
        SELECT sr.safety_rule_id,sr.category_id,sr.rule_code,sr.keyword_or_pattern,sr.match_type,
               sr.language_type,sr.score_weight,sr.severity,sr.warning_message,sr.resident_action,
               sr.technician_action,sr.rule_version,sr.active,c.name AS category
        FROM safety_rules sr
        LEFT JOIN issue_categories c ON c.category_id=sr.category_id
        ORDER BY sr.active DESC,sr.severity DESC,sr.safety_rule_id
        """
    )
    return [{
        'id': int(r['safety_rule_id']), 'categoryId': int(r['category_id']) if r.get('category_id') else None,
        'code': r['rule_code'], 'keyword': r['keyword_or_pattern'], 'matchType': r['match_type'],
        'language': r['language_type'], 'risk': float(r['score_weight']), 'severity': r['severity'],
        'warning': r['warning_message'], 'residentAction': r.get('resident_action') or '',
        'technicianAction': r.get('technician_action') or '', 'version': r['rule_version'],
        'category': r.get('category') or 'Any', 'active': bool(r['active']),
    } for r in rows]


def _unit_data():
    rows = query_all(
        """
        SELECT u.unit_id,u.floor_id,u.unit_number,u.unit_type,u.status,
               f.building_id,f.floor_number,f.name AS floor_name,b.block_code,b.name AS building_name
        FROM units u
        INNER JOIN floors f ON f.floor_id=u.floor_id
        INNER JOIN buildings b ON b.building_id=f.building_id
        ORDER BY b.block_code,f.floor_number,u.unit_number
        """
    )
    return [{
        'id': int(r['unit_id']), 'floorId': int(r['floor_id']), 'buildingId': int(r['building_id']),
        'unitNumber': r['unit_number'], 'type': r['unit_type'], 'active': r['status'] == 'Active',
        'block': r['block_code'], 'building': r['building_name'], 'floorNumber': int(r['floor_number']),
        'floor': r['floor_name'],
    } for r in rows]


@system_admin_bp.get('/dashboard')
@roles_required('system_admin')
def dashboard_route():
    return success(dashboard(), 'System Admin dashboard loaded.')


@system_admin_bp.get('/users')
@roles_required('system_admin')
def users_route():
    users = list_users(
        request.args.get('search','').strip(),
        request.args.get('role','').strip(),
        request.args.get('status','').strip(),
        request.args.get('deleted','active').strip(),
    )
    # Keep Forgot Password state with the user record itself. This avoids
    # frontend timing issues and makes the action available only for users
    # who currently have an unused password reset request.
    pending_rows = query_all(
        """
        SELECT user_id, MAX(created_at) AS requested_at
        FROM password_reset_tokens
        WHERE used_at IS NULL
          AND expires_at > NOW()
        GROUP BY user_id
        """
    )
    pending = {int(row['user_id']): row.get('requested_at') for row in pending_rows}
    for item in users:
        requested_at = pending.get(int(item['id']))
        item['passwordResetRequested'] = requested_at is not None
        item['passwordResetRequestedAt'] = requested_at.isoformat() if requested_at else None
    return success({'users': users}, 'Users loaded.')


@system_admin_bp.get('/user-options')
@roles_required('system_admin')
def user_options_route():
    return success(user_options(), 'User setup options loaded.')


@system_admin_bp.post('/users')
@roles_required('system_admin')
def create_user_route():
    result, message, status = create_user(_payload(), int(get_jwt_identity()))
    if not result:
        return error(message, status)
    return success(result, 'User account created.', status)


@system_admin_bp.get('/users/<int:user_id>')
@roles_required('system_admin')
def user_details_route(user_id):
    data = get_user_details(user_id)
    if not data:
        return error('User not found.', 404)
    return success({'user': data}, 'User details loaded.')


@system_admin_bp.put('/users/<int:user_id>')
@roles_required('system_admin')
def update_user_route(user_id):
    result, message, status = update_user(user_id, _payload(), int(get_jwt_identity()))
    if not result:
        return error(message, status)
    return success(result, 'User account updated.')


@system_admin_bp.post('/users/<int:user_id>/reset-password')
@roles_required('system_admin')
def reset_user_password_route(user_id):
    p = _payload()
    result, message, status = set_temporary_password(user_id, p.get('temporary_password') or '', int(get_jwt_identity()))
    if not result:
        return error(message, status)

    # Mark matching password-reset notifications as handled for System Admins.
    # The password_reset_tokens row is marked used when the temporary password is issued.
    target = query_one('SELECT email FROM users WHERE user_id=%s LIMIT 1', (user_id,)) or {}
    email = (target.get('email') or '').strip().lower()
    if email:
        connection = get_connection()
        try:
            with connection.cursor() as cursor:
                cursor.execute(
                    """
                    UPDATE notifications n
                    INNER JOIN users au ON au.user_id=n.user_id
                    INNER JOIN roles r ON r.role_id=au.role_id
                    SET n.read_at=COALESCE(n.read_at,NOW()),
                        n.delivery_status=CASE WHEN n.delivery_status='Delivered' THEN 'Read' ELSE n.delivery_status END
                    WHERE r.role_code='system_admin'
                      AND n.event_type='Password Reset Request'
                      AND LOWER(n.message) LIKE %s
                    """,
                    (f'%{email}%',),
                )
            connection.commit()
        except Exception:
            connection.rollback()
        finally:
            connection.close()

    return success(result, 'Temporary password set. The user must change it at the next sign in.')


@system_admin_bp.post('/users/<int:user_id>/unlock')
@roles_required('system_admin')
def unlock_user_route(user_id):
    result, message, status = unlock_user(user_id, int(get_jwt_identity()))
    if not result:
        return error(message, status)
    return success(result, 'User account unlocked.')


@system_admin_bp.post('/users/<int:user_id>/email-verification')
@roles_required('system_admin')
def email_verification_route(user_id):
    result, message, status = set_email_verified(user_id, bool(_payload().get('verified')), int(get_jwt_identity()))
    if not result:
        return error(message, status)
    return success(result, 'Email verification updated.')


@system_admin_bp.delete('/users/<int:user_id>')
@roles_required('system_admin')
def delete_user_route(user_id):
    result, message, status = delete_user(user_id, int(get_jwt_identity()))
    if not result:
        return error(message, status)
    return success(result, 'User account deleted.')


@system_admin_bp.post('/users/<int:user_id>/restore')
@roles_required('system_admin')
def restore_user_route(user_id):
    result, message, status = restore_user(user_id, int(get_jwt_identity()))
    if not result:
        return error(message, status)
    return success(result, 'User account restored.')


@system_admin_bp.get('/roles')
@roles_required('system_admin')
def roles_route():
    return success({'roles': roles()}, 'Roles loaded.')


@system_admin_bp.get('/skills')
@roles_required('system_admin')
def skills_route():
    return success({'skills': skills()}, 'Skills loaded.')


@system_admin_bp.post('/skills')
@roles_required('system_admin')
def create_skill_route():
    p = _payload()
    result, message, status = create_skill(p.get('name'), p.get('description',''))
    if not result:
        return error(message, status)
    return success(result, 'Skill added.', status)


@system_admin_bp.put('/skills/<int:skill_id>')
@roles_required('system_admin')
def update_skill_route(skill_id):
    result, message, status = update_skill(skill_id, _payload(), int(get_jwt_identity()))
    return _mutation_result(result, message, status, 'Technician skill updated.')


@system_admin_bp.patch('/skills/<int:skill_id>/status')
@roles_required('system_admin')
def skill_status_route(skill_id):
    result, message, status = set_skill_status(skill_id, _status_value(_payload()), int(get_jwt_identity()))
    return _mutation_result(result, message, status, 'Technician skill status updated.')


@system_admin_bp.get('/technician-skill-assignments')
@roles_required('system_admin')
def technician_skill_assignments_route():
    return success({'technicians': technician_skill_assignments(), 'skills': skills()}, 'Technician skill assignments loaded.')


@system_admin_bp.put('/technicians/<int:technician_id>/skills')
@roles_required('system_admin')
def technician_skills_route(technician_id):
    result, message, status = replace_technician_skills(technician_id, _payload().get('assignments'), int(get_jwt_identity()))
    return _mutation_result(result, message, status, 'Technician skill assignments updated.')


@system_admin_bp.get('/categories')
@roles_required('system_admin')
def categories_route():
    return success({'categories': _category_data(), 'skills': skills()}, 'Categories loaded.')


@system_admin_bp.post('/categories')
@roles_required('system_admin')
def create_category_route():
    result, message, status = create_category(_payload())
    if not result:
        return error(message, status)
    return success(result, 'Issue category added.', status)


@system_admin_bp.put('/categories/<int:category_id>')
@roles_required('system_admin')
def update_category_route(category_id):
    result, message, status = update_category(category_id, _payload(), int(get_jwt_identity()))
    return _mutation_result(result, message, status, 'Issue category updated.')


@system_admin_bp.patch('/categories/<int:category_id>/status')
@roles_required('system_admin')
def category_status_route(category_id):
    result, message, status = set_category_status(category_id, _status_value(_payload()), int(get_jwt_identity()))
    return _mutation_result(result, message, status, 'Issue category status updated.')


@system_admin_bp.get('/buildings')
@roles_required('system_admin')
def buildings_route():
    return success({'buildings': _building_data()}, 'Buildings loaded.')


@system_admin_bp.post('/buildings')
@roles_required('system_admin')
def create_building_route():
    result, message, status = create_building(_payload())
    if not result:
        return error(message, status)
    return success(result, 'Building added.', status)


@system_admin_bp.put('/buildings/<int:building_id>')
@roles_required('system_admin')
def update_building_route(building_id):
    result, message, status = update_building(building_id, _payload(), int(get_jwt_identity()))
    return _mutation_result(result, message, status, 'Building updated.')


@system_admin_bp.patch('/buildings/<int:building_id>/status')
@roles_required('system_admin')
def building_status_route(building_id):
    result, message, status = set_building_status(building_id, _status_value(_payload()), int(get_jwt_identity()))
    return _mutation_result(result, message, status, 'Building status updated.')


@system_admin_bp.get('/locations')
@roles_required('system_admin')
def locations_route():
    return success({'buildings': _building_data(), **locations()}, 'Locations loaded.')


@system_admin_bp.post('/floors')
@roles_required('system_admin')
def create_floor_route():
    result, message, status = create_floor(_payload())
    if not result:
        return error(message, status)
    return success(result, 'Floor added.', status)


@system_admin_bp.put('/floors/<int:floor_id>')
@roles_required('system_admin')
def update_floor_route(floor_id):
    result, message, status = update_floor(floor_id, _payload(), int(get_jwt_identity()))
    return _mutation_result(result, message, status, 'Floor updated.')


@system_admin_bp.patch('/floors/<int:floor_id>/status')
@roles_required('system_admin')
def floor_status_route(floor_id):
    result, message, status = set_floor_status(floor_id, _status_value(_payload()), int(get_jwt_identity()))
    return _mutation_result(result, message, status, 'Floor status updated.')


@system_admin_bp.post('/areas')
@roles_required('system_admin')
def create_area_route():
    result, message, status = create_area(_payload())
    if not result:
        return error(message, status)
    return success(result, 'Area added.', status)


@system_admin_bp.put('/areas/<int:area_id>')
@roles_required('system_admin')
def update_area_route(area_id):
    result, message, status = update_area(area_id, _payload(), int(get_jwt_identity()))
    return _mutation_result(result, message, status, 'Maintenance area updated.')


@system_admin_bp.patch('/areas/<int:area_id>/status')
@roles_required('system_admin')
def area_status_route(area_id):
    result, message, status = set_area_status(area_id, _status_value(_payload()), int(get_jwt_identity()))
    return _mutation_result(result, message, status, 'Maintenance area status updated.')


@system_admin_bp.get('/units')
@roles_required('system_admin')
def units_route():
    return success({'units': _unit_data(), 'buildings': _building_data(), 'floors': locations().get('floors', [])}, 'Units loaded.')


@system_admin_bp.post('/units')
@roles_required('system_admin')
def create_unit_route():
    result, message, status = create_unit(_payload(), int(get_jwt_identity()))
    return _mutation_result(result, message, status, 'Unit added.')


@system_admin_bp.put('/units/<int:unit_id>')
@roles_required('system_admin')
def update_unit_route(unit_id):
    result, message, status = update_unit(unit_id, _payload(), int(get_jwt_identity()))
    return _mutation_result(result, message, status, 'Unit updated.')


@system_admin_bp.patch('/units/<int:unit_id>/status')
@roles_required('system_admin')
def unit_status_route(unit_id):
    result, message, status = set_unit_status(unit_id, _status_value(_payload()), int(get_jwt_identity()))
    return _mutation_result(result, message, status, 'Unit status updated.')


@system_admin_bp.get('/safety-rules')
@roles_required('system_admin')
def safety_rules_route():
    return success({'rules': _safety_rule_data(), 'categories': _category_data()}, 'Safety rules loaded.')


@system_admin_bp.post('/safety-rules')
@roles_required('system_admin')
def create_safety_rule_route():
    payload = _payload()
    user_id = int(get_jwt_identity())
    result, message, status = create_safety_rule(payload, user_id)
    if not result:
        return error(message, status)
    # The original creation service predates technician_action. Reuse the validated update
    # service so every field visible on the final System Admin form is persisted.
    if payload.get('technician_action'):
        updated, update_message, update_status = update_safety_rule(int(result['id']), payload, user_id)
        if not updated:
            return error(update_message, update_status)
    return success(result, 'Safety rule added.', status)


@system_admin_bp.put('/safety-rules/<int:rule_id>')
@roles_required('system_admin')
def update_safety_rule_route(rule_id):
    result, message, status = update_safety_rule(rule_id, _payload(), int(get_jwt_identity()))
    return _mutation_result(result, message, status, 'Safety rule updated.')


@system_admin_bp.patch('/safety-rules/<int:rule_id>/status')
@roles_required('system_admin')
def safety_rule_status_route(rule_id):
    result, message, status = set_safety_rule_status(rule_id, _status_value(_payload()), int(get_jwt_identity()))
    return _mutation_result(result, message, status, 'Safety rule status updated.')


@system_admin_bp.get('/settings')
@roles_required('system_admin')
def settings_route():
    return success({'settings': settings()}, 'System settings loaded.')


@system_admin_bp.put('/settings')
@roles_required('system_admin')
def update_settings_route():
    ok, message, status = update_settings(_payload(), int(get_jwt_identity()))
    if not ok:
        return error(message, status)
    return success(message='System settings updated.')


@system_admin_bp.get('/audit-logs')
@roles_required('system_admin')
def audit_route():
    data = audit_logs(
        search=request.args.get('search','').strip(), action=request.args.get('action','').strip(),
        entity=request.args.get('entity','').strip(), user=request.args.get('user','').strip(),
        date_from=request.args.get('date_from','').strip(), date_to=request.args.get('date_to','').strip(),
        page=request.args.get('page',1), per_page=request.args.get('per_page',25),
    )
    return success(data, 'Audit logs loaded.')


@system_admin_bp.get('/registration-requests')
@roles_required('system_admin')
def registration_requests_route():
    return success({'requests': list_registration_requests(request.args.get('status','Pending'))}, 'Registration requests loaded.')


@system_admin_bp.post('/registration-requests/<int:request_id>/review')
@roles_required('system_admin')
def registration_review_route(request_id):
    p = _payload()
    result, message, status = review_registration_request(request_id, int(get_jwt_identity()), 'system_admin', p.get('action'), p.get('note',''))
    if not result:
        return error(message, status)
    return success(result, 'Registration request reviewed.', status)


@system_admin_bp.get('/password-reset-requests')
@roles_required('system_admin')
def password_reset_requests_route():
    # Primary source is the unused reset-token record created by Forgot Password.
    # A notification fallback is also included so an already-created request is
    # still visible if an older local database missed the token record.
    token_rows = query_all(
        """
        SELECT prt.reset_token_id,prt.user_id,prt.created_at,prt.expires_at,
               u.full_name,u.email,u.account_status,u.is_deleted,r.role_name
        FROM password_reset_tokens prt
        INNER JOIN users u ON u.user_id=prt.user_id
        INNER JOIN roles r ON r.role_id=u.role_id
        WHERE prt.used_at IS NULL
          AND prt.expires_at > NOW()
        ORDER BY prt.created_at DESC,prt.reset_token_id DESC
        """
    )

    by_user = {}
    for row in token_rows:
        uid = int(row['user_id'])
        if uid in by_user:
            continue
        by_user[uid] = {
            'requestId': int(row['reset_token_id']),
            'userId': uid,
            'name': row.get('full_name') or 'User',
            'email': row.get('email') or '',
            'role': row.get('role_name') or '',
            'accountStatus': row.get('account_status') or '',
            'deleted': bool(row.get('is_deleted')),
            'requestedAt': row['created_at'].isoformat() if row.get('created_at') else None,
            'expiresAt': row['expires_at'].isoformat() if row.get('expires_at') else None,
            'source': 'token',
        }

    # Fallback for older local builds. Only password-reset notifications that
    # have not been handled are considered. Exact email matching avoids showing
    # the action on another account.
    notification_rows = query_all(
        """
        SELECT n.message,n.created_at
        FROM notifications n
        INNER JOIN users au ON au.user_id=n.user_id
        INNER JOIN roles ar ON ar.role_id=au.role_id
        WHERE ar.role_code='system_admin'
          AND n.event_type='Password Reset Request'
          AND n.read_at IS NULL
        ORDER BY n.created_at DESC,n.notification_id DESC
        """
    )
    if notification_rows:
        active_users = query_all(
            """
            SELECT u.user_id,u.full_name,u.email,u.account_status,u.is_deleted,r.role_name
            FROM users u INNER JOIN roles r ON r.role_id=u.role_id
            WHERE u.is_deleted=FALSE
            """
        )
        for user in active_users:
            uid = int(user['user_id'])
            if uid in by_user:
                continue
            email = (user.get('email') or '').strip().lower()
            if not email:
                continue
            matched = next((n for n in notification_rows if email in (n.get('message') or '').lower()), None)
            if not matched:
                continue
            by_user[uid] = {
                'requestId': None,
                'userId': uid,
                'name': user.get('full_name') or 'User',
                'email': user.get('email') or '',
                'role': user.get('role_name') or '',
                'accountStatus': user.get('account_status') or '',
                'deleted': bool(user.get('is_deleted')),
                'requestedAt': matched['created_at'].isoformat() if matched.get('created_at') else None,
                'expiresAt': None,
                'source': 'notification',
            }

    data = sorted(by_user.values(), key=lambda x: x.get('requestedAt') or '', reverse=True)
    return success({'requests': data}, 'Password reset requests loaded.')


@system_admin_bp.get('/notifications')
@roles_required('system_admin')
def notifications_route():
    return success({'notifications': list_notifications(int(get_jwt_identity()))}, 'Notifications loaded.')


@system_admin_bp.post('/notifications/read-all')
@roles_required('system_admin')
def notifications_read_all_route():
    return success({'updated': mark_notifications_read(int(get_jwt_identity()))}, 'Notifications marked as read.')


@system_admin_bp.get('/profile')
@roles_required('system_admin')
def system_admin_profile_route():
    user_id = int(get_jwt_identity())
    row = query_one(
        """
        SELECT u.user_id,u.full_name,u.email,u.phone,u.account_status,
               u.email_verified,u.last_login_at,u.created_at
        FROM users u
        INNER JOIN roles r ON r.role_id=u.role_id
        WHERE u.user_id=%s AND r.role_code='system_admin' AND u.is_deleted=FALSE
        LIMIT 1
        """,
        (user_id,),
    )
    if not row:
        return error('System Admin profile not found.', 404)
    return success({'profile': {
        'name': row.get('full_name') or '', 'email': row.get('email') or '',
        'phone': row.get('phone') or '', 'status': row.get('account_status') or 'Active',
        'emailVerified': bool(row.get('email_verified')),
        'lastLogin': row['last_login_at'].isoformat() if row.get('last_login_at') else None,
        'created': row['created_at'].isoformat() if row.get('created_at') else None,
    }}, 'System Admin profile loaded.')


@system_admin_bp.put('/profile')
@roles_required('system_admin')
def update_system_admin_profile_route():
    payload = _payload()
    user_id = int(get_jwt_identity())
    name = clean_text(payload.get('name'), 150)
    phone = normalize_mobile(payload.get('phone'))
    if not validate_name(name):
        return error('Enter a valid full name.', 400)
    if not validate_mobile(phone, required=True):
        return error('Enter a valid Sri Lankan mobile number such as 0771234567 or +94771234567.', 400)
    connection = get_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute('UPDATE users SET full_name=%s,phone=%s,updated_at=NOW() WHERE user_id=%s AND is_deleted=FALSE', (name, phone, user_id))
            if cursor.rowcount == 0:
                connection.rollback()
                return error('System Admin account could not be found.', 404)
            cursor.execute(
                "INSERT INTO audit_logs(user_id,action_type,entity_type,entity_id,reason) VALUES(%s,'PROFILE_UPDATED','User',%s,'System Admin updated own profile')",
                (user_id, str(user_id)),
            )
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()
    return success(message='System Admin profile updated.')


@system_admin_bp.get('/backup/records')
@roles_required('system_admin')
def backup_records_route():
    return success({'records': backup_records(50)}, 'Data export history loaded.')


@system_admin_bp.get('/backup/export')
@roles_required('system_admin')
def backup_export_route():
    data = export_data_snapshot(int(get_jwt_identity()))
    response = jsonify(data)
    response.headers['Content-Disposition'] = 'attachment; filename=helafixit_data_export.json'
    return response
