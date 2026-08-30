from __future__ import annotations

from database import get_connection
from utils.validators import clean_text


def _notify_admins(cursor, ticket_id, building_id, event_type, title, message):
    cursor.execute(
        """
        SELECT DISTINCT u.user_id
        FROM users u
        INNER JOIN roles r ON r.role_id=u.role_id
        INNER JOIN apartment_admin_profiles ap ON ap.user_id=u.user_id
        WHERE r.role_code='apartment_admin'
          AND u.account_status='Active' AND u.is_deleted=FALSE
          AND ap.active=TRUE AND ap.primary_building_id=%s
        """,
        (building_id,),
    )
    for row in cursor.fetchall():
        cursor.execute(
            """
            INSERT INTO notifications(user_id,ticket_id,event_type,channel,title,message,delivery_status)
            VALUES(%s,%s,%s,'In App',%s,%s,'Delivered')
            """,
            (row['user_id'], ticket_id, event_type, title[:180], message[:1000]),
        )


def _audit(cursor, user_id, action, ticket_id, reason):
    cursor.execute(
        """
        INSERT INTO audit_logs(user_id,action_type,entity_type,entity_id,reason)
        VALUES(%s,%s,'maintenance_tickets',%s,%s)
        """,
        (user_id, action, str(ticket_id), reason[:1000]),
    )


def resident_cancel_ticket(user_id, ticket_number, reason):
    note = clean_text(reason, 1000)
    if len(note) < 5:
        return None, 'Enter a short reason for cancelling the ticket.', 400
    connection = get_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                SELECT mt.ticket_id,mt.ticket_number,mt.current_status,mt.building_id
                FROM maintenance_tickets mt
                INNER JOIN resident_profiles rp ON rp.resident_id=mt.resident_id
                WHERE mt.ticket_number=%s AND rp.user_id=%s
                FOR UPDATE
                """,
                (ticket_number, user_id),
            )
            ticket = cursor.fetchone()
            if not ticket:
                return None, 'Ticket not found.', 404
            allowed = {'Submitted', 'Analysing', 'Awaiting Review', 'Urgent Unassigned'}
            if ticket['current_status'] not in allowed:
                return None, 'This ticket can no longer be cancelled by the resident because maintenance assignment or work has already progressed.', 409
            old_status = ticket['current_status']
            cursor.execute(
                "UPDATE maintenance_tickets SET current_status='Cancelled',cancelled_at=NOW() WHERE ticket_id=%s",
                (ticket['ticket_id'],),
            )
            cursor.execute(
                """
                INSERT INTO ticket_updates(ticket_id,updated_by,update_type,status_from,status_to,note,resident_visible)
                VALUES(%s,%s,'Cancellation Note',%s,'Cancelled',%s,TRUE)
                """,
                (ticket['ticket_id'], user_id, old_status, note),
            )
            _notify_admins(cursor, ticket['ticket_id'], ticket['building_id'], 'Ticket Cancelled', 'Resident cancelled a maintenance ticket', f"{ticket_number} was cancelled by the resident. Reason  {note}")
            _audit(cursor, user_id, 'TICKET_CANCELLED', ticket['ticket_id'], 'Resident cancelled own maintenance ticket.')
        connection.commit()
        return {'ticket_number': ticket_number, 'status': 'Cancelled'}, None, 200
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()


def resident_close_ticket(user_id, ticket_number, note=''):
    close_note = clean_text(note, 1000) or 'Resident confirmed that the maintenance issue has been resolved.'
    connection = get_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                SELECT mt.ticket_id,mt.ticket_number,mt.current_status,mt.building_id
                FROM maintenance_tickets mt
                INNER JOIN resident_profiles rp ON rp.resident_id=mt.resident_id
                WHERE mt.ticket_number=%s AND rp.user_id=%s
                FOR UPDATE
                """,
                (ticket_number, user_id),
            )
            ticket = cursor.fetchone()
            if not ticket:
                return None, 'Ticket not found.', 404
            if ticket['current_status'] != 'Resolved':
                return None, 'Only a resolved ticket can be closed.', 409
            cursor.execute("UPDATE maintenance_tickets SET current_status='Closed',closed_at=NOW() WHERE ticket_id=%s", (ticket['ticket_id'],))
            cursor.execute(
                """
                INSERT INTO ticket_updates(ticket_id,updated_by,update_type,status_from,status_to,note,resident_visible)
                VALUES(%s,%s,'Status Update','Resolved','Closed',%s,TRUE)
                """,
                (ticket['ticket_id'], user_id, close_note),
            )
            _notify_admins(cursor, ticket['ticket_id'], ticket['building_id'], 'Ticket Closed', 'Resident confirmed resolution', f"{ticket_number} was closed by the resident after confirming the repair.")
            _audit(cursor, user_id, 'TICKET_CLOSED', ticket['ticket_id'], 'Resident confirmed resolution and closed own ticket.')
        connection.commit()
        return {'ticket_number': ticket_number, 'status': 'Closed'}, None, 200
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()


