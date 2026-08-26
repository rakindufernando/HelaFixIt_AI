from flask import Blueprint, request
from flask_jwt_extended import get_jwt_identity

from database import get_connection, query_one
from services.registration_service import list_registration_requests, review_registration_request
from services.report_service import admin_report_data
from services.ticket_service import (
    admin_dashboard, admin_technicians, admin_tickets, assign_technician,
    categories, duplicate_groups, get_ticket, list_notifications, mark_notifications_read,
    review_ticket, technician_candidates, update_technician_availability, review_duplicate_match,
)
from utils.auth_decorators import roles_required
from utils.responses import error, success
from utils.validators import clean_text, normalize_mobile, validate_mobile, validate_name, validate_plain_text

admin_bp = Blueprint('admin', __name__, url_prefix='/api/admin')


def client_ip():
    forwarded = request.headers.get('X-Forwarded-For', '')
    return (forwarded.split(',')[0].strip() if forwarded else (request.remote_addr or ''))[:45]


def admin_scope(user_id):
    return query_one(
        """
        SELECT ap.primary_building_id,b.block_code,b.name AS building_name
        FROM apartment_admin_profiles ap
        LEFT JOIN buildings b ON b.building_id=ap.primary_building_id
        WHERE ap.user_id=%s AND ap.active=TRUE
        LIMIT 1
        """,
        (user_id,),
    )


def scoped_building_or_error(user_id):
    scope = admin_scope(user_id)
    if not scope or not scope.get('primary_building_id'):
        return None, error('No apartment building is assigned to this administrator.', 403)
    return scope, None


def ticket_in_admin_scope(user_id, ticket_number):
    scope = admin_scope(user_id)
    if not scope or not scope.get('primary_building_id'):
        return False
    row = query_one(
        'SELECT ticket_id FROM maintenance_tickets WHERE ticket_number=%s AND building_id=%s LIMIT 1',
        (ticket_number, int(scope['primary_building_id'])),
    )
    return bool(row)


def technician_in_admin_scope(user_id, technician_id):
    scope = admin_scope(user_id)
    if not scope or not scope.get('primary_building_id'):
        return False
    row = query_one(
        """
        SELECT technician_id FROM technician_profiles
        WHERE technician_id=%s AND assigned_building_id=%s AND active=TRUE
        LIMIT 1
        """,
        (technician_id, int(scope['primary_building_id'])),
    )
    return bool(row)


@admin_bp.get('/dashboard')
@roles_required('apartment_admin')
def dashboard():
    user_id = int(get_jwt_identity())
    scope, denied = scoped_building_or_error(user_id)
    if denied: return denied
    building_id = int(scope['primary_building_id'])
    rows = [x for x in admin_tickets() if int(x.get('buildingId') or 0) == building_id]
    for item in rows: item.pop('residentEmail', None)
    technicians = [x for x in admin_technicians() if x.get('block') == scope.get('block_code')]
    closed = {'Resolved','Closed','Cancelled'}
    active = [x for x in rows if x.get('status') not in closed]
    pending = {'Submitted','Analysing','Awaiting Review','Urgent Unassigned'}
    data = {
        'stats': {
            'active': len(active),
            'pending_review': sum(1 for x in rows if x.get('status') in pending),
            'emergency': sum(1 for x in active if x.get('emergency')),
            'available_technicians': sum(1 for x in technicians if x.get('status') == 'Available'),
        },
        'recent_tickets': rows[:6],
        'emergencies': [x for x in active if x.get('emergency')][:4],
        'scope': {'buildingId': building_id, 'block': scope.get('block_code'), 'building': scope.get('building_name')},
    }
    return success(data, 'Apartment admin dashboard loaded.')


@admin_bp.get('/tickets')
@roles_required('apartment_admin')
def tickets():
    user_id = int(get_jwt_identity())
    scope, denied = scoped_building_or_error(user_id)
    if denied: return denied
    rows = admin_tickets(
        request.args.get('search','').strip(), request.args.get('status','').strip(),
        request.args.get('priority','').strip(), request.args.get('category','').strip(),
    )
    building_id = int(scope['primary_building_id'])
    rows = [x for x in rows if int(x.get('buildingId') or 0) == building_id]
    for item in rows: item.pop('residentEmail', None)
    return success({'tickets': rows}, 'Ticket queue loaded.')


