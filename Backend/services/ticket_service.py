import hashlib
import json
import os
import uuid
from pathlib import Path

from werkzeug.utils import secure_filename

from database import get_connection, query_all, query_one
from services.settings_service import allowed_image_extensions, get_int_setting
from utils.validators import clean_text, normalize_mobile, validate_mobile, validate_name

ACTIVE_ASSIGNMENT_STATUSES = ('Assigned', 'Accepted', 'In Progress', 'On Hold')
CLOSED_TICKET_STATUSES = ('Resolved', 'Closed', 'Cancelled')
MIME_BY_EXTENSION = {
    'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png', 'webp': 'image/webp'
}


def _allowed_upload_mimes():
    return {MIME_BY_EXTENSION[x] for x in allowed_image_extensions() if x in MIME_BY_EXTENSION}


def _max_upload_bytes():
    return get_int_setting('max_upload_mb', 5, 1, 20) * 1024 * 1024


def _upload_size(upload_file):
    if not upload_file or not getattr(upload_file, 'stream', None):
        return 0
    stream = upload_file.stream
    try:
        current = stream.tell()
        stream.seek(0, 2)
        size = stream.tell()
        stream.seek(current)
        return int(size)
    except Exception:
        return int(getattr(upload_file, 'content_length', 0) or 0)


def _validate_upload(upload_file):
    if not upload_file or not upload_file.filename:
        return None
    extensions = allowed_image_extensions()
    allowed = _allowed_upload_mimes()
    extension = Path(str(upload_file.filename)).suffix.lower().lstrip('.')
    if extension not in extensions or upload_file.mimetype not in allowed:
        readable = ', '.join(x.upper() for x in extensions)
        return f'Only {readable} image files are allowed.'
    if _upload_size(upload_file) > _max_upload_bytes():
        return f'The uploaded image exceeds the {get_int_setting("max_upload_mb", 5, 1, 20)} MB limit.'
    return None


def _float(value):
    return float(value) if value is not None else None


def _int(value):
    return int(value) if value is not None else None


def _ticket_base_sql(extra_where=''):
    return f"""
        SELECT
            mt.ticket_id,
            mt.ticket_number,
            mt.resident_id,
            mt.subject,
            mt.description,
            mt.language_type,
            mt.asset_type,
            mt.current_priority,
            mt.current_risk_score,
            mt.current_risk_level,
            mt.current_status,
            mt.safety_flag,
            mt.duplicate_flag,
            mt.manual_review_required,
            mt.submitted_at,
            mt.analysed_at,
            mt.resolved_at,
            mt.closed_at,
            mt.updated_at,
            b.building_id,
            b.block_code,
            b.name AS building_name,
            f.floor_id,
            f.floor_number,
            f.name AS floor_name,
            a.area_id,
            a.name AS area_name,
            ic.category_id,
            ic.name AS category_name,
            ic.default_skill_id,
            u.user_id AS resident_user_id,
            u.full_name AS resident_name,
            u.email AS resident_email,
            ap.prediction_id,
            ap.predicted_priority,
            ap.category_confidence,
            ap.priority_confidence,
            ap.risk_score AS predicted_risk_score,
            ap.risk_level AS predicted_risk_level,
            ap.safety_warning,
            ap.duplicate_ticket_id,
            ap.duplicate_similarity,
            ap.recommended_skill_id,
            ap.recommended_technician_id,
            ap.review_status AS prediction_review_status,
            pic.name AS predicted_category_name,
            rs.skill_name AS recommended_skill_name,
            dm.ticket_number AS duplicate_ticket_number,
            ta.assignment_id,
            ta.assignment_method,
            ta.assignment_status,
            ta.assigned_at,
            ta.accepted_at,
            ta.started_at,
            ta.completed_at,
            tp.technician_id,
            tu.user_id AS technician_user_id,
            tu.full_name AS technician_name,
            ts.skill_name AS technician_primary_skill,
            (
                SELECT note
                FROM ticket_updates ru
                WHERE ru.ticket_id = mt.ticket_id
                  AND ru.update_type IN ('Repair Note','Completion Note')
                  AND ru.note IS NOT NULL
                ORDER BY ru.created_at DESC, ru.update_id DESC
                LIMIT 1
            ) AS latest_repair_note,
            (
                SELECT original_file_name
                FROM ticket_attachments ca
                WHERE ca.ticket_id = mt.ticket_id
                  AND ca.attachment_type = 'Completion Proof'
                  AND ca.deleted_at IS NULL
                ORDER BY ca.uploaded_at DESC, ca.attachment_id DESC
                LIMIT 1
            ) AS completion_proof_name
        FROM maintenance_tickets mt
        INNER JOIN resident_profiles rp ON rp.resident_id = mt.resident_id
        INNER JOIN users u ON u.user_id = rp.user_id
        INNER JOIN buildings b ON b.building_id = mt.building_id
        INNER JOIN floors f ON f.floor_id = mt.floor_id
        LEFT JOIN areas a ON a.area_id = mt.area_id
        LEFT JOIN issue_categories ic ON ic.category_id = mt.current_category_id
        LEFT JOIN ai_predictions ap ON ap.ticket_id = mt.ticket_id AND ap.is_current = TRUE
        LEFT JOIN issue_categories pic ON pic.category_id = ap.predicted_category_id
        LEFT JOIN skills rs ON rs.skill_id = ap.recommended_skill_id
        LEFT JOIN maintenance_tickets dm ON dm.ticket_id = ap.duplicate_ticket_id
        LEFT JOIN ticket_assignments ta ON ta.ticket_id = mt.ticket_id AND ta.is_current = TRUE
        LEFT JOIN technician_profiles tp ON tp.technician_id = ta.technician_id
        LEFT JOIN users tu ON tu.user_id = tp.user_id
        LEFT JOIN technician_skills tsk ON tsk.technician_id = tp.technician_id AND tsk.is_primary = TRUE
        LEFT JOIN skills ts ON ts.skill_id = tsk.skill_id
        WHERE 1=1 {extra_where}
    """


