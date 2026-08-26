from flask import Blueprint, current_app, request
from flask_jwt_extended import get_jwt_identity

from services.ticket_service import (
    add_repair_note, complete_job, get_ticket, list_notifications, mark_notifications_read,
    technician_dashboard, technician_jobs, technician_profile_for_user,
    update_job_status, update_own_technician_profile,
)
from utils.auth_decorators import roles_required
from utils.responses import error, success

technician_bp = Blueprint('technician', __name__, url_prefix='/api/technician')


@technician_bp.get('/dashboard')
@roles_required('technician')
def dashboard():
    return success(technician_dashboard(int(get_jwt_identity())), 'Technician dashboard loaded.')


@technician_bp.get('/jobs')
@roles_required('technician')
def jobs():
    rows = technician_jobs(
        int(get_jwt_identity()), request.args.get('status','').strip(),
        request.args.get('emergency','').lower() in ('1','true','yes'),
    )
    return success({'jobs': rows}, 'Technician jobs loaded.')


@technician_bp.get('/jobs/<ticket_number>')
@roles_required('technician')
def job_details(ticket_number):
    ticket = get_ticket(ticket_number, int(get_jwt_identity()), 'technician')
    if not ticket: return error('Assigned job not found.', 404)
    return success({'ticket': ticket}, 'Job details loaded.')


@technician_bp.post('/jobs/<ticket_number>/status')
@roles_required('technician')
def job_status(ticket_number):
    payload = request.get_json(silent=True) or {}
    result, message, status = update_job_status(
        int(get_jwt_identity()), ticket_number, payload.get('status'), payload.get('note','')
    )
    if not result: return error(message, status)
    return success({'ticket': result}, 'Job status updated.')


@technician_bp.post('/jobs/<ticket_number>/repair-note')
@roles_required('technician')
def repair_note(ticket_number):
    payload = request.get_json(silent=True) or {}
    result, message, status = add_repair_note(int(get_jwt_identity()), ticket_number, payload.get('note'))
    if not result: return error(message, status)
    return success({'ticket': result}, 'Repair note saved.')


@technician_bp.post('/jobs/<ticket_number>/complete')
@roles_required('technician')
def complete(ticket_number):
    result, message, status = complete_job(
        int(get_jwt_identity()), ticket_number, request.form.get('summary',''),
        request.files.get('image'), current_app.config['UPLOAD_FOLDER'],
    )
    if not result and message: return error(message, status)
    if message and status >= 400: return error(message, status, {'ticket': result})
    return success({'ticket': result}, 'Maintenance job marked resolved.')




@technician_bp.post('/notifications/read-all')
@roles_required('technician')
def read_all_notifications():
    return success({'updated': mark_notifications_read(int(get_jwt_identity()))}, 'Notifications marked as read.')


@technician_bp.get('/profile')
@roles_required('technician')
def profile():
    data = technician_profile_for_user(int(get_jwt_identity()))
    if not data: return error('Technician profile not found.', 404)
    return success({'profile': data}, 'Technician profile loaded.')


@technician_bp.put('/profile')
@roles_required('technician')
def update_profile():
    payload = request.get_json(silent=True) or {}
    result, message, status = update_own_technician_profile(
        int(get_jwt_identity()), payload.get('name'), payload.get('phone'), payload.get('availability')
    )
    if not result: return error(message, status)
    return success({'profile': result}, 'Technician profile updated.')


@technician_bp.get('/notifications')
@roles_required('technician')
def notifications():
    return success({'notifications': list_notifications(int(get_jwt_identity()))}, 'Notifications loaded.')
