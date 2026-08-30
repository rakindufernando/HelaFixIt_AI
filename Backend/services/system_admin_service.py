from __future__ import annotations

import json
from datetime import datetime

from flask import current_app

from werkzeug.security import generate_password_hash

from database import get_connection, query_all, query_one
from services.settings_service import get_int_setting
from utils.validators import clean_text, validate_email, validate_password

ROLE_MAP = {
    'resident': 'resident', 'admin': 'apartment_admin', 'apartment_admin': 'apartment_admin',
    'technician': 'technician', 'systemAdmin': 'system_admin', 'system_admin': 'system_admin'
}
FRONT_ROLE = {'resident':'resident','apartment_admin':'admin','technician':'technician','system_admin':'systemAdmin'}


def _bool(value):
    return str(value).lower() in {'1','true','yes','on'}


def dashboard():
    stats = query_one(
        """
        SELECT
          (SELECT COUNT(*) FROM users WHERE is_deleted=FALSE) AS users,
          (SELECT COUNT(*) FROM technician_profiles WHERE active=TRUE) AS technicians,
          (SELECT COUNT(*) FROM issue_categories WHERE active=TRUE) AS categories,
          (SELECT COUNT(*) FROM buildings WHERE status='Active') AS buildings,
          (SELECT COUNT(*) FROM resident_registration_requests WHERE request_status='Pending') AS pending_registrations
        """
    ) or {}
    audit = query_all(
        """
        SELECT al.audit_id,al.action_type,al.entity_type,al.entity_id,al.reason,al.created_at,u.full_name
        FROM audit_logs al LEFT JOIN users u ON u.user_id=al.user_id
        ORDER BY al.created_at DESC LIMIT 8
        """
    )
    return {
        'stats': {k:int(stats.get(k) or 0) for k in ['users','technicians','categories','buildings','pending_registrations']},
        'audit': [{
            'id': int(r['audit_id']), 'action': r['action_type'], 'target': f"{r['entity_type']} {r.get('entity_id') or ''}".strip(),
            'detail': r.get('reason') or '', 'user': r.get('full_name') or 'System',
            'time': r['created_at'].isoformat() if r.get('created_at') else None,
        } for r in audit],
    }


def user_options():
    roles = query_all("SELECT role_code,role_name FROM roles WHERE active=TRUE ORDER BY role_id")
    buildings = query_all("SELECT building_id,block_code,name FROM buildings WHERE status='Active' ORDER BY block_code")
    floors = query_all("SELECT floor_id,building_id,floor_number,name FROM floors WHERE status='Active' ORDER BY building_id,floor_number")
    skills = query_all("SELECT skill_id,skill_name FROM skills WHERE active=TRUE ORDER BY skill_name")
    return {
        'roles': [{'code':r['role_code'],'name':r['role_name'],'frontend':FRONT_ROLE.get(r['role_code'],r['role_code'])} for r in roles],
        'buildings': [{'id':int(b['building_id']),'code':b['block_code'],'name':b['name']} for b in buildings],
        'floors': [{'id':int(f['floor_id']),'buildingId':int(f['building_id']),'number':int(f['floor_number']),'name':f['name']} for f in floors],
        'skills': [{'id':int(s['skill_id']),'name':s['skill_name']} for s in skills],
        'defaultTechnicianMaxJobs': get_int_setting('technician_default_max_jobs', 4, 1, 20),
        'defaultStaffPassword': current_app.config['DEFAULT_STAFF_PASSWORD'],
    }


def list_users(search='', role='', status='', deleted='active'):
    where=['1=1']; params=[]
    if deleted == 'deleted':
        where.append('u.is_deleted=TRUE')
    elif deleted != 'all':
        where.append('u.is_deleted=FALSE')
    if search:
        where.append('(u.full_name LIKE %s OR u.email LIKE %s OR u.phone LIKE %s OR CAST(u.user_id AS CHAR) LIKE %s)')
        q=f'%{search}%'; params += [q,q,q,q]
    if role:
        where.append('r.role_code=%s'); params.append(ROLE_MAP.get(role,role))
    if status and status != 'Deleted':
        where.append('u.account_status=%s'); params.append(status)
    rows=query_all(
        f"""
        SELECT u.user_id,u.full_name,u.email,u.phone,u.account_status,u.email_verified,u.must_change_password,
               u.failed_login_count,u.locked_until,u.last_login_at,u.created_at,u.is_deleted,u.deleted_at,
               r.role_code,r.role_name,
               rb.block_code AS resident_block,ab.block_code AS admin_block,tb.block_code AS technician_block,
               tp.technician_id,tp.employee_code,tp.availability,tp.current_workload,tp.max_active_jobs,tp.emergency_eligible,
               GROUP_CONCAT(DISTINCT s.skill_name ORDER BY ts.is_primary DESC,s.skill_name SEPARATOR ', ') AS skills
        FROM users u JOIN roles r ON r.role_id=u.role_id
        LEFT JOIN resident_profiles rp ON rp.user_id=u.user_id LEFT JOIN buildings rb ON rb.building_id=rp.building_id
        LEFT JOIN apartment_admin_profiles ap ON ap.user_id=u.user_id LEFT JOIN buildings ab ON ab.building_id=ap.primary_building_id
        LEFT JOIN technician_profiles tp ON tp.user_id=u.user_id LEFT JOIN buildings tb ON tb.building_id=tp.assigned_building_id
        LEFT JOIN technician_skills ts ON ts.technician_id=tp.technician_id AND ts.verified=TRUE LEFT JOIN skills s ON s.skill_id=ts.skill_id
        WHERE {' AND '.join(where)}
        GROUP BY u.user_id,u.full_name,u.email,u.phone,u.account_status,u.email_verified,u.must_change_password,
                 u.failed_login_count,u.locked_until,u.last_login_at,u.created_at,u.is_deleted,u.deleted_at,r.role_code,r.role_name,
                 rb.block_code,ab.block_code,tb.block_code,tp.technician_id,tp.employee_code,tp.availability,tp.current_workload,tp.max_active_jobs,tp.emergency_eligible
        ORDER BY u.is_deleted ASC,u.created_at DESC,u.full_name
        """, tuple(params))
    result=[]
    for r in rows:
        block=r.get('resident_block') or r.get('admin_block') or r.get('technician_block') or ''
        result.append({
            'id':int(r['user_id']),'displayId':f"USR-{int(r['user_id']):03d}",'name':r['full_name'],'email':r['email'],'phone':r.get('phone') or '',
            'role':FRONT_ROLE.get(r['role_code'],r['role_code']),'roleCode':r['role_code'],'roleName':r['role_name'],'block':block,
            'status':'Deleted' if r.get('is_deleted') else r['account_status'],'accountStatus':r['account_status'],
            'emailVerified':bool(r.get('email_verified')),'mustChangePassword':bool(r.get('must_change_password')),
            'failedLogins':int(r.get('failed_login_count') or 0),'lockedUntil':r['locked_until'].isoformat() if r.get('locked_until') else None,
            'lastLogin':r['last_login_at'].isoformat() if r.get('last_login_at') else None,
            'created':r['created_at'].isoformat() if r.get('created_at') else None,
            'deleted':bool(r.get('is_deleted')),'deletedAt':r['deleted_at'].isoformat() if r.get('deleted_at') else None,
            'technicianId':int(r['technician_id']) if r.get('technician_id') else None,'employeeCode':r.get('employee_code') or '',
            'availability':r.get('availability') or '', 'workload':int(r.get('current_workload') or 0), 'maxJobs':int(r.get('max_active_jobs') or 0),
            'emergencyEligible':bool(r.get('emergency_eligible')),'skills':r.get('skills') or '',
        })
    return result