@admin_bp.get('/tickets/<ticket_number>')
@roles_required('apartment_admin')
def ticket_details(ticket_number):
    user_id = int(get_jwt_identity())
    if not ticket_in_admin_scope(user_id, ticket_number):
        return error('Ticket not found in your assigned building.', 404)
    ticket = get_ticket(ticket_number)
    if not ticket: return error('Ticket not found.', 404)
    ticket.pop('residentEmail', None)
    return success({'ticket': ticket, 'categories': categories()}, 'Ticket review details loaded.')


@admin_bp.post('/tickets/<ticket_number>/review')
@roles_required('apartment_admin')
def review(ticket_number):
    user_id = int(get_jwt_identity())
    if not ticket_in_admin_scope(user_id, ticket_number):
        return error('Ticket not found in your assigned building.', 404)
    payload = request.get_json(silent=True) or {}
    result, message, status = review_ticket(
        user_id, ticket_number, payload.get('category'), payload.get('priority'),
        payload.get('note'), client_ip(), request.headers.get('User-Agent',''),
    )
    if not result: return error(message, status)
    result.pop('residentEmail', None)
    return success({'ticket': result}, 'Admin review saved.')


@admin_bp.get('/tickets/<ticket_number>/technicians')
@roles_required('apartment_admin')
def assignment_options(ticket_number):
    user_id = int(get_jwt_identity())
    if not ticket_in_admin_scope(user_id, ticket_number):
        return error('Ticket not found in your assigned building.', 404)
    scope, denied = scoped_building_or_error(user_id)
    if denied: return denied
    data = technician_candidates(ticket_number)
    if not data: return error('Ticket not found.', 404)
    data['ticket'].pop('residentEmail', None)
    data['candidates'] = [x for x in data.get('candidates', []) if x.get('block') == scope.get('block_code')]
    return success(data, 'Technician candidates loaded.')


@admin_bp.post('/tickets/<ticket_number>/assign')
@roles_required('apartment_admin')
def assign(ticket_number):
    user_id = int(get_jwt_identity())
    if not ticket_in_admin_scope(user_id, ticket_number):
        return error('Ticket not found in your assigned building.', 404)
    payload = request.get_json(silent=True) or {}
    try:
        technician_id = int(payload.get('technician_id'))
    except (TypeError, ValueError):
        return error('Select a valid technician.', 400)
    if not technician_in_admin_scope(user_id, technician_id):
        return error('The selected technician is not assigned to your building.', 403)
    result, message, status = assign_technician(
        user_id, ticket_number, technician_id, payload.get('reason'),
        client_ip(), request.headers.get('User-Agent',''),
    )
    if not result: return error(message, status)
    result.pop('residentEmail', None)
    return success({'ticket': result}, 'Technician assigned successfully.')


@admin_bp.get('/emergencies')
@roles_required('apartment_admin')
def emergencies():
    user_id = int(get_jwt_identity())
    scope, denied = scoped_building_or_error(user_id)
    if denied: return denied
    building_id = int(scope['primary_building_id'])
    rows = [t for t in admin_tickets() if int(t.get('buildingId') or 0) == building_id and t['emergency']]
    for item in rows: item.pop('residentEmail', None)
    return success({'tickets': rows}, 'Emergency tickets loaded.')


@admin_bp.get('/duplicates')
@roles_required('apartment_admin')
def duplicates():
    user_id = int(get_jwt_identity())
    scope, denied = scoped_building_or_error(user_id)
    if denied: return denied
    block = scope.get('block_code')
    rows = [x for x in duplicate_groups() if x.get('source',{}).get('block') == block and x.get('matched',{}).get('block') == block]
    return success({'duplicates': rows}, 'Duplicate review data loaded.')


@admin_bp.get('/technicians')
@roles_required('apartment_admin')
def technicians():
    user_id = int(get_jwt_identity())
    scope, denied = scoped_building_or_error(user_id)
    if denied: return denied
    rows = [x for x in admin_technicians() if x.get('block') == scope.get('block_code')]
    return success({'technicians': rows}, 'Technicians loaded.')


@admin_bp.patch('/technicians/<int:technician_id>/availability')
@roles_required('apartment_admin')
def technician_availability(technician_id):
    user_id = int(get_jwt_identity())
    if not technician_in_admin_scope(user_id, technician_id):
        return error('Technician not found in your assigned building.', 404)
    payload = request.get_json(silent=True) or {}
    if not update_technician_availability(technician_id, payload.get('availability')):
        return error('Technician or availability status is invalid.', 400)
    return success(message='Technician availability updated.')


@admin_bp.get('/notifications')
@roles_required('apartment_admin')
def notifications():
    return success({'notifications': list_notifications(int(get_jwt_identity()))}, 'Notifications loaded.')


