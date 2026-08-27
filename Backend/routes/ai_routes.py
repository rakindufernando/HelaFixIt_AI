from flask import Blueprint, request
from flask_jwt_extended import get_jwt_identity

from database import query_one
from services.ai_service import ai_status, analyse_ticket_number
from utils.auth_decorators import roles_required
from utils.responses import error, success

ai_bp = Blueprint('ai', __name__, url_prefix='/api/ai')


def client_ip():
    forwarded = request.headers.get('X-Forwarded-For', '')
    return (forwarded.split(',')[0].strip() if forwarded else (request.remote_addr or ''))[:45]


def can_manage_ticket(user_id, ticket_number):
    """System Admins can analyse any ticket. Apartment Admins are limited to their building."""
    user = query_one(
        """
        SELECT r.role_code,ap.primary_building_id
        FROM users u
        INNER JOIN roles r ON r.role_id=u.role_id
        LEFT JOIN apartment_admin_profiles ap ON ap.user_id=u.user_id AND ap.active=TRUE
        WHERE u.user_id=%s LIMIT 1
        """,
        (user_id,),
    )
    if not user:
        return False
    if user.get('role_code') == 'system_admin':
        return True
    if user.get('role_code') != 'apartment_admin' or not user.get('primary_building_id'):
        return False
    ticket = query_one(
        'SELECT ticket_id FROM maintenance_tickets WHERE ticket_number=%s AND building_id=%s LIMIT 1',
        (ticket_number, int(user['primary_building_id'])),
    )
    return bool(ticket)


@ai_bp.get('/status')
@roles_required('apartment_admin', 'system_admin')
def status():
    state = ai_status()
    return success(state, 'AI module status loaded.') if state.get('ready') else error(state.get('error', 'AI module is not ready.'), 503)


@ai_bp.post('/tickets/<ticket_number>/analyse')
@roles_required('apartment_admin', 'system_admin')
def analyse(ticket_number):
    user_id = int(get_jwt_identity())
    if not can_manage_ticket(user_id, ticket_number):
        return error('Ticket not found or not available to this account.', 404)
    result, message = analyse_ticket_number(
        ticket_number,
        initiated_by=user_id,
        ip_address=client_ip(),
        user_agent=request.headers.get('User-Agent', ''),
    )
    if not result:
        return error(message or 'Ticket analysis failed.', 404)
    return success({'analysis': result}, 'Ticket analysed using the local HelaFixIt AI module.')