def get_user_details(user_id):
    row=query_one(
        """
        SELECT u.user_id,u.full_name,u.email,u.phone,u.account_status,u.email_verified,u.must_change_password,
               u.failed_login_count,u.locked_until,u.last_login_at,u.last_password_change_at,u.created_at,u.updated_at,u.is_deleted,u.deleted_at,
               r.role_code,r.role_name,
               rp.resident_id,rp.building_id AS resident_building_id,rp.floor_id AS resident_floor_id,rp.unit_number,
               rp.resident_type,rp.preferred_language,rp.contact_preference,rp.profile_status,
               ap.admin_id,ap.primary_building_id AS admin_building_id,ap.job_title,ap.can_review_emergencies,ap.active AS admin_active,
               tp.technician_id,tp.employee_code,tp.assigned_building_id AS technician_building_id,tp.availability,
               tp.current_workload,tp.max_active_jobs,tp.emergency_eligible,tp.can_work_after_hours,tp.service_area,tp.active AS technician_active,
               pts.skill_id AS primary_skill_id,ps.skill_name AS primary_skill_name
        FROM users u JOIN roles r ON r.role_id=u.role_id
        LEFT JOIN resident_profiles rp ON rp.user_id=u.user_id
        LEFT JOIN apartment_admin_profiles ap ON ap.user_id=u.user_id
        LEFT JOIN technician_profiles tp ON tp.user_id=u.user_id
        LEFT JOIN technician_skills pts ON pts.technician_id=tp.technician_id AND pts.is_primary=TRUE AND pts.verified=TRUE
        LEFT JOIN skills ps ON ps.skill_id=pts.skill_id
        WHERE u.user_id=%s LIMIT 1
        """, (user_id,))
    if not row: return None
    data={
        'id':int(row['user_id']),'displayId':f"USR-{int(row['user_id']):03d}",'name':row['full_name'],'email':row['email'],'phone':row.get('phone') or '',
        'role':FRONT_ROLE.get(row['role_code'],row['role_code']),'roleCode':row['role_code'],'roleName':row['role_name'],
        'status':'Deleted' if row.get('is_deleted') else row['account_status'],'accountStatus':row['account_status'],
        'emailVerified':bool(row.get('email_verified')),'mustChangePassword':bool(row.get('must_change_password')),
        'failedLogins':int(row.get('failed_login_count') or 0),'lockedUntil':row['locked_until'].isoformat() if row.get('locked_until') else None,
        'lastLogin':row['last_login_at'].isoformat() if row.get('last_login_at') else None,
        'lastPasswordChange':row['last_password_change_at'].isoformat() if row.get('last_password_change_at') else None,
        'created':row['created_at'].isoformat() if row.get('created_at') else None,'updated':row['updated_at'].isoformat() if row.get('updated_at') else None,
        'deleted':bool(row.get('is_deleted')),'deletedAt':row['deleted_at'].isoformat() if row.get('deleted_at') else None,
    }
    if row['role_code']=='resident':
        data['resident']={'residentId':int(row['resident_id']) if row.get('resident_id') else None,'buildingId':int(row['resident_building_id']) if row.get('resident_building_id') else None,
                          'floorId':int(row['resident_floor_id']) if row.get('resident_floor_id') else None,'unitNumber':row.get('unit_number') or '',
                          'residentType':row.get('resident_type') or 'Other','preferredLanguage':row.get('preferred_language') or 'English',
                          'contactPreference':row.get('contact_preference') or 'In App','profileStatus':row.get('profile_status') or ''}
    elif row['role_code']=='apartment_admin':
        data['admin']={'adminId':int(row['admin_id']) if row.get('admin_id') else None,'buildingId':int(row['admin_building_id']) if row.get('admin_building_id') else None,
                       'jobTitle':row.get('job_title') or 'Apartment Administrator','canReviewEmergencies':bool(row.get('can_review_emergencies')),
                       'active':bool(row.get('admin_active'))}
    elif row['role_code']=='technician':
        data['technician']={'technicianId':int(row['technician_id']) if row.get('technician_id') else None,'employeeCode':row.get('employee_code') or '',
                            'buildingId':int(row['technician_building_id']) if row.get('technician_building_id') else None,'availability':row.get('availability') or 'Off Duty',
                            'currentWorkload':int(row.get('current_workload') or 0),'maxJobs':int(row.get('max_active_jobs') or 4),
                            'emergencyEligible':bool(row.get('emergency_eligible')),'canWorkAfterHours':bool(row.get('can_work_after_hours')),
                            'serviceArea':row.get('service_area') or '','active':bool(row.get('technician_active')),
                            'skillId':int(row['primary_skill_id']) if row.get('primary_skill_id') else None,'skillName':row.get('primary_skill_name') or ''}
    return data


def _valid_location(cursor, building_id, floor_id=None):
    if not building_id: return None
    if floor_id:
        cursor.execute("SELECT b.building_id,f.floor_id FROM buildings b JOIN floors f ON f.building_id=b.building_id WHERE b.building_id=%s AND f.floor_id=%s AND b.status='Active' AND f.status='Active' LIMIT 1", (building_id,floor_id))
    else:
        cursor.execute("SELECT building_id FROM buildings WHERE building_id=%s AND status='Active' LIMIT 1", (building_id,))
    return cursor.fetchone()