@admin_bp.post('/notifications/read-all')
@roles_required('apartment_admin')
def read_all():
    return success({'updated': mark_notifications_read(int(get_jwt_identity()))}, 'Notifications marked as read.')


@admin_bp.get('/registration-requests')
@roles_required('apartment_admin')
def registration_requests():
    return success({'requests': list_registration_requests(request.args.get('status','Pending'), int(get_jwt_identity()), 'apartment_admin')}, 'Registration requests loaded.')


@admin_bp.post('/registration-requests/<int:request_id>/review')
@roles_required('apartment_admin')
def registration_review(request_id):
    payload = request.get_json(silent=True) or {}
    result, message, status = review_registration_request(request_id, int(get_jwt_identity()), 'apartment_admin', payload.get('action'), payload.get('note',''))
    if not result:
        return error(message, status)
    return success(result, 'Registration request reviewed.', status)


@admin_bp.get('/categories')
@roles_required('apartment_admin')
def category_options():
    return success({'categories': categories()}, 'Issue categories loaded.')


@admin_bp.post('/duplicates/<int:match_id>/review')
@roles_required('apartment_admin')
def duplicate_review(match_id):
    user_id = int(get_jwt_identity())
    scope, denied = scoped_building_or_error(user_id)
    if denied: return denied
    record = query_one(
        """
        SELECT dm.duplicate_match_id
        FROM duplicate_matches dm
        INNER JOIN maintenance_tickets s ON s.ticket_id=dm.source_ticket_id
        INNER JOIN maintenance_tickets m ON m.ticket_id=dm.matched_ticket_id
        WHERE dm.duplicate_match_id=%s AND s.building_id=%s AND m.building_id=%s
        LIMIT 1
        """,
        (match_id, int(scope['primary_building_id']), int(scope['primary_building_id'])),
    )
    if not record: return error('Duplicate record not found in your assigned building.', 404)
    payload=request.get_json(silent=True) or {}
    result,message,status=review_duplicate_match(user_id,match_id,payload.get('action'),payload.get('note'),client_ip(),request.headers.get('User-Agent',''))
    if not result: return error(message,status)
    return success(result,'Duplicate review saved.')


@admin_bp.get('/reports')
@roles_required('apartment_admin')
def reports():
    user_id = int(get_jwt_identity())
    scope, denied = scoped_building_or_error(user_id)
    if denied: return denied
    return success(admin_report_data(int(scope['primary_building_id'])), 'Maintenance reports loaded.')


@admin_bp.get('/profile')
@roles_required('apartment_admin')
def admin_profile():
    row = query_one("""
        SELECT u.user_id,u.full_name,u.email,u.phone,ap.job_title,ap.can_review_emergencies,b.block_code,b.name AS building_name
        FROM users u JOIN apartment_admin_profiles ap ON ap.user_id=u.user_id
        LEFT JOIN buildings b ON b.building_id=ap.primary_building_id
        WHERE u.user_id=%s LIMIT 1
    """, (int(get_jwt_identity()),))
    if not row:
        return error('Apartment Admin profile not found.',404)
    return success({'profile':{
        'name':row['full_name'],'email':row['email'],'phone':row.get('phone') or '',
        'jobTitle':row.get('job_title') or 'Apartment Administrator','block':row.get('block_code') or '',
        'building':row.get('building_name') or 'All buildings','canReviewEmergencies':bool(row.get('can_review_emergencies'))
    }}, 'Apartment Admin profile loaded.')


@admin_bp.put('/profile')
@roles_required('apartment_admin')
def update_admin_profile():
    payload=request.get_json(silent=True) or {}
    name=clean_text(payload.get('name'),150); phone=normalize_mobile(payload.get('phone')); job=clean_text(payload.get('job_title'),100)
    if not validate_name(name):
        return error('Enter a valid full name.',400)
    if phone and not validate_mobile(phone):
        return error('Enter a valid Sri Lankan mobile number such as 0771234567 or +94771234567.',400)
    if job and not validate_plain_text(job,2,100):
        return error('Enter a valid job title.',400)
    connection=get_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute('UPDATE users SET full_name=%s,phone=%s WHERE user_id=%s',(name,phone or None,int(get_jwt_identity())))
            cursor.execute('UPDATE apartment_admin_profiles SET job_title=%s WHERE user_id=%s',(job or 'Apartment Administrator',int(get_jwt_identity())))
        connection.commit()
    except Exception:
        connection.rollback(); raise
    finally:
        connection.close()
    return success(message='Apartment Admin profile updated.')