def serialize_ticket(row):
    if not row:
        return None
    current_priority = row.get('current_priority') or row.get('predicted_priority')
    current_risk = row.get('current_risk_score')
    if current_risk is None:
        current_risk = row.get('predicted_risk_score')
    current_risk_level = row.get('current_risk_level') or row.get('predicted_risk_level')
    category = row.get('category_name') or row.get('predicted_category_name')
    confidence_values = [v for v in (row.get('category_confidence'), row.get('priority_confidence')) if v is not None]
    confidence = round(sum(float(v) for v in confidence_values) / len(confidence_values) * 100) if confidence_values else None
    risk_number = _float(current_risk)
    emergency_threshold = get_int_setting('emergency_risk_threshold', 86, 60, 100)
    is_emergency = current_priority == 'Emergency' or current_risk_level == 'Critical' or (risk_number is not None and risk_number >= emergency_threshold)
    return {
        'ticket_id': _int(row.get('ticket_id')),
        'id': row.get('ticket_number'),
        'residentId': _int(row.get('resident_user_id')),
        'residentProfileId': _int(row.get('resident_id')),
        'resident': row.get('resident_name'),
        'residentEmail': row.get('resident_email'),
        'title': row.get('subject'),
        'description': row.get('description'),
        'language': row.get('language_type') or 'Unknown',
        'buildingId': _int(row.get('building_id')),
        'block': row.get('block_code'),
        'building': row.get('building_name'),
        'floorId': _int(row.get('floor_id')),
        'floor': row.get('floor_name') or str(row.get('floor_number')),
        'floorNumber': row.get('floor_number'),
        'areaId': _int(row.get('area_id')),
        'area': row.get('area_name') or 'Not specified',
        'asset': row.get('asset_type') or 'Not specified',
        'categoryId': _int(row.get('category_id')),
        'category': category or 'Awaiting analysis',
        'priority': current_priority or 'Pending',
        'risk': round(risk_number, 1) if risk_number is not None else None,
        'riskLevel': current_risk_level or 'Pending',
        'safety': row.get('safety_warning') or ('Safety flag requires review.' if row.get('safety_flag') else 'No AI safety warning is available yet.'),
        'duplicate': bool(row.get('duplicate_flag') or row.get('duplicate_ticket_id')),
        'duplicateOf': row.get('duplicate_ticket_number'),
        'duplicateSimilarity': round(float(row['duplicate_similarity']) * 100, 1) if row.get('duplicate_similarity') is not None else None,
        'confidence': confidence,
        'technicianType': row.get('recommended_skill_name') or row.get('technician_primary_skill') or 'Not recommended yet',
        'technicianId': _int(row.get('technician_id')),
        'technician': row.get('technician_name'),
        'status': row.get('current_status'),
        'assignmentStatus': row.get('assignment_status'),
        'assignmentMethod': row.get('assignment_method'),
        'created': row.get('submitted_at').isoformat() if row.get('submitted_at') else None,
        'updated': row.get('updated_at').isoformat() if row.get('updated_at') else None,
        'repairNote': row.get('latest_repair_note') or '',
        'proof': row.get('completion_proof_name') or '',
        'emergency': is_emergency,
        'predictionAvailable': bool(row.get('prediction_id')),
        'predictionStatus': row.get('prediction_review_status'),
        'manualReviewRequired': bool(row.get('manual_review_required')),
    }


def redact_ticket_for_role(ticket, role):
    if not ticket:
        return ticket
    data = dict(ticket)
    # Contact information is not required in normal ticket screens.
    data.pop('residentEmail', None)
    if role == 'technician':
        data.pop('residentId', None)
        data.pop('residentProfileId', None)
    if role == 'resident':
        data.pop('technicianId', None)
    return data


def get_ticket(ticket_number, user_id=None, role=None):
    params = [ticket_number]
    extra = ' AND mt.ticket_number = %s '
    if role == 'resident':
        extra += ' AND u.user_id = %s '
        params.append(user_id)
    elif role == 'technician':
        extra += ' AND tu.user_id = %s '
        params.append(user_id)
    row = query_one(_ticket_base_sql(extra) + ' LIMIT 1', tuple(params))
    if not row:
        return None
    ticket = serialize_ticket(row)
    ticket['timeline'] = get_ticket_timeline(ticket['ticket_id'], role)
    return redact_ticket_for_role(ticket, role)


def get_ticket_timeline(ticket_id, role=None):
    visibility = ' AND resident_visible = TRUE ' if role == 'resident' else ''
    rows = query_all(
        f"""
        SELECT tu.update_id, tu.update_type, tu.status_from, tu.status_to, tu.note,
               tu.created_at, u.full_name AS updated_by_name
        FROM ticket_updates tu
        LEFT JOIN users u ON u.user_id = tu.updated_by
        WHERE tu.ticket_id = %s {visibility}
        ORDER BY tu.created_at, tu.update_id
        """,
        (ticket_id,),
    )
    result = []
    for row in rows:
        result.append({
            'id': _int(row['update_id']),
            'type': row['update_type'],
            'from': row['status_from'],
            'to': row['status_to'],
            'note': row['note'],
            'by': row['updated_by_name'] or 'System',
            'created': row['created_at'].isoformat() if row['created_at'] else None,
        })
    return result


def get_resident_context(user_id):
    return query_one(
        """
        SELECT rp.resident_id, rp.building_id, rp.floor_id, rp.unit_id, rp.unit_number,
               u.complex_id
        FROM resident_profiles rp
        INNER JOIN users u ON u.user_id = rp.user_id
        WHERE rp.user_id = %s AND rp.profile_status = 'Active'
        LIMIT 1
        """,
        (user_id,),
    )


def resident_ticket_options(user_id):
    context = get_resident_context(user_id)
    if not context:
        return None
    buildings = query_all(
        "SELECT building_id, block_code, name FROM buildings WHERE building_id=%s AND complex_id=%s AND status='Active' ORDER BY block_code",
        (context['building_id'], context['complex_id']),
    )
    floors = query_all(
        """
        SELECT f.floor_id, f.building_id, f.floor_number, f.name
        FROM floors f INNER JOIN buildings b ON b.building_id=f.building_id
        WHERE f.building_id=%s AND b.complex_id=%s AND f.status='Active'
        ORDER BY f.floor_number
        """,
        (context['building_id'], context['complex_id']),
    )
    areas = query_all(
        """
        SELECT a.area_id, a.building_id, a.floor_id, a.name, a.area_type
        FROM areas a INNER JOIN buildings b ON b.building_id=a.building_id
        WHERE a.building_id=%s AND b.complex_id=%s AND a.status='Active'
        ORDER BY a.floor_id, a.name
        """,
        (context['building_id'], context['complex_id']),
    )
    return {
        'resident': {
            'building_id': _int(context['building_id']),
            'floor_id': _int(context['floor_id']),
            'unit_id': _int(context['unit_id']),
            'unit_number': context['unit_number'],
        },
        'buildings': [{**x, 'building_id': _int(x['building_id'])} for x in buildings],
        'floors': [{**x, 'floor_id': _int(x['floor_id']), 'building_id': _int(x['building_id'])} for x in floors],
        'areas': [{**x, 'area_id': _int(x['area_id']), 'building_id': _int(x['building_id']), 'floor_id': _int(x['floor_id'])} for x in areas],
    }