def create_user(payload, created_by):
    from pymysql.err import IntegrityError
    from utils.validators import normalize_email, normalize_mobile, validate_mobile, validate_name, validate_employee_code, validate_plain_text, validate_int_range

    name = clean_text(payload.get('name'), 150)
    email = normalize_email(payload.get('email'))
    phone = normalize_mobile(payload.get('phone'))
    role_code = ROLE_MAP.get(payload.get('role'), payload.get('role'))
    password = current_app.config['DEFAULT_STAFF_PASSWORD']
    requested_status = payload.get('status') if payload.get('status') in {'Pending','Active','Suspended','Disabled','Locked'} else 'Active'
    email_verified = _bool(payload.get('email_verified', True))

    if role_code == 'resident':
        return None, 'Resident accounts must be created through an approved resident registration request.', 400
    if role_code not in {'apartment_admin','technician','system_admin'}:
        return None, 'Select a valid user role.', 400
    if not validate_name(name):
        return None, 'Enter a valid full name.', 400
    if not validate_email(email):
        return None, 'Enter a valid email address.', 400
    if not email.endswith('@helafixit.lk'):
        return None, 'New staff email addresses must end with @helafixit.lk.', 400
    if not validate_mobile(phone, required=True):
        return None, 'Enter a valid Sri Lankan mobile number such as 0771234567 or +94771234567.', 400
    valid, msg = validate_password(password)
    if not valid:
        return None, msg, 500

    try:
        building_id = int(payload.get('building_id')) if payload.get('building_id') else None
    except (TypeError, ValueError):
        building_id = None

    employee_code = clean_text(payload.get('employee_code'), 50).upper()
    if employee_code and not validate_employee_code(employee_code):
        return None, 'Employee code can contain only letters, numbers, hyphens and underscores.', 400
    job_title = clean_text(payload.get('job_title'), 100) or 'Apartment Administrator'
    if role_code == 'apartment_admin' and not validate_plain_text(job_title, 2, 100):
        return None, 'Enter a valid job title.', 400
    if role_code in {'apartment_admin','technician'} and not building_id:
        return None, 'Select the assigned building.', 400

    skill_id = None
    default_max_jobs = get_int_setting('technician_default_max_jobs', 4, 1, 20)
    max_jobs = default_max_jobs
    if role_code == 'technician':
        try:
            skill_id = int(payload.get('skill_id')) if payload.get('skill_id') else None
        except (TypeError, ValueError):
            skill_id = None
        if not skill_id:
            return None, 'Select the technician primary skill.', 400
        if not employee_code:
            return None, 'Enter the technician employee code.', 400
        if not validate_int_range(payload.get('max_jobs') or default_max_jobs, 1, 20):
            return None, 'Maximum active jobs must be between 1 and 20.', 400
        max_jobs = int(payload.get('max_jobs') or default_max_jobs)

    connection = get_connection()
    try:
        with connection.cursor() as c:
            c.execute('SELECT user_id FROM users WHERE LOWER(email)=%s LIMIT 1', (email,))
            if c.fetchone():
                connection.rollback(); return None, 'A user already exists with this email address.', 409

            c.execute('SELECT role_id FROM roles WHERE role_code=%s AND active=TRUE LIMIT 1', (role_code,))
            role = c.fetchone()
            c.execute("SELECT complex_id FROM apartment_complexes WHERE status='Active' ORDER BY complex_id LIMIT 1")
            complex_row = c.fetchone()
            if not role or not complex_row:
                connection.rollback(); return None, 'Required role or apartment configuration is missing.', 500

            if building_id and not _valid_location(c, building_id):
                connection.rollback(); return None, 'Select a valid active building.', 400
            if skill_id:
                c.execute('SELECT skill_id FROM skills WHERE skill_id=%s AND active=TRUE LIMIT 1', (skill_id,))
                if not c.fetchone():
                    connection.rollback(); return None, 'Select a valid technician skill.', 400
            if role_code == 'technician':
                c.execute('SELECT technician_id FROM technician_profiles WHERE UPPER(employee_code)=%s LIMIT 1', (employee_code,))
                if c.fetchone():
                    connection.rollback(); return None, 'Another technician already uses this employee code.', 409

            password_hash = generate_password_hash(password, method='pbkdf2:sha256:600000')
            c.execute(
                "INSERT INTO users(role_id,complex_id,full_name,email,phone,password_hash,account_status,email_verified,must_change_password,created_by,last_password_change_at,is_deleted) VALUES(%s,%s,%s,%s,%s,%s,%s,%s,TRUE,%s,NOW(),FALSE)",
                (role['role_id'], complex_row['complex_id'], name, email, phone, password_hash, requested_status, email_verified, created_by)
            )
            user_id = c.lastrowid

            if role_code == 'apartment_admin':
                c.execute(
                    "INSERT INTO apartment_admin_profiles(user_id,primary_building_id,job_title,can_review_emergencies,active) VALUES(%s,%s,%s,%s,%s)",
                    (user_id, building_id, job_title, _bool(payload.get('can_review_emergencies', True)), requested_status == 'Active')
                )
            elif role_code == 'technician':
                availability = payload.get('availability') if payload.get('availability') in {'Available','Busy','Off Duty','On Leave'} else 'Available'
                if requested_status != 'Active':
                    availability = 'Off Duty'
                emergency = _bool(payload.get('emergency_eligible'))
                c.execute(
                    "INSERT INTO technician_profiles(user_id,employee_code,assigned_building_id,availability,current_workload,max_active_jobs,emergency_eligible,active,last_availability_change_at) VALUES(%s,%s,%s,%s,0,%s,%s,%s,NOW())",
                    (user_id, employee_code, building_id, availability, max_jobs, emergency, requested_status == 'Active')
                )
                technician_id = c.lastrowid
                c.execute(
                    "INSERT INTO technician_skills(technician_id,skill_id,skill_level,verified,is_primary) VALUES(%s,%s,'Intermediate',TRUE,TRUE)",
                    (technician_id, skill_id)
                )

            c.execute('INSERT IGNORE INTO notification_preferences(user_id) VALUES(%s)', (user_id,))
            c.execute(
                "INSERT INTO audit_logs(user_id,action_type,entity_type,entity_id,new_value,reason) VALUES(%s,'USER_CREATED','User',%s,JSON_OBJECT('role',%s,'status',%s,'email_verified',%s),'User created by System Admin')",
                (created_by, str(user_id), role_code, requested_status, email_verified)
            )
        connection.commit()
        return {'id': int(user_id), 'mustChangePassword': True, 'temporaryPassword': password}, None, 201
    except IntegrityError as exc:
        connection.rollback()
        code = exc.args[0] if exc.args else None
        message = str(exc).lower()
        if code == 1062 and 'employee' in message:
            return None, 'Another technician already uses this employee code.', 409
        if code == 1062 and 'email' in message:
            return None, 'A user already exists with this email address.', 409
        return None, 'The user account could not be created because a unique account value is already in use.', 409
    except Exception:
        connection.rollback(); raise
    finally:
        connection.close()


