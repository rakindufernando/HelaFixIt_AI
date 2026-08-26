from flask import Blueprint, current_app, request
from flask_jwt_extended import get_jwt_identity

from database import get_connection, query_one
from services.ticket_service import (
    create_ticket, get_ticket, list_notifications, mark_notifications_read,
    resident_dashboard, resident_ticket_options, resident_tickets,
)
from utils.auth_decorators import roles_required
from utils.responses import error, success
from utils.validators import clean_text, normalize_mobile, validate_mobile, validate_name

resident_bp = Blueprint('resident', __name__, url_prefix='/api/resident')


def client_ip():
    forwarded = request.headers.get('X-Forwarded-For', '')
    return (forwarded.split(',')[0].strip() if forwarded else (request.remote_addr or ''))[:45]


@resident_bp.get('/dashboard')
@roles_required('resident')
def dashboard():
    return success(resident_dashboard(int(get_jwt_identity())), 'Resident dashboard loaded.')


@resident_bp.get('/ticket-options')
@roles_required('resident')
def ticket_options():
    data = resident_ticket_options(int(get_jwt_identity()))
    if not data:
        return error('Resident profile could not be found.', 404)
    return success(data, 'Ticket location options loaded.')


@resident_bp.post('/tickets')
@roles_required('resident')
def submit_ticket():
    payload = request.form.to_dict() if request.content_type and 'multipart/form-data' in request.content_type else (request.get_json(silent=True) or {})
    upload_file = request.files.get('image')
    result, message, status = create_ticket(
        int(get_jwt_identity()), payload, upload_file,
        current_app.config['UPLOAD_FOLDER'], client_ip(), request.headers.get('User-Agent', ''),
    )
    if not result:
        return error(message, status)
    return success({'ticket': result}, 'Maintenance ticket submitted.', status)


@resident_bp.get('/tickets')
@roles_required('resident')
def my_tickets():
    rows = resident_tickets(
        int(get_jwt_identity()), request.args.get('search','').strip(),
        request.args.get('status','').strip(), request.args.get('priority','').strip(),
    )
    return success({'tickets': rows}, 'Resident tickets loaded.')


@resident_bp.get('/tickets/<ticket_number>')
@roles_required('resident')
def ticket_details(ticket_number):
    ticket = get_ticket(ticket_number, int(get_jwt_identity()), 'resident')
    if not ticket:
        return error('Ticket not found.', 404)
    return success({'ticket': ticket}, 'Ticket details loaded.')


@resident_bp.get('/tickets/<ticket_number>/analysis')
@roles_required('resident')
def ticket_analysis(ticket_number):
    ticket = get_ticket(ticket_number, int(get_jwt_identity()), 'resident')
    if not ticket:
        return error('Ticket not found.', 404)
    return success({'ticket': ticket}, 'Ticket analysis state loaded.')


@resident_bp.get('/profile')
@roles_required('resident')
def resident_profile():
    user_id = int(get_jwt_identity())
    row = query_one(
        """
        SELECT
            u.user_id, u.full_name, u.email, u.phone, u.account_status,
            rp.resident_id, rp.resident_type, rp.preferred_language, rp.contact_preference,
            rp.unit_number AS profile_unit_number,
            b.block_code, b.name AS building_name,
            f.floor_number, f.name AS floor_name,
            COALESCE(un.unit_number, rp.unit_number) AS unit_number
        FROM users u
        INNER JOIN resident_profiles rp ON rp.user_id = u.user_id
        LEFT JOIN buildings b ON b.building_id = rp.building_id
        LEFT JOIN floors f ON f.floor_id = rp.floor_id
        LEFT JOIN units un ON un.unit_id = rp.unit_id
        WHERE u.user_id = %s AND u.is_deleted = FALSE
        LIMIT 1
        """,
        (user_id,),
    )
    if not row:
        return error('Resident profile could not be found.', 404)
    floor_label = row.get('floor_name') or (str(row.get('floor_number')) if row.get('floor_number') is not None else '')
    return success({'profile': {
        'name': row.get('full_name') or '',
        'email': row.get('email') or '',
        'phone': row.get('phone') or '',
        'block': row.get('block_code') or '',
        'building': row.get('building_name') or '',
        'floor': floor_label,
        'unitNumber': row.get('unit_number') or row.get('profile_unit_number') or '',
        'residentType': row.get('resident_type') or '',
        'preferredLanguage': row.get('preferred_language') or 'English',
        'contactPreference': row.get('contact_preference') or 'In App',
        'status': row.get('account_status') or 'Active',
    }}, 'Resident profile loaded.')


@resident_bp.put('/profile')
@roles_required('resident')
def update_resident_profile():
    payload = request.get_json(silent=True) or {}
    user_id = int(get_jwt_identity())
    name = clean_text(payload.get('name'), 150)
    phone = normalize_mobile(payload.get('phone'))
    language = clean_text(payload.get('preferred_language'), 20) or 'English'
    contact = clean_text(payload.get('contact_preference'), 20) or 'In App'
    if not validate_name(name):
        return error('Enter a valid full name.', 400)
    if not validate_mobile(phone, required=True):
        return error('Enter a valid Sri Lankan mobile number such as 0771234567 or +94771234567.', 400)
    if language not in {'English', 'Sinhala', 'Singlish', 'Mixed'}:
        return error('Select a valid preferred language.', 400)
    if contact not in {'In App', 'Email', 'SMS', 'Phone'}:
        return error('Select a valid contact preference.', 400)
    connection = get_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute(
                "UPDATE users SET full_name=%s, phone=%s, updated_at=NOW() WHERE user_id=%s AND is_deleted=FALSE",
                (name, phone, user_id),
            )
            if cursor.rowcount == 0:
                connection.rollback()
                return error('Resident account could not be found.', 404)
            cursor.execute(
                """
                UPDATE resident_profiles
                SET preferred_language=%s, contact_preference=%s
                WHERE user_id=%s
                """,
                (language, contact, user_id),
            )
            cursor.execute(
                """
                INSERT INTO audit_logs(user_id, action_type, entity_type, entity_id, reason)
                VALUES(%s, 'PROFILE_UPDATED', 'User', %s, 'Resident updated own profile')
                """,
                (user_id, str(user_id)),
            )
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()
    return success(message='Resident profile updated.')


@resident_bp.get('/notifications')
@roles_required('resident')
def notifications():
    return success({'notifications': list_notifications(int(get_jwt_identity()))}, 'Notifications loaded.')


@resident_bp.post('/notifications/read-all')
@roles_required('resident')
def read_all():
    changed = mark_notifications_read(int(get_jwt_identity()))
    return success({'updated': changed}, 'Notifications marked as read.')