def _validate_location(connection, complex_id, building_id, floor_id, area_id):
    with connection.cursor() as cursor:
        cursor.execute(
            "SELECT building_id, block_code FROM buildings WHERE building_id=%s AND complex_id=%s AND status='Active'",
            (building_id, complex_id),
        )
        building = cursor.fetchone()
        if not building:
            return None, None, None, 'Select a valid building.'
        cursor.execute(
            "SELECT floor_id, name FROM floors WHERE floor_id=%s AND building_id=%s AND status='Active'",
            (floor_id, building_id),
        )
        floor = cursor.fetchone()
        if not floor:
            return None, None, None, 'Select a valid floor for the building.'
        area = None
        if area_id:
            cursor.execute(
                """
                SELECT area_id, name FROM areas
                WHERE area_id=%s AND building_id=%s AND status='Active'
                  AND (floor_id IS NULL OR floor_id=%s)
                """,
                (area_id, building_id, floor_id),
            )
            area = cursor.fetchone()
            if not area:
                return None, None, None, 'Select a valid maintenance area.'
        return building, floor, area, None


def create_ticket(user_id, payload, upload_file=None, upload_root=None, ip_address=None, user_agent=None):
    upload_error = _validate_upload(upload_file)
    if upload_error:
        return None, upload_error, 400
    title = (payload.get('title') or '').strip()[:180]
    description = (payload.get('description') or '').strip()
    asset_type = (payload.get('asset') or '').strip()[:100] or None
    if len(title) < 4:
        return None, 'Enter a short issue title.', 400
    if len(description) < 10:
        return None, 'Describe the maintenance problem in a little more detail.', 400
    try:
        building_id = int(payload.get('building_id'))
        floor_id = int(payload.get('floor_id'))
        area_id = int(payload.get('area_id')) if payload.get('area_id') else None
    except (TypeError, ValueError):
        return None, 'Select a valid building, floor and area.', 400

    connection = get_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                SELECT rp.resident_id, rp.building_id, rp.unit_id, rp.unit_number, u.complex_id
                FROM resident_profiles rp INNER JOIN users u ON u.user_id=rp.user_id
                WHERE rp.user_id=%s AND rp.profile_status='Active' LIMIT 1 FOR UPDATE
                """,
                (user_id,),
            )
            resident = cursor.fetchone()
            if not resident:
                connection.rollback()
                return None, 'Resident profile could not be found.', 404
            if not resident.get('building_id') or int(building_id) != int(resident['building_id']):
                connection.rollback()
                return None, 'Maintenance tickets can only be submitted for your registered building.', 403

            building, floor, area, location_error = _validate_location(
                connection, resident['complex_id'], building_id, floor_id, area_id
            )
            if location_error:
                connection.rollback()
                return None, location_error, 400

            cursor.execute(
                """
                INSERT INTO maintenance_tickets
                    (ticket_number, resident_id, building_id, floor_id, unit_id, area_id,
                     unit_number_snapshot, subject, description, language_type, asset_type,
                     current_status, manual_review_required)
                VALUES ('', %s, %s, %s, %s, %s, %s, %s, %s, 'Unknown', %s, 'Analysing', TRUE)
                """,
                (
                    resident['resident_id'], building_id, floor_id, resident['unit_id'], area_id,
                    resident['unit_number'], title, description, asset_type,
                ),
            )
            ticket_id = cursor.lastrowid
            cursor.execute('SELECT ticket_number FROM maintenance_tickets WHERE ticket_id=%s', (ticket_id,))
            ticket_number = cursor.fetchone()['ticket_number']
            cursor.execute(
                """
                INSERT INTO ticket_updates
                    (ticket_id, updated_by, update_type, status_from, status_to, note, resident_visible)
                VALUES (%s, %s, 'System Event', 'Submitted', 'Analysing',
                        'Ticket stored in the live database. Local multilingual AI analysis has started.', TRUE)
                """,
                (ticket_id, user_id),
            )
            cursor.execute(
                """
                INSERT INTO notifications
                    (user_id, ticket_id, event_type, channel, title, message, delivery_status)
                VALUES (%s, %s, 'Ticket Created', 'In App', 'Maintenance ticket received',
                        %s, 'Delivered')
                """,
                (user_id, ticket_id, f'{ticket_number} was saved successfully and local AI analysis has started.'),
            )
            cursor.execute(
                """
                INSERT INTO audit_logs
                    (user_id, action_type, entity_type, entity_id, new_value, reason, ip_address, user_agent)
                VALUES (%s, 'Ticket Submitted', 'maintenance_tickets', %s, %s,
                        'Resident submitted a live maintenance ticket through the Flask application.', %s, %s)
                """,
                (
                    user_id, str(ticket_id),
                    json.dumps({'ticket_number': ticket_number, 'subject': title}),
                    (ip_address or '')[:45], (user_agent or '')[:500],
                ),
            )

        connection.commit()
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()

    if upload_file and upload_file.filename:
        save_ticket_attachment(ticket_id, user_id, upload_file, 'Issue Photo', upload_root)

    try:
        from services.ai_service import analyse_ticket
        analyse_ticket(ticket_id, initiated_by=user_id, ip_address=ip_address, user_agent=user_agent)
    except Exception as exc:
        # The software must still keep the resident ticket if the local AI module cannot load.
        fallback = get_connection()
        try:
            with fallback.cursor() as cursor:
                cursor.execute(
                    "UPDATE maintenance_tickets SET current_status='Awaiting Review',manual_review_required=TRUE WHERE ticket_id=%s",
                    (ticket_id,),
                )
                cursor.execute(
                    """
                    INSERT INTO ticket_updates(ticket_id,updated_by,update_type,status_from,status_to,note,resident_visible)
                    VALUES(%s,%s,'System Event','Analysing','Awaiting Review',%s,TRUE)
                    """,
                    (ticket_id, user_id, ('Local AI analysis could not complete. Apartment admin manual review is required. ' + str(exc))[:2000]),
                )
                cursor.execute(
                    """
                    SELECT DISTINCT u.user_id
                    FROM users u
                    INNER JOIN roles r ON r.role_id=u.role_id
                    INNER JOIN apartment_admin_profiles ap ON ap.user_id=u.user_id
                    WHERE u.complex_id=%s AND r.role_code='apartment_admin' AND u.account_status='Active'
                      AND ap.active=TRUE AND ap.primary_building_id=%s
                    """,
                    (resident['complex_id'], building_id),
                )
                for admin in cursor.fetchall():
                    cursor.execute(
                        "INSERT INTO notifications(user_id,ticket_id,event_type,channel,title,message,delivery_status) VALUES(%s,%s,'AI Fallback','In App','Manual ticket review required',%s,'Delivered')",
                        (admin['user_id'], ticket_id, f'{ticket_number} could not complete local AI analysis and requires manual review.'),
                    )
            fallback.commit()
        except Exception:
            fallback.rollback()
            raise
        finally:
            fallback.close()

    return get_ticket(ticket_number, user_id=user_id, role='resident'), None, 201


def save_ticket_attachment(ticket_id, user_id, upload_file, attachment_type, upload_root, update_id=None):
    if not upload_file or not upload_file.filename:
        return None
    upload_error = _validate_upload(upload_file)
    if upload_error:
        raise ValueError(upload_error)
    original_name = secure_filename(upload_file.filename)[:255]
    if not original_name:
        raise ValueError('The selected file name is invalid.')
    extension = Path(original_name).suffix.lower()
    stored_name = f'{uuid.uuid4().hex}{extension}'
    root = Path(upload_root or 'uploads').resolve()
    folder = root / 'tickets' / str(ticket_id)
    folder.mkdir(parents=True, exist_ok=True)
    target = folder / stored_name
    upload_file.save(target)
    data = target.read_bytes()
    checksum = hashlib.sha256(data).hexdigest()
    relative_path = str(target.relative_to(root)).replace(os.sep, '/')
    connection = get_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                INSERT INTO ticket_attachments
                    (ticket_id, update_id, uploaded_by, attachment_type, original_file_name,
                     stored_file_name, storage_path, mime_type, file_size_bytes, checksum_sha256, resident_visible)
                VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,TRUE)
                """,
                (ticket_id, update_id, user_id, attachment_type, original_name, stored_name,
                 relative_path, upload_file.mimetype, len(data), checksum),
            )
            attachment_id = cursor.lastrowid
        connection.commit()
        return attachment_id
    except Exception:
        connection.rollback()
        try:
            target.unlink(missing_ok=True)
        except Exception:
            pass
        raise
    finally:
        connection.close()


