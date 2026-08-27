from flask import Blueprint, jsonify, request
from flask_jwt_extended import get_jwt_identity

from database import get_connection, query_one

from services.registration_service import list_registration_requests, review_registration_request
from services.ticket_service import list_notifications, mark_notifications_read
from services.system_admin_service import (
    audit_logs, buildings, categories, create_area, create_building, create_category,
    create_floor, create_safety_rule, create_skill, create_user, dashboard, export_data_snapshot,
    list_users, locations, roles, safety_rules, settings, skills, update_settings, update_user, user_options,
    get_user_details, reset_user_password, unlock_user, set_email_verified, delete_user, restore_user,
)
from utils.auth_decorators import roles_required
from utils.responses import error, success
from utils.validators import clean_text, normalize_mobile, validate_mobile, validate_name

system_admin_bp = Blueprint('system_admin', __name__, url_prefix='/api/system-admin')

@system_admin_bp.get('/dashboard')
@roles_required('system_admin')
def dashboard_route(): return success(dashboard(), 'System Admin dashboard loaded.')

@system_admin_bp.get('/users')
@roles_required('system_admin')
def users_route(): return success({'users':list_users(request.args.get('search','').strip(),request.args.get('role','').strip(),request.args.get('status','').strip(),request.args.get('deleted','active').strip())}, 'Users loaded.')

@system_admin_bp.get('/user-options')
@roles_required('system_admin')
def user_options_route(): return success(user_options(), 'User setup options loaded.')

@system_admin_bp.post('/users')
@roles_required('system_admin')
def create_user_route():
    result,message,status=create_user(request.get_json(silent=True) or {},int(get_jwt_identity()))
    if not result:return error(message,status)
    return success(result,'User account created.',status)

@system_admin_bp.put('/users/<int:user_id>')
@roles_required('system_admin')
def update_user_route(user_id):
    result,message,status=update_user(user_id,request.get_json(silent=True) or {},int(get_jwt_identity()))
    if not result:return error(message,status)
    return success(result,'User account updated.')


@system_admin_bp.get('/users/<int:user_id>')
@roles_required('system_admin')
def user_details_route(user_id):
    data=get_user_details(user_id)
    if not data:return error('User not found.',404)
    return success({'user':data},'User details loaded.')

@system_admin_bp.post('/users/<int:user_id>/reset-password')
@roles_required('system_admin')
def reset_user_password_route(user_id):
    p=request.get_json(silent=True) or {}
    result,message,status=reset_user_password(user_id,p.get('temporary_password') or '',int(get_jwt_identity()))
    if not result:return error(message,status)
    return success(result,'Temporary password set. The user must change it at the next sign in.')

@system_admin_bp.post('/users/<int:user_id>/unlock')
@roles_required('system_admin')
def unlock_user_route(user_id):
    result,message,status=unlock_user(user_id,int(get_jwt_identity()))
    if not result:return error(message,status)
    return success(result,'User account unlocked.')

@system_admin_bp.post('/users/<int:user_id>/email-verification')
@roles_required('system_admin')
def email_verification_route(user_id):
    p=request.get_json(silent=True) or {}
    result,message,status=set_email_verified(user_id,bool(p.get('verified')),int(get_jwt_identity()))
    if not result:return error(message,status)
    return success(result,'Email verification updated.')

@system_admin_bp.delete('/users/<int:user_id>')
@roles_required('system_admin')
def delete_user_route(user_id):
    result,message,status=delete_user(user_id,int(get_jwt_identity()))
    if not result:return error(message,status)
    return success(result,'User account deleted.')

@system_admin_bp.post('/users/<int:user_id>/restore')
@roles_required('system_admin')
def restore_user_route(user_id):
    result,message,status=restore_user(user_id,int(get_jwt_identity()))
    if not result:return error(message,status)
    return success(result,'User account restored.')

@system_admin_bp.get('/roles')
@roles_required('system_admin')
def roles_route(): return success({'roles':roles()},'Roles loaded.')

@system_admin_bp.get('/skills')
@roles_required('system_admin')
def skills_route(): return success({'skills':skills()},'Skills loaded.')

@system_admin_bp.post('/skills')
@roles_required('system_admin')
def create_skill_route():
    p=request.get_json(silent=True) or {}; result,message,status=create_skill(p.get('name'),p.get('description',''))
    if not result:return error(message,status)
    return success(result,'Skill added.',status)

@system_admin_bp.get('/categories')
@roles_required('system_admin')
def categories_route(): return success({'categories':categories(),'skills':skills()},'Categories loaded.')

@system_admin_bp.post('/categories')
@roles_required('system_admin')
def create_category_route():
    result,message,status=create_category(request.get_json(silent=True) or {})
    if not result:return error(message,status)
    return success(result,'Issue category added.',status)

@system_admin_bp.get('/buildings')
@roles_required('system_admin')
def buildings_route(): return success({'buildings':buildings()},'Buildings loaded.')