def update_user(user_id,payload,updated_by):
    from utils.validators import normalize_email,normalize_mobile,validate_mobile,validate_name,validate_employee_code,validate_plain_text,validate_int_range,validate_unit_number
    name=clean_text(payload.get('name'),150); email=normalize_email(payload.get('email')); phone=normalize_mobile(payload.get('phone')); status=payload.get('status')
    if not validate_name(name): return None,'Enter a valid full name.',400
    if not validate_email(email): return None,'Enter a valid email address.',400
    if not validate_mobile(phone,required=True): return None,'Enter a valid Sri Lankan mobile number such as 0771234567 or +94771234567.',400
    if status not in {'Pending','Active','Suspended','Disabled','Locked'}: return None,'Select a valid account status.',400
    if int(user_id)==int(updated_by) and status!='Active': return None,'You cannot suspend, disable or lock your own System Admin account.',400
    connection=get_connection()
    try:
        with connection.cursor() as c:
            c.execute("SELECT u.user_id,u.is_deleted,u.account_status,r.role_code FROM users u JOIN roles r ON r.role_id=u.role_id WHERE u.user_id=%s FOR UPDATE",(user_id,)); current=c.fetchone()
            if not current: connection.rollback(); return None,'User not found.',404
            if current.get('is_deleted'): connection.rollback(); return None,'Restore the deleted account before editing it.',400
            c.execute('SELECT user_id FROM users WHERE LOWER(email)=%s AND user_id<>%s LIMIT 1',(email,user_id))
            if c.fetchone(): connection.rollback(); return None,'Another account already uses this email address.',409
            role_code=current['role_code']
            if role_code == 'technician' and status != 'Active':
                c.execute("""
                    SELECT COUNT(*) AS total
                    FROM technician_profiles tp
                    INNER JOIN ticket_assignments ta ON ta.technician_id=tp.technician_id AND ta.is_current=TRUE
                    INNER JOIN maintenance_tickets mt ON mt.ticket_id=ta.ticket_id
                    WHERE tp.user_id=%s AND mt.current_status NOT IN ('Resolved','Closed','Cancelled')
                """, (user_id,))
                active_jobs = int((c.fetchone() or {}).get('total') or 0)
                if active_jobs:
                    connection.rollback(); return None,'Reassign the technician active jobs before changing this account from Active.',409
            if role_code != 'resident' and not email.endswith('@helafixit.lk'):
                connection.rollback(); return None,'Staff email addresses must end with @helafixit.lk.',400
            email_verified=_bool(payload.get('email_verified'))
            session_bump=1 if current.get('account_status')!=status else 0
            if status == 'Active':
                c.execute('UPDATE users SET full_name=%s,email=%s,phone=%s,account_status=%s,email_verified=%s,failed_login_count=0,locked_until=NULL,auth_version=auth_version+%s WHERE user_id=%s',(name,email,phone,status,email_verified,session_bump,user_id))
            else:
                c.execute('UPDATE users SET full_name=%s,email=%s,phone=%s,account_status=%s,email_verified=%s,auth_version=auth_version+%s WHERE user_id=%s',(name,email,phone,status,email_verified,session_bump,user_id))
            if role_code=='resident':
                try: building_id=int(payload.get('building_id')); floor_id=int(payload.get('floor_id'))
                except (TypeError,ValueError): connection.rollback(); return None,'Select a valid resident building and floor.',400
                unit_number=clean_text(payload.get('unit_number'),40)
                if not validate_unit_number(unit_number): connection.rollback(); return None,'Enter a valid apartment or unit number.',400
                if not _valid_location(c,building_id,floor_id): connection.rollback(); return None,'The selected floor does not belong to the selected building.',400
                resident_type=payload.get('resident_type') if payload.get('resident_type') in {'Owner','Tenant','Family','Other'} else 'Other'
                language=payload.get('preferred_language') if payload.get('preferred_language') in {'English','Sinhala','Singlish','Mixed'} else 'English'
                unit_id=None
                if unit_number:
                    c.execute("SELECT unit_id FROM units WHERE floor_id=%s AND unit_number=%s AND status='Active' LIMIT 1",(floor_id,unit_number)); unit=c.fetchone(); unit_id=unit['unit_id'] if unit else None
                c.execute("UPDATE resident_profiles SET building_id=%s,floor_id=%s,unit_id=%s,unit_number=%s,resident_type=%s,preferred_language=%s WHERE user_id=%s",(building_id,floor_id,unit_id,unit_number or None,resident_type,language,user_id))
            elif role_code=='apartment_admin':
                try: building_id=int(payload.get('building_id')) if payload.get('building_id') else None
                except (TypeError,ValueError): building_id=None
                if building_id and not _valid_location(c,building_id): connection.rollback(); return None,'Select a valid active building.',400
                job_title=clean_text(payload.get('job_title'),100) or 'Apartment Administrator'
                if not validate_plain_text(job_title,2,100): connection.rollback(); return None,'Enter a valid job title.',400
                c.execute("UPDATE apartment_admin_profiles SET primary_building_id=%s,job_title=%s,can_review_emergencies=%s,active=%s WHERE user_id=%s",(building_id,job_title,_bool(payload.get('can_review_emergencies')),status=='Active',user_id))
            elif role_code=='technician':
                try: building_id=int(payload.get('building_id')) if payload.get('building_id') else None
                except (TypeError,ValueError): building_id=None
                if not building_id or not _valid_location(c,building_id): connection.rollback(); return None,'Select a valid assigned building.',400
                employee_code=clean_text(payload.get('employee_code'),50)
                if not validate_employee_code(employee_code): connection.rollback(); return None,'Enter a valid technician employee code.',400
                availability=payload.get('availability') if payload.get('availability') in {'Available','Busy','Off Duty','On Leave'} else 'Off Duty'
                if status != 'Active':
                    availability = 'Off Duty'
                if not validate_int_range(payload.get('max_jobs'),1,20): connection.rollback(); return None,'Maximum active jobs must be between 1 and 20.',400
                max_jobs=int(payload.get('max_jobs'))
                c.execute('SELECT technician_id,current_workload FROM technician_profiles WHERE user_id=%s LIMIT 1',(user_id,)); tech=c.fetchone()
                if not tech: connection.rollback(); return None,'Technician profile not found.',404
                c.execute('SELECT technician_id FROM technician_profiles WHERE UPPER(employee_code)=%s AND user_id<>%s LIMIT 1',(employee_code.upper(),user_id))
                if c.fetchone(): connection.rollback(); return None,'Another technician already uses this employee code.',409
                if max_jobs < int(tech.get('current_workload') or 0): connection.rollback(); return None,'Maximum active jobs cannot be lower than the current workload.',400
                try: skill_id=int(payload.get('skill_id'))
                except (TypeError,ValueError): connection.rollback(); return None,'Select the technician primary skill.',400
                c.execute('SELECT skill_id FROM skills WHERE skill_id=%s AND active=TRUE LIMIT 1',(skill_id,))
                if not c.fetchone(): connection.rollback(); return None,'Select a valid technician skill.',400
                c.execute("UPDATE technician_profiles SET employee_code=%s,assigned_building_id=%s,availability=%s,max_active_jobs=%s,emergency_eligible=%s,active=%s,last_availability_change_at=NOW() WHERE user_id=%s",(employee_code,building_id,availability,max_jobs,_bool(payload.get('emergency_eligible')),status=='Active',user_id))
                c.execute('UPDATE technician_skills SET is_primary=FALSE WHERE technician_id=%s',(tech['technician_id'],))
                c.execute("INSERT INTO technician_skills(technician_id,skill_id,skill_level,verified,is_primary) VALUES(%s,%s,'Intermediate',TRUE,TRUE) ON DUPLICATE KEY UPDATE verified=TRUE,is_primary=TRUE",(tech['technician_id'],skill_id))
            c.execute("INSERT INTO audit_logs(user_id,action_type,entity_type,entity_id,new_value,reason) VALUES(%s,'USER_UPDATED','User',%s,JSON_OBJECT('status',%s,'email_verified',%s),'User account updated by System Admin')",(updated_by,str(user_id),status,email_verified))
        connection.commit(); return {'id':int(user_id)},None,200
    except Exception: connection.rollback(); raise
    finally: connection.close()