def resident_reopen_ticket(user_id, ticket_number, reason):
    note = clean_text(reason, 1000)
    if len(note) < 5:
        return None, 'Enter a short reason explaining why the issue is still unresolved.', 400
    connection = get_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                SELECT mt.ticket_id,mt.ticket_number,mt.current_status,mt.building_id
                FROM maintenance_tickets mt
                INNER JOIN resident_profiles rp ON rp.resident_id=mt.resident_id
                WHERE mt.ticket_number=%s AND rp.user_id=%s
                FOR UPDATE
                """,
                (ticket_number, user_id),
            )
            ticket = cursor.fetchone()
            if not ticket:
                return None, 'Ticket not found.', 404
            if ticket['current_status'] not in {'Resolved', 'Closed'}:
                return None, 'Only a resolved or closed ticket can be reopened.', 409
            old_status = ticket['current_status']
            cursor.execute(
                "UPDATE ticket_assignments SET is_current=FALSE WHERE ticket_id=%s AND is_current=TRUE",
                (ticket['ticket_id'],),
            )
            cursor.execute(
                "UPDATE maintenance_tickets SET current_status='Reopened',resolved_at=NULL,closed_at=NULL,cancelled_at=NULL WHERE ticket_id=%s",
                (ticket['ticket_id'],),
            )
            cursor.execute(
                """
                INSERT INTO ticket_updates(ticket_id,updated_by,update_type,status_from,status_to,note,resident_visible)
                VALUES(%s,%s,'Reopen Note',%s,'Reopened',%s,TRUE)
                """,
                (ticket['ticket_id'], user_id, old_status, note),
            )
            _notify_admins(cursor, ticket['ticket_id'], ticket['building_id'], 'Ticket Reopened', 'Resident reopened a maintenance ticket', f"{ticket_number} was reopened. Reason  {note}")
            _audit(cursor, user_id, 'TICKET_REOPENED', ticket['ticket_id'], 'Resident reopened own maintenance ticket.')
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()

    # Reopened tickets are analysed again so the latest issue wording, risk state and technician
    # recommendation can re-enter the normal admin workflow. A model failure does not undo the
    # resident's valid reopen action.
    try:
        from services.ai_service import analyse_ticket
        analysed, _ = analyse_ticket(ticket['ticket_id'], initiated_by=user_id)
        if analysed:
            return {'ticket_number': ticket_number, 'status': analysed.get('status', 'Reopened'), 'analysis': analysed}, None, 200
    except Exception:
        pass
    return {'ticket_number': ticket_number, 'status': 'Reopened'}, None, 200


def technician_decline_assignment(user_id, ticket_number, reason):
    note = clean_text(reason, 1000)
    if len(note) < 5:
        return None, 'Enter a short reason for declining the assignment.', 400
    connection = get_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                SELECT mt.ticket_id,mt.ticket_number,mt.current_status,mt.building_id,rp.user_id AS resident_user_id,
                       ta.assignment_id,ta.assignment_status
                FROM maintenance_tickets mt
                INNER JOIN resident_profiles rp ON rp.resident_id=mt.resident_id
                INNER JOIN ticket_assignments ta ON ta.ticket_id=mt.ticket_id AND ta.is_current=TRUE
                INNER JOIN technician_profiles tp ON tp.technician_id=ta.technician_id
                WHERE mt.ticket_number=%s AND tp.user_id=%s
                FOR UPDATE
                """,
                (ticket_number, user_id),
            )
            ticket = cursor.fetchone()
            if not ticket:
                return None, 'Current assignment not found.', 404
            if ticket['current_status'] not in {'Assigned', 'Auto Assigned'} or ticket['assignment_status'] != 'Assigned':
                return None, 'Only a newly assigned job can be declined.', 409
            old_status = ticket['current_status']
            new_status = 'Urgent Unassigned' if old_status == 'Auto Assigned' else 'Awaiting Review'
            cursor.execute(
                """
                UPDATE ticket_assignments
                SET assignment_status='Declined',declined_at=NOW(),decline_reason=%s,is_current=FALSE
                WHERE assignment_id=%s
                """,
                (note, ticket['assignment_id']),
            )
            cursor.execute("UPDATE maintenance_tickets SET current_status=%s WHERE ticket_id=%s", (new_status, ticket['ticket_id']))
            cursor.execute(
                """
                INSERT INTO ticket_updates(ticket_id,updated_by,update_type,status_from,status_to,note,resident_visible)
                VALUES(%s,%s,'Status Update',%s,%s,%s,TRUE)
                """,
                (ticket['ticket_id'], user_id, old_status, new_status, 'Technician could not accept the assignment. The apartment admin will assign another suitable technician.'),
            )
            cursor.execute(
                """
                INSERT INTO notifications(user_id,ticket_id,event_type,channel,title,message,delivery_status)
                VALUES(%s,%s,'Assignment Declined','In App','Technician reassignment required',%s,'Delivered')
                """,
                (ticket['resident_user_id'], ticket['ticket_id'], f"The technician assigned to {ticket_number} could not accept the job. The apartment admin has been notified."),
            )
            _notify_admins(cursor, ticket['ticket_id'], ticket['building_id'], 'Assignment Declined', 'Technician declined an assignment', f"{ticket_number} requires reassignment. Technician reason  {note}")
            _audit(cursor, user_id, 'ASSIGNMENT_DECLINED', ticket['ticket_id'], 'Technician declined current assignment and returned the ticket for reassignment.')
        connection.commit()
        return {'ticket_number': ticket_number, 'status': new_status}, None, 200
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()