def resident_tickets(user_id, search='', status='', priority=''):
    clauses = [' AND u.user_id=%s ']
    params = [user_id]
    if search:
        clauses.append(' AND (mt.ticket_number LIKE %s OR mt.subject LIKE %s OR COALESCE(ic.name, pic.name, \'\') LIKE %s) ')
        term = f'%{search}%'
        params.extend([term, term, term])
    if status:
        clauses.append(' AND mt.current_status=%s ')
        params.append(status)
    if priority:
        clauses.append(' AND COALESCE(mt.current_priority, ap.predicted_priority)=%s ')
        params.append(priority)
    rows = query_all(_ticket_base_sql(''.join(clauses)) + ' ORDER BY mt.submitted_at DESC', tuple(params))
    return [redact_ticket_for_role(serialize_ticket(r), 'resident') for r in rows]


def resident_dashboard(user_id):
    tickets = resident_tickets(user_id)
    notifications = list_notifications(user_id, limit=4)
    active = [t for t in tickets if t['status'] not in CLOSED_TICKET_STATUSES]
    return {
        'stats': {
            'total': len(tickets),
            'open': len(active),
            'emergency': sum(1 for t in active if t['emergency']),
            'completed': sum(1 for t in tickets if t['status'] in ('Resolved', 'Closed')),
        },
        'recent_tickets': tickets[:5],
        'notifications': notifications,
    }


def list_notifications(user_id, limit=None):
    retention_days = get_int_setting('notification_retention_days', 90, 7, 365)
    cleanup = get_connection()
    try:
        with cleanup.cursor() as cursor:
            cursor.execute(
                f"DELETE FROM notifications WHERE read_at IS NOT NULL AND created_at < DATE_SUB(NOW(), INTERVAL {retention_days} DAY)"
            )
        cleanup.commit()
    finally:
        cleanup.close()
    sql = """
        SELECT n.notification_id, n.ticket_id, mt.ticket_number, n.event_type, n.title, n.message,
               n.delivery_status, n.created_at, n.read_at
        FROM notifications n
        LEFT JOIN maintenance_tickets mt ON mt.ticket_id=n.ticket_id
        WHERE n.user_id=%s AND n.channel='In App'
        ORDER BY n.created_at DESC, n.notification_id DESC
    """
    params = [user_id]
    if limit:
        sql += ' LIMIT %s'
        params.append(int(limit))
    rows = query_all(sql, tuple(params))
    return [{
        'id': _int(r['notification_id']), 'ticketId': r['ticket_number'], 'type': r['event_type'],
        'title': r['title'], 'text': r['message'],
        'time': r['created_at'].isoformat() if r['created_at'] else None,
        'read': bool(r['read_at']) or r['delivery_status'] == 'Read',
    } for r in rows]