@system_admin_bp.post('/buildings')
@roles_required('system_admin')
def create_building_route():
    result,message,status=create_building(request.get_json(silent=True) or {})
    if not result:return error(message,status)
    return success(result,'Building added.',status)

@system_admin_bp.get('/locations')
@roles_required('system_admin')
def locations_route(): return success({'buildings':buildings(),**locations()},'Locations loaded.')

@system_admin_bp.post('/floors')
@roles_required('system_admin')
def create_floor_route():
    result,message,status=create_floor(request.get_json(silent=True) or {})
    if not result:return error(message,status)
    return success(result,'Floor added.',status)

@system_admin_bp.post('/areas')
@roles_required('system_admin')
def create_area_route():
    result,message,status=create_area(request.get_json(silent=True) or {})
    if not result:return error(message,status)
    return success(result,'Area added.',status)

@system_admin_bp.get('/safety-rules')
@roles_required('system_admin')
def safety_rules_route(): return success({'rules':safety_rules(),'categories':categories()},'Safety rules loaded.')

@system_admin_bp.post('/safety-rules')
@roles_required('system_admin')
def create_safety_rule_route():
    result,message,status=create_safety_rule(request.get_json(silent=True) or {},int(get_jwt_identity()))
    if not result:return error(message,status)
    return success(result,'Safety rule added.',status)

@system_admin_bp.get('/settings')
@roles_required('system_admin')
def settings_route(): return success({'settings':settings()},'System settings loaded.')

@system_admin_bp.put('/settings')
@roles_required('system_admin')
def update_settings_route():
    ok,message,status=update_settings(request.get_json(silent=True) or {},int(get_jwt_identity()))
    if not ok:
        return error(message,status)
    return success(message='System settings updated.')

@system_admin_bp.get('/audit-logs')
@roles_required('system_admin')
def audit_route():
    data = audit_logs(
        search=request.args.get('search','').strip(),
        action=request.args.get('action','').strip(),
        entity=request.args.get('entity','').strip(),
        user=request.args.get('user','').strip(),
        date_from=request.args.get('date_from','').strip(),
        date_to=request.args.get('date_to','').strip(),
        page=request.args.get('page',1),
        per_page=request.args.get('per_page',25),
    )
    return success(data,'Audit logs loaded.')

@system_admin_bp.get('/registration-requests')
@roles_required('system_admin')
def registration_requests_route():
    return success({'requests':list_registration_requests(request.args.get('status','Pending'))},'Registration requests loaded.')

@system_admin_bp.post('/registration-requests/<int:request_id>/review')
@roles_required('system_admin')
def registration_review_route(request_id):
    p=request.get_json(silent=True) or {}; result,message,status=review_registration_request(request_id,int(get_jwt_identity()),'system_admin',p.get('action'),p.get('note',''))
    if not result:return error(message,status)
    return success(result,'Registration request reviewed.',status)



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
        SELECT u.user_id, u.full_name, u.email, u.phone, u.account_status,
               u.email_verified, u.last_login_at, u.created_at
        FROM users u
        INNER JOIN roles r ON r.role_id = u.role_id
        WHERE u.user_id=%s AND r.role_code='system_admin' AND u.is_deleted=FALSE
        LIMIT 1
        """,
        (user_id,),
    )
    if not row:
        return error('System Admin profile not found.', 404)
    return success({'profile': {
        'name': row.get('full_name') or '',
        'email': row.get('email') or '',
        'phone': row.get('phone') or '',
        'status': row.get('account_status') or 'Active',
        'emailVerified': bool(row.get('email_verified')),
        'lastLogin': row['last_login_at'].isoformat() if row.get('last_login_at') else None,
        'created': row['created_at'].isoformat() if row.get('created_at') else None,
    }}, 'System Admin profile loaded.')


@system_admin_bp.put('/profile')
@roles_required('system_admin')
def update_system_admin_profile_route():
    payload = request.get_json(silent=True) or {}
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
            cursor.execute(
                "UPDATE users SET full_name=%s, phone=%s, updated_at=NOW() WHERE user_id=%s AND is_deleted=FALSE",
                (name, phone, user_id),
            )
            if cursor.rowcount == 0:
                connection.rollback()
                return error('System Admin account could not be found.', 404)
            cursor.execute(
                """
                INSERT INTO audit_logs(user_id, action_type, entity_type, entity_id, reason)
                VALUES(%s, 'PROFILE_UPDATED', 'User', %s, 'System Admin updated own profile')
                """,
                (user_id, str(user_id)),
            )
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()
    return success(message='System Admin profile updated.')

@system_admin_bp.get('/backup/export')
@roles_required('system_admin')
def backup_export_route():
    data=export_data_snapshot(int(get_jwt_identity()))
    response=jsonify(data)
    response.headers['Content-Disposition']='attachment; filename=helafixit_data_export.json'
    return response