def reset_user_password(user_id,temp_password,updated_by):
    """Compatibility wrapper for the final temporary-password workflow.

    The user's permanent password hash is never overwritten here. All System
    Admin password actions issue a separate temporary password instead.
    """
    from services.temporary_password_service import set_temporary_password
    return set_temporary_password(user_id, temp_password, updated_by)


def unlock_user(user_id,updated_by):
    connection=get_connection()
    try:
        with connection.cursor() as c:
            c.execute('SELECT user_id,is_deleted FROM users WHERE user_id=%s FOR UPDATE',(user_id,)); row=c.fetchone()
            if not row:return None,'User not found.',404
            if row.get('is_deleted'):return None,'Deleted accounts cannot be unlocked.',400
            c.execute("UPDATE users SET failed_login_count=0,locked_until=NULL,account_status=IF(account_status='Locked','Active',account_status),auth_version=auth_version+1 WHERE user_id=%s",(user_id,))
            c.execute("INSERT INTO audit_logs(user_id,action_type,entity_type,entity_id,reason) VALUES(%s,'USER_UNLOCKED','User',%s,'Account unlocked by System Admin')",(updated_by,str(user_id)))
        connection.commit(); return {'id':int(user_id)},None,200
    except Exception: connection.rollback(); raise
    finally: connection.close()


def set_email_verified(user_id,verified,updated_by):
    connection=get_connection()
    try:
        with connection.cursor() as c:
            c.execute('UPDATE users SET email_verified=%s WHERE user_id=%s AND is_deleted=FALSE',(bool(verified),user_id))
            if c.rowcount==0:return None,'User not found or account is deleted.',404
            c.execute("INSERT INTO audit_logs(user_id,action_type,entity_type,entity_id,new_value,reason) VALUES(%s,'EMAIL_VERIFICATION_UPDATED','User',%s,JSON_OBJECT('verified',%s),'Email verification updated by System Admin')",(updated_by,str(user_id),bool(verified)))
        connection.commit(); return {'id':int(user_id),'emailVerified':bool(verified)},None,200
    except Exception: connection.rollback(); raise
    finally: connection.close()


def delete_user(user_id,updated_by):
    if int(user_id)==int(updated_by): return None,'You cannot delete your own System Admin account.',400
    connection=get_connection()
    try:
        with connection.cursor() as c:
            c.execute("SELECT u.user_id,u.is_deleted,r.role_code FROM users u JOIN roles r ON r.role_id=u.role_id WHERE u.user_id=%s FOR UPDATE",(user_id,)); row=c.fetchone()
            if not row:return None,'User not found.',404
            if row.get('is_deleted'):return {'id':int(user_id)},None,200
            if row['role_code']=='system_admin':
                c.execute("SELECT COUNT(*) AS total FROM users u JOIN roles r ON r.role_id=u.role_id WHERE r.role_code='system_admin' AND u.account_status='Active' AND u.is_deleted=FALSE AND u.user_id<>%s",(user_id,))
                if int(c.fetchone()['total'] or 0)<1:return None,'At least one active System Admin account must remain.',400
            if row['role_code']=='technician':
                c.execute("""
                    SELECT COUNT(*) AS total
                    FROM technician_profiles tp
                    INNER JOIN ticket_assignments ta ON ta.technician_id=tp.technician_id AND ta.is_current=TRUE
                    INNER JOIN maintenance_tickets mt ON mt.ticket_id=ta.ticket_id
                    WHERE tp.user_id=%s AND mt.current_status NOT IN ('Resolved','Closed','Cancelled')
                """,(user_id,))
                if int((c.fetchone() or {}).get('total') or 0)>0:
                    return None,'Reassign the technician active jobs before deleting this account.',409
            c.execute("UPDATE users SET is_deleted=TRUE,deleted_at=NOW(),account_status='Disabled',must_change_password=FALSE,failed_login_count=0,locked_until=NULL,auth_version=auth_version+1 WHERE user_id=%s",(user_id,))
            c.execute("UPDATE resident_profiles SET profile_status='Inactive' WHERE user_id=%s",(user_id,))
            c.execute("UPDATE apartment_admin_profiles SET active=FALSE WHERE user_id=%s",(user_id,))
            c.execute("UPDATE technician_profiles SET active=FALSE,availability='Off Duty',last_availability_change_at=NOW() WHERE user_id=%s",(user_id,))
            c.execute("INSERT INTO audit_logs(user_id,action_type,entity_type,entity_id,reason) VALUES(%s,'USER_DELETED','User',%s,'Account deleted by System Admin. Operational maintenance history was retained.')",(updated_by,str(user_id)))
        connection.commit(); return {'id':int(user_id)},None,200
    except Exception: connection.rollback(); raise
    finally: connection.close()


def restore_user(user_id,updated_by):
    connection=get_connection()
    try:
        with connection.cursor() as c:
            c.execute('SELECT user_id,is_deleted FROM users WHERE user_id=%s FOR UPDATE',(user_id,)); row=c.fetchone()
            if not row:return None,'User not found.',404
            if not row.get('is_deleted'):return {'id':int(user_id)},None,200
            c.execute("UPDATE users SET is_deleted=FALSE,deleted_at=NULL,account_status='Active',auth_version=auth_version+1 WHERE user_id=%s",(user_id,))
            c.execute("UPDATE resident_profiles SET profile_status='Active' WHERE user_id=%s",(user_id,))
            c.execute("UPDATE apartment_admin_profiles SET active=TRUE WHERE user_id=%s",(user_id,))
            c.execute("UPDATE technician_profiles SET active=TRUE,availability='Off Duty',last_availability_change_at=NOW() WHERE user_id=%s",(user_id,))
            c.execute("INSERT INTO audit_logs(user_id,action_type,entity_type,entity_id,reason) VALUES(%s,'USER_RESTORED','User',%s,'Deleted account restored by System Admin')",(updated_by,str(user_id)))
        connection.commit(); return {'id':int(user_id)},None,200
    except Exception: connection.rollback(); raise
    finally: connection.close()

def roles():
    rows=query_all("""
        SELECT r.role_id,r.role_code,r.role_name,r.description,r.active,COUNT(DISTINCT CASE WHEN u.is_deleted=FALSE THEN u.user_id END) AS user_count,
               GROUP_CONCAT(DISTINCT p.permission_code ORDER BY p.permission_code SEPARATOR ', ') AS permissions
        FROM roles r LEFT JOIN users u ON u.role_id=r.role_id
        LEFT JOIN role_permissions rp ON rp.role_id=r.role_id LEFT JOIN permissions p ON p.permission_id=rp.permission_id
        GROUP BY r.role_id,r.role_code,r.role_name,r.description,r.active ORDER BY r.role_id
    """)
    return [{'id':int(r['role_id']),'code':r['role_code'],'name':r['role_name'],'description':r.get('description') or '', 'users':int(r['user_count'] or 0),'permissions':r.get('permissions') or '', 'active':bool(r['active'])} for r in rows]