def mark_notifications_read(user_id):
    connection = get_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                UPDATE notifications SET read_at=COALESCE(read_at,NOW()), delivery_status='Read'
                WHERE user_id=%s AND channel='In App' AND read_at IS NULL
                """,
                (user_id,),
            )
            changed = cursor.rowcount
        connection.commit()
        return changed
    finally:
        connection.close()


def admin_tickets(search='', status='', priority='', category=''):
    clauses = []
    params = []
    if search:
        clauses.append(' AND (mt.ticket_number LIKE %s OR mt.subject LIKE %s OR u.full_name LIKE %s) ')
        term = f'%{search}%'
        params.extend([term, term, term])
    if status:
        clauses.append(' AND mt.current_status=%s ')
        params.append(status)
    if priority:
        clauses.append(' AND COALESCE(mt.current_priority, ap.predicted_priority)=%s ')
        params.append(priority)
    if category:
        clauses.append(' AND COALESCE(ic.name, pic.name)=%s ')
        params.append(category)
    rows = query_all(_ticket_base_sql(''.join(clauses)) + ' ORDER BY mt.submitted_at DESC', tuple(params))
    return [serialize_ticket(r) for r in rows]


def admin_dashboard():
    tickets = admin_tickets()
    available = query_one("SELECT COUNT(*) AS c FROM technician_profiles WHERE active=TRUE AND availability='Available'")['c']
    active = [t for t in tickets if t['status'] not in CLOSED_TICKET_STATUSES]
    pending_statuses = {'Submitted', 'Analysing', 'Awaiting Review', 'Urgent Unassigned'}
    return {
        'stats': {
            'active': len(active),
            'pending_review': sum(1 for t in tickets if t['status'] in pending_statuses),
            'emergency': sum(1 for t in active if t['emergency']),
            'available_technicians': int(available),
        },
        'recent_tickets': tickets[:6],
        'emergencies': [t for t in active if t['emergency']][:4],
    }


def categories():
    return query_all("SELECT category_id, name, default_skill_id FROM issue_categories WHERE active=TRUE ORDER BY name")


def technician_candidates(ticket_number):
    ticket = get_ticket(ticket_number)
    if not ticket:
        return None
    required_skill_id = query_one(
        """
        SELECT COALESCE(ic.default_skill_id, ap.recommended_skill_id) AS skill_id
        FROM maintenance_tickets mt
        LEFT JOIN issue_categories ic ON ic.category_id=mt.current_category_id
        LEFT JOIN ai_predictions ap ON ap.ticket_id=mt.ticket_id AND ap.is_current=TRUE
        WHERE mt.ticket_number=%s LIMIT 1
        """,
        (ticket_number,),
    )
    skill_id = required_skill_id['skill_id'] if required_skill_id else None
    rows = query_all(
        """
        SELECT tp.technician_id, u.full_name, u.phone, tp.employee_code, tp.availability,
               tp.current_workload, tp.max_active_jobs, tp.emergency_eligible,
               tp.rating, b.block_code,
               GROUP_CONCAT(DISTINCT s.skill_name ORDER BY ts.is_primary DESC, s.skill_name SEPARATOR ', ') AS skills,
               MAX(CASE WHEN ts.skill_id=%s THEN 1 ELSE 0 END) AS skill_match
        FROM technician_profiles tp
        INNER JOIN users u ON u.user_id=tp.user_id
        LEFT JOIN buildings b ON b.building_id=tp.assigned_building_id
        LEFT JOIN technician_skills ts ON ts.technician_id=tp.technician_id AND ts.verified=TRUE
        LEFT JOIN skills s ON s.skill_id=ts.skill_id
        WHERE tp.active=TRUE AND u.account_status='Active'
        GROUP BY tp.technician_id, u.full_name, u.phone, tp.employee_code, tp.availability,
                 tp.current_workload, tp.max_active_jobs, tp.emergency_eligible, tp.rating, b.block_code
        ORDER BY skill_match DESC,
                 CASE tp.availability WHEN 'Available' THEN 0 WHEN 'Busy' THEN 1 ELSE 2 END,
                 tp.current_workload ASC, tp.rating DESC
        """,
        (skill_id or 0,),
    )
    candidates = []
    for r in rows:
        candidates.append({
            'id': _int(r['technician_id']), 'name': r['full_name'], 'phone': r['phone'],
            'employeeCode': r['employee_code'], 'status': r['availability'],
            'workload': _int(r['current_workload']), 'maxJobs': _int(r['max_active_jobs']),
            'emergency': bool(r['emergency_eligible']), 'rating': _float(r['rating']),
            'block': r['block_code'] or 'Any block', 'skills': r['skills'] or 'No verified skill',
            'skillMatch': bool(r['skill_match']),
        })
    return {'ticket': ticket, 'candidates': candidates}


def review_ticket(admin_user_id, ticket_number, category_name=None, priority=None, note=None, ip_address=None, user_agent=None):
    allowed_priorities = {'Emergency', 'High', 'Medium', 'Low'}
    if priority and priority not in allowed_priorities:
        return None, 'Select a valid priority.', 400
    category_id = None
    if category_name:
        row = query_one("SELECT category_id FROM issue_categories WHERE name=%s AND active=TRUE LIMIT 1", (category_name,))
        if not row:
            return None, 'Select a valid issue category.', 400
        category_id = row['category_id']
    connection = get_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute("""
                SELECT mt.ticket_id,mt.current_status,mt.current_category_id,mt.current_priority,
                       ap.prediction_id,ap.predicted_category_id,ap.predicted_priority
                FROM maintenance_tickets mt
                LEFT JOIN ai_predictions ap ON ap.ticket_id=mt.ticket_id AND ap.is_current=TRUE
                WHERE mt.ticket_number=%s FOR UPDATE
            """, (ticket_number,))
            ticket = cursor.fetchone()
            if not ticket:
                connection.rollback(); return None, 'Ticket not found.', 404
            new_category = category_id if category_id is not None else ticket['current_category_id']
            new_priority = priority if priority else ticket['current_priority']
            new_status = 'Awaiting Review' if ticket['current_status'] in ('Submitted','Analysing') else ticket['current_status']
            cursor.execute(
                """
                UPDATE maintenance_tickets
                SET current_category_id=%s, current_priority=%s, current_status=%s, manual_review_required=FALSE
                WHERE ticket_id=%s
                """,
                (new_category, new_priority, new_status, ticket['ticket_id']),
            )
            cursor.execute(
                """
                INSERT INTO ticket_updates(ticket_id,updated_by,update_type,status_from,status_to,note,resident_visible)
                VALUES(%s,%s,'Admin Note',%s,%s,%s,TRUE)
                """,
                (ticket['ticket_id'], admin_user_id, ticket['current_status'], new_status,
                 (note or 'Apartment admin reviewed the ticket classification and priority.').strip()[:2000]),
            )

            if ticket.get('prediction_id'):
                category_changed = new_category is not None and new_category != ticket.get('predicted_category_id')
                priority_changed = new_priority is not None and new_priority != ticket.get('predicted_priority')
                if category_changed or priority_changed:
                    cursor.execute(
                        """
                        INSERT INTO ai_corrections
                            (prediction_id,corrected_by,corrected_category_id,corrected_priority,reason)
                        VALUES(%s,%s,%s,%s,%s)
                        """,
                        (ticket['prediction_id'], admin_user_id,
                         new_category if category_changed else None,
                         new_priority if priority_changed else None,
                         (note or 'Apartment admin corrected the stored AI result during ticket review.')[:1000]),
                    )
                    cursor.execute("UPDATE ai_predictions SET review_status='Corrected' WHERE prediction_id=%s", (ticket['prediction_id'],))
                else:
                    cursor.execute("UPDATE ai_predictions SET review_status='Accepted' WHERE prediction_id=%s", (ticket['prediction_id'],))
            cursor.execute(
                """
                INSERT INTO audit_logs(user_id,action_type,entity_type,entity_id,old_value,new_value,reason,ip_address,user_agent)
                VALUES(%s,'Ticket Review','maintenance_tickets',%s,%s,%s,%s,%s,%s)
                """,
                (admin_user_id, str(ticket['ticket_id']),
                 json.dumps({'category_id': _int(ticket['current_category_id']), 'priority': ticket['current_priority']}),
                 json.dumps({'category_id': _int(new_category), 'priority': new_priority}),
                 'Apartment admin reviewed the live ticket.', (ip_address or '')[:45], (user_agent or '')[:500]),
            )
        connection.commit()
    except Exception:
        connection.rollback(); raise
    finally:
        connection.close()
    return get_ticket(ticket_number), None, 200


def assign_technician(admin_user_id, ticket_number, technician_id, reason=None, ip_address=None, user_agent=None):
    try:
        technician_id = int(technician_id)
    except (TypeError, ValueError):
        return None, 'Select a valid technician.', 400
    connection = get_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute("SELECT ticket_id,current_status FROM maintenance_tickets WHERE ticket_number=%s FOR UPDATE", (ticket_number,))
            ticket = cursor.fetchone()
            if not ticket:
                connection.rollback(); return None, 'Ticket not found.', 404
            if ticket['current_status'] in CLOSED_TICKET_STATUSES:
                connection.rollback(); return None, 'A closed or cancelled ticket cannot be assigned.', 409
            cursor.execute(
                """
                SELECT tp.technician_id,tp.availability,tp.current_workload,tp.max_active_jobs,u.full_name
                FROM technician_profiles tp INNER JOIN users u ON u.user_id=tp.user_id
                WHERE tp.technician_id=%s AND tp.active=TRUE AND u.account_status='Active' FOR UPDATE
                """,
                (technician_id,),
            )
            technician = cursor.fetchone()
            if not technician:
                connection.rollback(); return None, 'Technician is not available for assignment.', 404
            if technician['availability'] in ('Off Duty','On Leave'):
                connection.rollback(); return None, 'This technician is currently off duty or on leave.', 409
            if int(technician['current_workload']) >= int(technician['max_active_jobs']):
                connection.rollback(); return None, 'This technician has reached the maximum active workload.', 409
            cursor.execute("SELECT assignment_id,technician_id FROM ticket_assignments WHERE ticket_id=%s AND is_current=TRUE FOR UPDATE", (ticket['ticket_id'],))
            previous = cursor.fetchone()
            method = 'Reassignment' if previous else 'Manual'
            if previous:
                if int(previous['technician_id']) == technician_id:
                    connection.rollback(); return None, 'This technician is already assigned to the ticket.', 409
                cursor.execute("UPDATE ticket_assignments SET is_current=FALSE,assignment_status='Reassigned',updated_at=NOW() WHERE assignment_id=%s", (previous['assignment_id'],))
            cursor.execute(
                """
                INSERT INTO ticket_assignments
                    (ticket_id,technician_id,assignment_method,assigned_by,assignment_status,assignment_reason,is_current)
                VALUES(%s,%s,%s,%s,'Assigned',%s,TRUE)
                """,
                (ticket['ticket_id'], technician_id, method, admin_user_id, (reason or 'Manual assignment by apartment admin.')[:1000]),
            )
            cursor.execute("UPDATE maintenance_tickets SET current_status='Assigned' WHERE ticket_id=%s", (ticket['ticket_id'],))
            cursor.execute(
                """
                INSERT INTO ticket_updates(ticket_id,updated_by,update_type,status_from,status_to,note,resident_visible)
                VALUES(%s,%s,'System Event',%s,'Assigned',%s,TRUE)
                """,
                (ticket['ticket_id'], admin_user_id, ticket['current_status'], f"Assigned to {technician['full_name']} by apartment admin."),
            )
            cursor.execute("SELECT resident_id FROM maintenance_tickets WHERE ticket_id=%s", (ticket['ticket_id'],))
            resident_id = cursor.fetchone()['resident_id']
            cursor.execute("SELECT user_id FROM resident_profiles WHERE resident_id=%s", (resident_id,))
            resident_user = cursor.fetchone()['user_id']
            cursor.execute(
                "INSERT INTO notifications(user_id,ticket_id,event_type,channel,title,message,delivery_status) VALUES(%s,%s,'Ticket Assignment','In App','Technician assigned',%s,'Delivered')",
                (resident_user, ticket['ticket_id'], f"{ticket_number} was assigned to {technician['full_name']}."),
            )
            cursor.execute("SELECT user_id FROM technician_profiles WHERE technician_id=%s", (technician_id,))
            technician_user = cursor.fetchone()['user_id']
            cursor.execute(
                "INSERT INTO notifications(user_id,ticket_id,event_type,channel,title,message,delivery_status) VALUES(%s,%s,'Ticket Assignment','In App','New maintenance job',%s,'Delivered')",
                (technician_user, ticket['ticket_id'], f"{ticket_number} has been assigned to you."),
            )
            cursor.execute(
                """
                INSERT INTO audit_logs(user_id,action_type,entity_type,entity_id,new_value,reason,ip_address,user_agent)
                VALUES(%s,'Technician Assigned','maintenance_tickets',%s,%s,%s,%s,%s)
                """,
                (admin_user_id, str(ticket['ticket_id']), json.dumps({'technician_id': technician_id, 'method': method}),
                 (reason or 'Manual assignment by apartment admin.')[:1000], (ip_address or '')[:45], (user_agent or '')[:500]),
            )
        connection.commit()
    except Exception:
        connection.rollback(); raise
    finally:
        connection.close()
    return get_ticket(ticket_number), None, 200


def duplicate_groups():
    rows = query_all(
        """
        SELECT dm.duplicate_match_id, dm.similarity_score, dm.match_status, dm.review_notes, dm.created_at,
               s.ticket_number AS source_number, s.subject AS source_subject, sb.block_code AS source_block,
               sf.name AS source_floor, s.current_status AS source_status,
               m.ticket_number AS matched_number, m.subject AS matched_subject, mb.block_code AS matched_block,
               mf.name AS matched_floor, m.current_status AS matched_status
        FROM duplicate_matches dm
        INNER JOIN maintenance_tickets s ON s.ticket_id=dm.source_ticket_id
        INNER JOIN buildings sb ON sb.building_id=s.building_id
        INNER JOIN floors sf ON sf.floor_id=s.floor_id
        INNER JOIN maintenance_tickets m ON m.ticket_id=dm.matched_ticket_id
        INNER JOIN buildings mb ON mb.building_id=m.building_id
        INNER JOIN floors mf ON mf.floor_id=m.floor_id
        ORDER BY dm.created_at DESC
        """
    )
    return [{
        'id': _int(r['duplicate_match_id']), 'similarity': round(float(r['similarity_score']) * 100, 1),
        'status': r['match_status'], 'notes': r['review_notes'],
        'created': r['created_at'].isoformat() if r['created_at'] else None,
        'source': {'id': r['source_number'], 'title': r['source_subject'], 'block': r['source_block'], 'floor': r['source_floor'], 'status': r['source_status']},
        'matched': {'id': r['matched_number'], 'title': r['matched_subject'], 'block': r['matched_block'], 'floor': r['matched_floor'], 'status': r['matched_status']},
    } for r in rows]



def review_duplicate_match(admin_user_id, match_id, action, note=None, ip_address=None, user_agent=None):
    status_map = {'confirm': 'Confirmed', 'reject': 'Rejected', 'link': 'Linked'}
    new_status = status_map.get(str(action or '').strip().lower())
    if not new_status:
        return None, 'Select confirm, reject or link.', 400
    connection = get_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute(
                "SELECT duplicate_match_id,source_ticket_id,matched_ticket_id,match_status FROM duplicate_matches WHERE duplicate_match_id=%s FOR UPDATE",
                (match_id,),
            )
            row = cursor.fetchone()
            if not row:
                connection.rollback(); return None, 'Duplicate record not found.', 404
            cursor.execute(
                "UPDATE duplicate_matches SET match_status=%s,reviewed_by=%s,review_notes=%s,reviewed_at=NOW() WHERE duplicate_match_id=%s",
                (new_status, admin_user_id, (note or '')[:1000] or None, match_id),
            )
            if new_status in {'Confirmed','Linked'}:
                cursor.execute("UPDATE maintenance_tickets SET duplicate_flag=TRUE WHERE ticket_id=%s", (row['source_ticket_id'],))
            elif new_status == 'Rejected':
                cursor.execute(
                    "SELECT COUNT(*) AS c FROM duplicate_matches WHERE source_ticket_id=%s AND duplicate_match_id<>%s AND match_status IN ('Pending','Confirmed','Linked')",
                    (row['source_ticket_id'], match_id),
                )
                remaining = int((cursor.fetchone() or {}).get('c') or 0)
                if remaining == 0:
                    cursor.execute("UPDATE maintenance_tickets SET duplicate_flag=FALSE WHERE ticket_id=%s", (row['source_ticket_id'],))
            cursor.execute(
                "INSERT INTO audit_logs(user_id,action_type,entity_type,entity_id,new_value,reason,ip_address,user_agent) VALUES(%s,'DUPLICATE_REVIEW','duplicate_matches',%s,%s,%s,%s,%s)",
                (admin_user_id, str(match_id), json.dumps({'status': new_status}), (note or 'Duplicate match reviewed by Apartment Admin')[:1000], (ip_address or '')[:45], (user_agent or '')[:500]),
            )
        connection.commit()
        return {'id': int(match_id), 'status': new_status}, None, 200
    except Exception:
        connection.rollback(); raise
    finally:
        connection.close()

def admin_technicians():
    rows = query_all(
        """
        SELECT tp.technician_id,u.full_name,u.phone,tp.employee_code,tp.availability,tp.current_workload,
               tp.max_active_jobs,tp.emergency_eligible,tp.rating,b.block_code,
               GROUP_CONCAT(DISTINCT s.skill_name ORDER BY ts.is_primary DESC,s.skill_name SEPARATOR ', ') AS skills
        FROM technician_profiles tp INNER JOIN users u ON u.user_id=tp.user_id
        LEFT JOIN buildings b ON b.building_id=tp.assigned_building_id
        LEFT JOIN technician_skills ts ON ts.technician_id=tp.technician_id AND ts.verified=TRUE
        LEFT JOIN skills s ON s.skill_id=ts.skill_id
        WHERE tp.active=TRUE
        GROUP BY tp.technician_id,u.full_name,u.phone,tp.employee_code,tp.availability,tp.current_workload,
                 tp.max_active_jobs,tp.emergency_eligible,tp.rating,b.block_code
        ORDER BY u.full_name
        """
    )
    return [{
        'id': _int(r['technician_id']), 'name': r['full_name'], 'phone': r['phone'], 'employeeCode': r['employee_code'],
        'status': r['availability'], 'workload': _int(r['current_workload']), 'maxJobs': _int(r['max_active_jobs']),
        'emergency': bool(r['emergency_eligible']), 'rating': _float(r['rating']), 'block': r['block_code'] or 'Any block',
        'skill': r['skills'] or 'No verified skill',
    } for r in rows]


def update_technician_availability(technician_id, availability):
    allowed = {'Available','Busy','Off Duty','On Leave'}
    if availability not in allowed:
        return False
    connection = get_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute("UPDATE technician_profiles SET availability=%s,last_availability_change_at=NOW() WHERE technician_id=%s AND active=TRUE", (availability, technician_id))
            changed = cursor.rowcount
        connection.commit(); return bool(changed)
    finally:
        connection.close()


def technician_profile_for_user(user_id):
    row = query_one(
        """
        SELECT tp.technician_id,u.full_name,u.email,u.phone,tp.employee_code,tp.availability,tp.current_workload,
               tp.max_active_jobs,tp.emergency_eligible,tp.rating,b.block_code,
               GROUP_CONCAT(DISTINCT s.skill_name ORDER BY ts.is_primary DESC,s.skill_name SEPARATOR ', ') AS skills
        FROM technician_profiles tp INNER JOIN users u ON u.user_id=tp.user_id
        LEFT JOIN buildings b ON b.building_id=tp.assigned_building_id
        LEFT JOIN technician_skills ts ON ts.technician_id=tp.technician_id AND ts.verified=TRUE
        LEFT JOIN skills s ON s.skill_id=ts.skill_id
        WHERE tp.user_id=%s
        GROUP BY tp.technician_id,u.full_name,u.email,u.phone,tp.employee_code,tp.availability,tp.current_workload,
                 tp.max_active_jobs,tp.emergency_eligible,tp.rating,b.block_code
        LIMIT 1
        """,
        (user_id,),
    )
    if not row: return None
    return {
        'id': _int(row['technician_id']), 'name': row['full_name'], 'email': row['email'], 'phone': row['phone'] or '',
        'employeeCode': row['employee_code'], 'status': row['availability'], 'workload': _int(row['current_workload']),
        'maxJobs': _int(row['max_active_jobs']), 'emergency': bool(row['emergency_eligible']), 'rating': _float(row['rating']),
        'block': row['block_code'] or 'Any block', 'skill': row['skills'] or 'No verified skill',
    }


def technician_jobs(user_id, status='', emergency_only=False):
    clauses = [' AND tu.user_id=%s ']
    params = [user_id]
    if status:
        clauses.append(' AND mt.current_status=%s '); params.append(status)
    rows = query_all(_ticket_base_sql(''.join(clauses)) + ' ORDER BY mt.submitted_at DESC', tuple(params))
    tickets = [redact_ticket_for_role(serialize_ticket(r), 'technician') for r in rows]
    if emergency_only:
        tickets = [t for t in tickets if t['emergency'] and t['status'] not in CLOSED_TICKET_STATUSES]
    return tickets


def technician_dashboard(user_id):
    profile = technician_profile_for_user(user_id)
    tickets = technician_jobs(user_id)
    return {
        'profile': profile,
        'stats': {
            'assigned': sum(1 for t in tickets if t['status'] not in ('Resolved','Closed','Cancelled')),
            'emergency': sum(1 for t in tickets if t['emergency'] and t['status'] not in ('Resolved','Closed','Cancelled')),
            'in_progress': sum(1 for t in tickets if t['status']=='In Progress'),
            'completed': sum(1 for t in tickets if t['status'] in ('Resolved','Closed')),
        },
        'jobs': tickets[:4],
    }


def _technician_assignment_for_update(connection, user_id, ticket_number):
    with connection.cursor() as cursor:
        cursor.execute(
            """
            SELECT mt.ticket_id,mt.current_status,mt.resident_id,ta.assignment_id,ta.assignment_status,tp.technician_id
            FROM maintenance_tickets mt
            INNER JOIN ticket_assignments ta ON ta.ticket_id=mt.ticket_id AND ta.is_current=TRUE
            INNER JOIN technician_profiles tp ON tp.technician_id=ta.technician_id
            WHERE mt.ticket_number=%s AND tp.user_id=%s FOR UPDATE
            """,
            (ticket_number, user_id),
        )
        return cursor.fetchone()


def update_job_status(user_id, ticket_number, new_status, note=''):
    allowed = {
        'Assigned': {'Accepted'},
        'Auto Assigned': {'Accepted'},
        'Accepted': {'In Progress'},
        'In Progress': {'On Hold'},
        'On Hold': {'In Progress'},
    }
    connection = get_connection()
    try:
        assignment = _technician_assignment_for_update(connection, user_id, ticket_number)
        if not assignment:
            connection.rollback(); return None, 'Assigned job not found.', 404
        current = assignment['current_status']
        if new_status not in allowed.get(current, set()):
            connection.rollback(); return None, f'Cannot change job from {current} to {new_status}.', 409
        if new_status == 'On Hold' and not (note or '').strip():
            connection.rollback(); return None, 'Add a short reason before placing a job on hold.', 400
        assignment_status = new_status
        with connection.cursor() as cursor:
            time_sql = ''
            if new_status == 'Accepted': time_sql = ', accepted_at=COALESCE(accepted_at,NOW())'
            if new_status == 'In Progress': time_sql = ', started_at=COALESCE(started_at,NOW())'
            cursor.execute(f"UPDATE ticket_assignments SET assignment_status=%s {time_sql} WHERE assignment_id=%s", (assignment_status, assignment['assignment_id']))
            cursor.execute("UPDATE maintenance_tickets SET current_status=%s WHERE ticket_id=%s", (new_status, assignment['ticket_id']))
            cursor.execute(
                "INSERT INTO ticket_updates(ticket_id,updated_by,update_type,status_from,status_to,note,resident_visible) VALUES(%s,%s,'Status Update',%s,%s,%s,TRUE)",
                (assignment['ticket_id'], user_id, current, new_status, (note or f'Job status changed to {new_status}.')[:2000]),
            )
            cursor.execute("SELECT user_id FROM resident_profiles WHERE resident_id=%s", (assignment['resident_id'],))
            resident_user = cursor.fetchone()['user_id']
            cursor.execute(
                "INSERT INTO notifications(user_id,ticket_id,event_type,channel,title,message,delivery_status) VALUES(%s,%s,'Status Changed','In App','Ticket status updated',%s,'Delivered')",
                (resident_user, assignment['ticket_id'], f'{ticket_number} status changed to {new_status}.'),
            )
        connection.commit()
    except Exception:
        connection.rollback(); raise
    finally:
        connection.close()
    return get_ticket(ticket_number, user_id=user_id, role='technician'), None, 200


def add_repair_note(user_id, ticket_number, note):
    note = (note or '').strip()
    if len(note) < 3:
        return None, 'Enter a short repair note.', 400
    connection = get_connection()
    try:
        assignment = _technician_assignment_for_update(connection, user_id, ticket_number)
        if not assignment:
            connection.rollback(); return None, 'Assigned job not found.', 404
        if assignment['current_status'] not in ('Accepted', 'In Progress', 'On Hold'):
            connection.rollback(); return None, 'Accept the job before adding repair notes.', 409
        with connection.cursor() as cursor:
            cursor.execute(
                "INSERT INTO ticket_updates(ticket_id,updated_by,update_type,status_from,status_to,note,resident_visible) VALUES(%s,%s,'Repair Note',%s,%s,%s,TRUE)",
                (assignment['ticket_id'], user_id, assignment['current_status'], assignment['current_status'], note[:5000]),
            )
        connection.commit()
    except Exception:
        connection.rollback(); raise
    finally:
        connection.close()
    return get_ticket(ticket_number, user_id=user_id, role='technician'), None, 200


def complete_job(user_id, ticket_number, summary, upload_file=None, upload_root=None):
    upload_error = _validate_upload(upload_file)
    if upload_error:
        return None, upload_error, 400
    summary = (summary or '').strip()
    if len(summary) < 5:
        return None, 'Enter a completion summary.', 400
    connection = get_connection()
    update_id = None
    ticket_id = None
    try:
        assignment = _technician_assignment_for_update(connection, user_id, ticket_number)
        if not assignment:
            connection.rollback(); return None, 'Assigned job not found.', 404
        if assignment['current_status'] != 'In Progress':
            connection.rollback(); return None, 'Start the job and keep it In Progress before marking it resolved.', 409
        ticket_id = assignment['ticket_id']
        with connection.cursor() as cursor:
            cursor.execute("UPDATE ticket_assignments SET assignment_status='Completed',completed_at=NOW() WHERE assignment_id=%s", (assignment['assignment_id'],))
            cursor.execute("UPDATE maintenance_tickets SET current_status='Resolved',resolved_at=NOW() WHERE ticket_id=%s", (ticket_id,))
            cursor.execute(
                "INSERT INTO ticket_updates(ticket_id,updated_by,update_type,status_from,status_to,note,resident_visible) VALUES(%s,%s,'Completion Note',%s,'Resolved',%s,TRUE)",
                (ticket_id, user_id, assignment['current_status'], summary[:5000]),
            )
            update_id = cursor.lastrowid
            cursor.execute("SELECT user_id FROM resident_profiles WHERE resident_id=%s", (assignment['resident_id'],))
            resident_user = cursor.fetchone()['user_id']
            cursor.execute(
                "INSERT INTO notifications(user_id,ticket_id,event_type,channel,title,message,delivery_status) VALUES(%s,%s,'Ticket Completed','In App','Maintenance work resolved',%s,'Delivered')",
                (resident_user, ticket_id, f'{ticket_number} was marked resolved by the assigned technician.'),
            )
            cursor.execute(
                "INSERT INTO audit_logs(user_id,action_type,entity_type,entity_id,new_value,reason) VALUES(%s,'Job Resolved','maintenance_tickets',%s,%s,%s)",
                (user_id, str(ticket_id), json.dumps({'status':'Resolved'}), summary[:1000]),
            )
        connection.commit()
    except Exception:
        connection.rollback(); raise
    finally:
        connection.close()
    if upload_file and upload_file.filename:
        try:
            save_ticket_attachment(ticket_id, user_id, upload_file, 'Completion Proof', upload_root, update_id=update_id)
        except ValueError as exc:
            return get_ticket(ticket_number, user_id=user_id, role='technician'), str(exc), 400
    return get_ticket(ticket_number, user_id=user_id, role='technician'), None, 200


def update_own_technician_profile(user_id, full_name, phone, availability):
    if availability not in {'Available','Busy','Off Duty','On Leave'}:
        return None, 'Select a valid availability status.', 400
    full_name = clean_text(full_name,150)
    phone = normalize_mobile(phone)
    if not validate_name(full_name):
        return None, 'Enter a valid full name.', 400
    if not validate_mobile(phone,required=True):
        return None, 'Enter a valid Sri Lankan mobile number such as 0771234567 or +94771234567.', 400
    connection = get_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute("UPDATE users SET full_name=%s,phone=%s,updated_at=NOW() WHERE user_id=%s", (full_name, phone, user_id))
            cursor.execute("UPDATE technician_profiles SET availability=%s,last_availability_change_at=NOW() WHERE user_id=%s", (availability, user_id))
            cursor.execute(
                "INSERT INTO audit_logs(user_id,action_type,entity_type,entity_id,reason) VALUES(%s,'PROFILE_UPDATED','User',%s,'Technician updated own profile')",
                (user_id, str(user_id)),
            )
        connection.commit()
    except Exception:
        connection.rollback(); raise
    finally:
        connection.close()
    return technician_profile_for_user(user_id), None, 200
