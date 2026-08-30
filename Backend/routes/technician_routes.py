from pathlib import Path

from flask import Blueprint, current_app, request, send_file
from flask_jwt_extended import get_jwt_identity

from database import query_one
from services.lifecycle_service import technician_decline_assignment
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
    if not ticket:
        return error('Assigned job not found.', 404)
    return success({'ticket': ticket}, 'Job details loaded.')


@technician_bp.get('/jobs/<ticket_number>/issue-photo')
@roles_required('technician')
def issue_photo(ticket_number):
    user_id = int(get_jwt_identity())
    ticket = get_ticket(ticket_number, user_id, 'technician')
    if not ticket:
        return error('Assigned job not found.', 404)
    row = query_one(
        """
        SELECT a.storage_path,a.mime_type,a.original_file_name
        FROM ticket_attachments a
        INNER JOIN maintenance_tickets mt ON mt.ticket_id=a.ticket_id
        WHERE mt.ticket_number=%s
          AND a.attachment_type='Issue Photo'
          AND a.deleted_at IS NULL
        ORDER BY a.uploaded_at DESC,a.attachment_id DESC
        LIMIT 1
        """,
        (ticket_number,),
    )
    if not row:
        return error('No resident issue image was uploaded for this ticket.', 404)
    root = Path(current_app.config['UPLOAD_FOLDER']).resolve()
    target = (root / str(row['storage_path'])).resolve()
    try:
        target.relative_to(root)
    except ValueError:
        return error('The stored issue image path is invalid.', 404)
    if not target.is_file():
        return error('The uploaded issue image file could not be found.', 404)
    return send_file(target, mimetype=row.get('mime_type') or None, as_attachment=False, conditional=True)


@technician_bp.post('/jobs/<ticket_number>/decline')
@roles_required('technician')
def decline_job(ticket_number):
    payload = request.get_json(silent=True) or {}
    result, message, status = technician_decline_assignment(int(get_jwt_identity()), ticket_number, payload.get('reason',''))
    if not result:
        return error(message, status)
    return success(result, 'Assignment declined and returned for reassignment.')


@technician_bp.post('/jobs/<ticket_number>/status')
@roles_required('technician')
def job_status(ticket_number):
    payload = request.get_json(silent=True) or {}
    result, message, status = update_job_status(
        int(get_jwt_identity()), ticket_number, payload.get('status'), payload.get('note','')
    )
    if not result:
        return error(message, status)
    return success({'ticket': result}, 'Job status updated.')


@technician_bp.post('/jobs/<ticket_number>/repair-note')
@roles_required('technician')
def repair_note(ticket_number):
    payload = request.get_json(silent=True) or {}
    result, message, status = add_repair_note(int(get_jwt_identity()), ticket_number, payload.get('note'))
    if not result:
        return error(message, status)
    return success({'ticket': result}, 'Repair note saved.')


@technician_bp.post('/jobs/<ticket_number>/complete')
@roles_required('technician')
def complete(ticket_number):
    result, message, status = complete_job(
        int(get_jwt_identity()), ticket_number, request.form.get('summary',''),
        request.files.get('image'), current_app.config['UPLOAD_FOLDER'],
    )
    if not result:
        return error(message or 'Job could not be completed.', status)
    if message and status >= 400:
        return success(
            {'ticket': result, 'warning': message},
            'Maintenance job was resolved, but the completion proof could not be stored.',
        )
    return success({'ticket': result}, 'Maintenance job marked resolved.')


@technician_bp.post('/notifications/read-all')
@roles_required('technician')
def read_all_notifications():
    return success({'updated': mark_notifications_read(int(get_jwt_identity()))}, 'Notifications marked as read.')


@technician_bp.get('/profile')
@roles_required('technician')
def profile():
    data = technician_profile_for_user(int(get_jwt_identity()))
    if not data:
        return error('Technician profile not found.', 404)
    return success({'profile': data}, 'Technician profile loaded.')


@technician_bp.put('/profile')
@roles_required('technician')
def update_profile():
    payload = request.get_json(silent=True) or {}
    result, message, status = update_own_technician_profile(
        int(get_jwt_identity()), payload.get('name'), payload.get('phone'), payload.get('availability')
    )
    if not result:
        return error(message, status)
    return success({'profile': result}, 'Technician profile updated.')


@technician_bp.get('/notifications')
@roles_required('technician')
def notifications():
    return success({'notifications': list_notifications(int(get_jwt_identity()))}, 'Notifications loaded.')