def skills():
    rows=query_all("""
        SELECT s.skill_id,s.skill_name,s.description,s.active,COUNT(DISTINCT ts.technician_id) AS technicians
        FROM skills s LEFT JOIN technician_skills ts ON ts.skill_id=s.skill_id AND ts.verified=TRUE
        GROUP BY s.skill_id,s.skill_name,s.description,s.active ORDER BY s.skill_name
    """)
    return [{'id':int(r['skill_id']),'name':r['skill_name'],'description':r.get('description') or '', 'active':bool(r['active']),'technicians':int(r['technicians'] or 0)} for r in rows]


def create_skill(name,description=''):
    name=clean_text(name,100); description=clean_text(description,255)
    if len(name)<2: return None,'Enter a skill name.',400
    connection=get_connection()
    try:
        with connection.cursor() as c:
            c.execute("INSERT INTO skills(skill_name,description,active) VALUES(%s,%s,TRUE)",(name,description or None)); sid=c.lastrowid
        connection.commit(); return {'id':int(sid)},None,201
    except Exception as exc:
        connection.rollback()
        if 'Duplicate' in str(exc): return None,'This skill already exists.',409
        raise
    finally: connection.close()


def categories():
    rows=query_all("""
        SELECT c.category_id,c.category_code,c.name,c.default_priority,c.severity_weight,c.description,c.active,
               s.skill_name AS technician
        FROM issue_categories c LEFT JOIN skills s ON s.skill_id=c.default_skill_id ORDER BY c.category_id
    """)
    return [{'id':int(r['category_id']),'code':r['category_code'],'name':r['name'],'priority':r['default_priority'],'riskWeight':float(r['severity_weight']),'description':r.get('description') or '', 'technician':r.get('technician') or 'General Maintenance','active':bool(r['active'])} for r in rows]


def create_category(payload):
    code=clean_text(payload.get('code'),50).upper(); name=clean_text(payload.get('name'),100); description=clean_text(payload.get('description'),255)
    priority=payload.get('priority') if payload.get('priority') in {'Emergency','High','Medium','Low'} else 'Medium'
    try: weight=max(0,min(30,float(payload.get('risk_weight') or 5)))
    except: weight=5
    try: skill_id=int(payload.get('skill_id')) if payload.get('skill_id') else None
    except: skill_id=None
    if not code or len(name)<2: return None,'Enter category code and name.',400
    connection=get_connection()
    try:
        with connection.cursor() as c:
            c.execute("INSERT INTO issue_categories(category_code,name,default_skill_id,default_priority,severity_weight,description,active) VALUES(%s,%s,%s,%s,%s,%s,TRUE)",(code,name,skill_id,priority,weight,description or None)); cid=c.lastrowid
            if skill_id: c.execute("INSERT INTO category_skill_mappings(category_id,skill_id,required_level,match_weight,is_primary,active) VALUES(%s,%s,'Intermediate',100,TRUE,TRUE)",(cid,skill_id))
        connection.commit(); return {'id':int(cid)},None,201
    except Exception as exc:
        connection.rollback()
        if 'Duplicate' in str(exc): return None,'Category code or name already exists.',409
        raise
    finally: connection.close()


def buildings():
    rows=query_all("""
        SELECT b.building_id,b.block_code,b.name,b.declared_floor_count,b.declared_unit_count,b.status,
               COUNT(DISTINCT f.floor_id) AS configured_floors,COUNT(DISTINCT u.unit_id) AS configured_units
        FROM buildings b LEFT JOIN floors f ON f.building_id=b.building_id LEFT JOIN units u ON u.floor_id=f.floor_id
        GROUP BY b.building_id,b.block_code,b.name,b.declared_floor_count,b.declared_unit_count,b.status ORDER BY b.block_code
    """)
    return [{'id':int(r['building_id']),'code':r['block_code'],'name':r['name'],'floors':int(r['configured_floors'] or 0),'units':int(r['configured_units'] or 0),'declaredFloors':int(r['declared_floor_count'] or 0),'declaredUnits':int(r['declared_unit_count'] or 0),'active':r['status']=='Active'} for r in rows]


def create_building(payload):
    code=clean_text(payload.get('code'),50); name=clean_text(payload.get('name'),150)
    try: floors=max(1,int(payload.get('floors') or 1)); units=max(0,int(payload.get('units') or 0))
    except: floors,units=1,0
    if not code or not name: return None,'Enter building code and name.',400
    connection=get_connection()
    try:
        with connection.cursor() as c:
            c.execute("SELECT complex_id FROM apartment_complexes WHERE status='Active' ORDER BY complex_id LIMIT 1"); cr=c.fetchone()
            if not cr: connection.rollback(); return None,'Apartment complex is not configured.',500
            c.execute("INSERT INTO buildings(complex_id,name,block_code,declared_floor_count,declared_unit_count,status) VALUES(%s,%s,%s,%s,%s,'Active')",(cr['complex_id'],name,code,floors,units)); bid=c.lastrowid
        connection.commit(); return {'id':int(bid)},None,201
    except Exception as exc:
        connection.rollback()
        if 'Duplicate' in str(exc): return None,'This building code already exists.',409
        raise
    finally: connection.close()


def locations():
    floors=query_all("SELECT f.floor_id,f.building_id,f.floor_number,f.name,f.status,b.block_code FROM floors f JOIN buildings b ON b.building_id=f.building_id ORDER BY b.block_code,f.floor_number")
    areas=query_all("SELECT a.area_id,a.building_id,a.floor_id,a.name,a.area_type,a.risk_weight,a.status,b.block_code,f.name AS floor_name FROM areas a JOIN buildings b ON b.building_id=a.building_id LEFT JOIN floors f ON f.floor_id=a.floor_id ORDER BY b.block_code,f.floor_number,a.name")
    return {
        'floors':[{'id':int(r['floor_id']),'buildingId':int(r['building_id']),'block':r['block_code'],'number':int(r['floor_number']),'name':r['name'],'active':r['status']=='Active'} for r in floors],
        'areas':[{'id':int(r['area_id']),'buildingId':int(r['building_id']),'floorId':int(r['floor_id']) if r.get('floor_id') else None,'block':r['block_code'],'floor':r.get('floor_name') or 'All floors','name':r['name'],'type':r['area_type'],'riskWeight':float(r['risk_weight']),'active':r['status']=='Active'} for r in areas]
    }


def create_floor(payload):
    try: building_id=int(payload.get('building_id')); number=int(payload.get('floor_number'))
    except: return None,'Select a building and enter a valid floor number.',400
    name=clean_text(payload.get('name'),80) or ('Ground Floor' if number==0 else f'Floor {number}')
    connection=get_connection()
    try:
        with connection.cursor() as c: c.execute("INSERT INTO floors(building_id,floor_number,name,status) VALUES(%s,%s,%s,'Active')",(building_id,number,name)); fid=c.lastrowid
        connection.commit(); return {'id':int(fid)},None,201
    except Exception as exc:
        connection.rollback()
        if 'Duplicate' in str(exc): return None,'This floor already exists for the selected building.',409
        raise
    finally: connection.close()


