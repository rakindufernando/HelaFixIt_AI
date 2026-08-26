from flask import Blueprint
from flask_jwt_extended import get_jwt_identity

from utils.auth_decorators import roles_required
from utils.responses import success

role_bp = Blueprint('role_checks', __name__, url_prefix='/api')


@role_bp.get('/resident/ping')
@roles_required('resident')
def resident_ping():
    return success({'user_id': int(get_jwt_identity()), 'role': 'resident'}, 'Resident access confirmed.')


@role_bp.get('/admin/ping')
@roles_required('apartment_admin')
def admin_ping():
    return success({'user_id': int(get_jwt_identity()), 'role': 'apartment_admin'}, 'Apartment Admin access confirmed.')


@role_bp.get('/technician/ping')
@roles_required('technician')
def technician_ping():
    return success({'user_id': int(get_jwt_identity()), 'role': 'technician'}, 'Technician access confirmed.')


@role_bp.get('/system-admin/ping')
@roles_required('system_admin')
def system_admin_ping():
    return success({'user_id': int(get_jwt_identity()), 'role': 'system_admin'}, 'System Admin access confirmed.')