def create_area(payload):
    try: building_id=int(payload.get('building_id')); floor_id=int(payload.get('floor_id')) if payload.get('floor_id') else None
    except: return None,'Select a valid building and floor.',400
    name=clean_text(payload.get('name'),100); area_type=payload.get('area_type') if payload.get('area_type') in {'Private','Common','Service','Outdoor','Other'} else 'Common'
    try: risk=max(0,min(30,float(payload.get('risk_weight') or 0)))
    except: risk=0
    if not name: return None,'Enter an area name.',400
    connection=get_connection()
    try:
        with connection.cursor() as c: c.execute("INSERT INTO areas(building_id,floor_id,name,area_type,risk_weight,status) VALUES(%s,%s,%s,%s,%s,'Active')",(building_id,floor_id,name,area_type,risk)); aid=c.lastrowid
        connection.commit(); return {'id':int(aid)},None,201
    except Exception as exc:
        connection.rollback()
        if 'Duplicate' in str(exc): return None,'This area already exists at the selected location.',409
        raise
    finally: connection.close()


def safety_rules():
    rows=query_all("""
        SELECT sr.safety_rule_id,sr.rule_code,sr.keyword_or_pattern,sr.match_type,sr.language_type,sr.score_weight,sr.severity,
               sr.warning_message,sr.resident_action,sr.rule_version,sr.active,c.name AS category
        FROM safety_rules sr LEFT JOIN issue_categories c ON c.category_id=sr.category_id ORDER BY sr.active DESC,sr.severity DESC,sr.safety_rule_id
    """)
    return [{'id':int(r['safety_rule_id']),'code':r['rule_code'],'keyword':r['keyword_or_pattern'],'matchType':r['match_type'],'language':r['language_type'],'risk':float(r['score_weight']),'severity':r['severity'],'warning':r['warning_message'],'residentAction':r.get('resident_action') or '', 'version':r['rule_version'],'category':r.get('category') or 'Any','active':bool(r['active'])} for r in rows]


def create_safety_rule(payload,user_id):
    code=clean_text(payload.get('code'),80).upper(); keyword=clean_text(payload.get('keyword'),255); warning=clean_text(payload.get('warning'),500)
    match_type=payload.get('match_type') if payload.get('match_type') in {'Keyword','Phrase','Regex'} else 'Phrase'
    language=payload.get('language') if payload.get('language') in {'English','Sinhala','Singlish','Mixed','Any'} else 'Any'
    severity=payload.get('severity') if payload.get('severity') in {'Low','Medium','High','Critical'} else 'High'
    try: score=max(0,min(50,float(payload.get('score') or 20))); category_id=int(payload.get('category_id')) if payload.get('category_id') else None
    except: score,category_id=20,None
    if not code or not keyword or not warning: return None,'Enter rule code, matching text and warning.',400
    connection=get_connection()
    try:
        with connection.cursor() as c:
            c.execute("INSERT INTO safety_rules(category_id,rule_code,keyword_or_pattern,match_type,language_type,score_weight,severity,warning_message,resident_action,rule_version,active,created_by,updated_by) VALUES(%s,%s,%s,%s,%s,%s,%s,%s,%s,'2.0.0',TRUE,%s,%s)",(category_id,code,keyword,match_type,language,score,severity,warning,clean_text(payload.get('resident_action'),500) or None,user_id,user_id)); rid=c.lastrowid
        connection.commit(); return {'id':int(rid)},None,201
    except Exception as exc:
        connection.rollback()
        if 'Duplicate' in str(exc): return None,'This safety rule code already exists.',409
        raise
    finally: connection.close()


def settings():
    rows=query_all("SELECT setting_key,setting_value,value_type,setting_group,description,updated_at FROM system_settings ORDER BY setting_group,setting_id")
    result={}
    for r in rows:
        value=r['setting_value']
        if r['value_type']=='Boolean': value=_bool(value)
        elif r['value_type']=='Integer':
            try:value=int(value)
            except:pass
        elif r['value_type']=='Decimal':
            try:value=float(value)
            except:pass
        elif r['value_type']=='JSON':
            try:value=json.loads(value)
            except:pass
        result[r['setting_key']]={'value':value,'type':r['value_type'],'group':r['setting_group'],'description':r.get('description') or ''}
    return result


def update_settings(values,user_id):
    """Validate and persist the settings displayed on the System Settings page."""
    values = values or {}
    string_limits = {
        'system_name': (2, 120),
        'apartment_name': (2, 150),
    }
    bool_keys = {
        'auto_emergency_assignment','email_alerts','sms_alerts','browser_alerts',
        'allow_registration','registration_requires_approval','maintenance_mode',
    }
    allowed_languages = {'English','Sinhala','Singlish','Mixed'}
    updates = {}

    for key, (minimum, maximum) in string_limits.items():
        if key in values:
            text = clean_text(values.get(key), maximum)
            if len(text) < minimum:
                return False, f'Enter a valid {key.replace("_", " ")}.', 400
            updates[key] = text

    if 'emergency_risk_threshold' in values:
        try: value = int(values['emergency_risk_threshold'])
        except (TypeError, ValueError): return False, 'Emergency risk threshold must be a number.', 400
        if value < 0 or value > 100: return False, 'Emergency risk threshold must be between 0 and 100.', 400
        updates['emergency_risk_threshold'] = value

    for key, label in [('duplicate_similarity_threshold','Duplicate similarity threshold'),('low_confidence_threshold','Low confidence threshold')]:
        if key in values:
            try: value = float(values[key])
            except (TypeError, ValueError): return False, f'{label} must be a number.', 400
            if value < 0 or value > 1: return False, f'{label} must be between 0 and 1.', 400
            updates[key] = round(value, 4)

    if 'max_upload_mb' in values:
        try: value = int(values['max_upload_mb'])
        except (TypeError, ValueError): return False, 'Maximum upload size must be a number.', 400
        if value < 1 or value > 20: return False, 'Maximum upload size must be between 1 and 20 MB.', 400
        updates['max_upload_mb'] = value

    if 'allowed_image_types' in values:
        raw = str(values.get('allowed_image_types') or '')
        accepted = []
        allowed = {'jpg','jpeg','png','webp'}
        for item in raw.split(','):
            ext = item.strip().lower().lstrip('.')
            if ext and ext not in allowed:
                return False, 'Allowed image types can use only jpg, jpeg, png and webp.', 400
            if ext and ext not in accepted:
                accepted.append(ext)
        if not accepted: return False, 'Enter at least one allowed image type.', 400
        updates['allowed_image_types'] = ','.join(accepted)

    if 'default_language' in values:
        language = str(values.get('default_language') or '')
        if language not in allowed_languages: return False, 'Select a valid default language.', 400
        updates['default_language'] = language

    if 'technician_default_max_jobs' in values:
        try: value = int(values['technician_default_max_jobs'])
        except (TypeError, ValueError): return False, 'Default technician job limit must be a number.', 400
        if value < 1 or value > 20: return False, 'Default technician job limit must be between 1 and 20.', 400
        updates['technician_default_max_jobs'] = value

    if 'notification_retention_days' in values:
        try: value = int(values['notification_retention_days'])
        except (TypeError, ValueError): return False, 'Notification retention must be a number.', 400
        if value < 7 or value > 365: return False, 'Notification retention must be between 7 and 365 days.', 400
        updates['notification_retention_days'] = value

    for key in bool_keys:
        if key in values:
            updates[key] = bool(values[key])

    connection=get_connection()
    try:
        with connection.cursor() as c:
            for key,value in updates.items():
                stored = 'true' if value is True else 'false' if value is False else str(value)
                c.execute('UPDATE system_settings SET setting_value=%s,updated_by=%s WHERE setting_key=%s',(stored,user_id,key))
            c.execute("INSERT INTO audit_logs(user_id,action_type,entity_type,new_value,reason) VALUES(%s,'SETTINGS_UPDATED','system_settings',%s,'System settings updated')",(user_id,json.dumps(updates,ensure_ascii=False)))
        connection.commit(); return True, None, 200
    except Exception:
        connection.rollback(); raise
    finally: connection.close()


def _audit_json_text(value):
    if value in (None, '', {}):
        return ''
    if isinstance(value, (dict, list)):
        return json.dumps(value, ensure_ascii=False, separators=(',', ':'))
    text = str(value)
    try:
        parsed = json.loads(text)
        return json.dumps(parsed, ensure_ascii=False, separators=(',', ':'))
    except Exception:
        return text


def audit_logs(search='', action='', entity='', user='', date_from='', date_to='', page=1, per_page=25):
    where = ['1=1']
    params = []

    if search:
        q = f'%{search}%'
        where.append('(al.action_type LIKE %s OR al.entity_type LIKE %s OR al.entity_id LIKE %s OR al.reason LIKE %s OR u.full_name LIKE %s OR u.email LIKE %s OR al.ip_address LIKE %s)')
        params.extend([q, q, q, q, q, q, q])
    if action:
        where.append('al.action_type=%s')
        params.append(action)
    if entity:
        where.append('al.entity_type=%s')
        params.append(entity)
    if user:
        q = f'%{user}%'
        where.append('(u.full_name LIKE %s OR u.email LIKE %s OR CAST(al.user_id AS CHAR) LIKE %s)')
        params.extend([q, q, q])
    if date_from:
        where.append('DATE(al.created_at) >= %s')
        params.append(date_from)
    if date_to:
        where.append('DATE(al.created_at) <= %s')
        params.append(date_to)

    where_sql = ' AND '.join(where)
    total_row = query_one('SELECT COUNT(*) AS total FROM audit_logs') or {}
    filtered_row = query_one(
        f'SELECT COUNT(*) AS total FROM audit_logs al LEFT JOIN users u ON u.user_id=al.user_id WHERE {where_sql}',
        tuple(params),
    ) or {}
    total = int(total_row.get('total') or 0)
    filtered = int(filtered_row.get('total') or 0)

    try:
        page = max(1, int(page))
    except Exception:
        page = 1
    try:
        per_page = int(per_page)
    except Exception:
        per_page = 25
    per_page = min(100, max(10, per_page))
    pages = max(1, (filtered + per_page - 1) // per_page)
    if page > pages:
        page = pages
    offset = (page - 1) * per_page

    rows = query_all(
        f"""
        SELECT al.audit_id,al.user_id,al.action_type,al.entity_type,al.entity_id,
               al.old_value,al.new_value,al.reason,al.ip_address,al.user_agent,al.created_at,
               u.full_name,u.email
        FROM audit_logs al
        LEFT JOIN users u ON u.user_id=al.user_id
        WHERE {where_sql}
        ORDER BY al.created_at DESC, al.audit_id DESC
        LIMIT %s OFFSET %s
        """,
        tuple(params + [per_page, offset]),
    )

    logs = []
    for r in rows:
        logs.append({
            'id': int(r['audit_id']),
            'time': r['created_at'].isoformat() if r.get('created_at') else None,
            'userId': int(r['user_id']) if r.get('user_id') is not None else None,
            'user': r.get('full_name') or 'System',
            'email': r.get('email') or '',
            'action': r.get('action_type') or '',
            'entity': r.get('entity_type') or '',
            'entityId': r.get('entity_id') or '',
            'target': f"{r.get('entity_type') or ''} {r.get('entity_id') or ''}".strip(),
            'detail': r.get('reason') or '',
            'oldValue': _audit_json_text(r.get('old_value')),
            'newValue': _audit_json_text(r.get('new_value')),
            'ipAddress': r.get('ip_address') or '',
            'userAgent': r.get('user_agent') or '',
        })

    action_rows = query_all("SELECT DISTINCT action_type FROM audit_logs WHERE action_type IS NOT NULL AND action_type <> '' ORDER BY action_type")
    entity_rows = query_all("SELECT DISTINCT entity_type FROM audit_logs WHERE entity_type IS NOT NULL AND entity_type <> '' ORDER BY entity_type")

    return {
        'logs': logs,
        'total': total,
        'filtered': filtered,
        'page': page,
        'perPage': per_page,
        'pages': pages,
        'actions': [r['action_type'] for r in action_rows],
        'entities': [r['entity_type'] for r in entity_rows],
    }


def export_data_snapshot(user_id):
    data={
        'exportedAt':datetime.now().isoformat(timespec='seconds'),
        'apartmentComplexes':query_all("SELECT complex_id,name,address_line,city,country,timezone_name,status FROM apartment_complexes"),
        'buildings':query_all("SELECT building_id,complex_id,name,block_code,address_label,status FROM buildings"),
        'floors':query_all("SELECT floor_id,building_id,floor_number,name,status FROM floors"),
        'areas':query_all("SELECT area_id,building_id,floor_id,name,area_type,risk_weight,status FROM areas"),
        'categories':query_all("SELECT category_id,category_code,name,default_priority,severity_weight,description,active FROM issue_categories"),
        'skills':query_all("SELECT skill_id,skill_name,description,active FROM skills"),
        'settings':query_all("SELECT setting_key,setting_value,value_type,setting_group,description FROM system_settings"),
        'users':query_all("SELECT u.user_id,u.full_name,u.email,u.phone,u.account_status,r.role_code,u.created_at FROM users u JOIN roles r ON r.role_id=u.role_id"),
        'tickets':query_all("SELECT ticket_number,subject,language_type,current_priority,current_risk_score,current_risk_level,current_status,submitted_at,resolved_at FROM maintenance_tickets ORDER BY submitted_at DESC"),
    }
    connection=get_connection()
    try:
        with connection.cursor() as c:
            c.execute("INSERT INTO backup_records(started_by,backup_type,file_name,file_location,backup_status,completed_at,notes) VALUES(%s,'Data',%s,'Browser download','Completed',NOW(),'JSON export generated from live database')",(user_id,'helafixit_data_export.json'))
        connection.commit()
    finally: connection.close()
    return data
