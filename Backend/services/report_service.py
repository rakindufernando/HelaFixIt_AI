from __future__ import annotations

from database import query_all, query_one


def _int(value):
    return int(value or 0)


def _float(value):
    return float(value or 0)


def admin_report_data(building_id):
    """Return live maintenance reporting data for one Apartment Admin building."""
    try:
        building_id = int(building_id)
    except (TypeError, ValueError):
        return {
            'scope': None,
            'summary': {
                'total': 0, 'open': 0, 'emergency': 0, 'completed': 0,
                'avgCompletionMinutes': 0, 'avgResponseMinutes': 0,
                'duplicates': 0, 'autoAssignments': 0,
            },
            'priority': [], 'categories': [], 'statuses': [], 'buildings': [], 'floors': [],
            'monthly': [], 'technicians': [],
            'ai': {
                'predictions': 0, 'avgCategoryConfidence': 0, 'avgPriorityConfidence': 0,
                'manualReviews': 0, 'safetyPredictions': 0, 'corrections': 0,
            },
        }

    scope = query_one(
        "SELECT building_id,block_code,name FROM buildings WHERE building_id=%s LIMIT 1",
        (building_id,),
    ) or {}

    summary = query_one(
        """
        SELECT
          COUNT(*) AS total,
          SUM(mt.current_status NOT IN ('Resolved','Closed','Cancelled')) AS open_count,
          SUM(mt.current_priority='Emergency' OR mt.current_risk_level='Critical') AS emergency_count,
          SUM(mt.current_status IN ('Resolved','Closed')) AS completed_count,
          ROUND(AVG(CASE WHEN mt.resolved_at IS NOT NULL
                    THEN TIMESTAMPDIFF(MINUTE,mt.submitted_at,mt.resolved_at) END),1) AS avg_completion_minutes
        FROM maintenance_tickets mt
        WHERE mt.building_id=%s
        """,
        (building_id,),
    ) or {}

    response = query_one(
        """
        SELECT ROUND(AVG(TIMESTAMPDIFF(MINUTE,ta.assigned_at,ta.accepted_at)),1) AS avg_response_minutes
        FROM ticket_assignments ta
        INNER JOIN maintenance_tickets mt ON mt.ticket_id=ta.ticket_id
        WHERE mt.building_id=%s AND ta.accepted_at IS NOT NULL
        """,
        (building_id,),
    ) or {}

    duplicate_row = query_one(
        """
        SELECT COUNT(*) AS c
        FROM duplicate_matches dm
        INNER JOIN maintenance_tickets src ON src.ticket_id=dm.source_ticket_id
        WHERE src.building_id=%s AND dm.match_status IN ('Pending','Confirmed','Linked')
        """,
        (building_id,),
    ) or {}

    auto_row = query_one(
        """
        SELECT COUNT(*) AS c
        FROM ticket_assignments ta
        INNER JOIN maintenance_tickets mt ON mt.ticket_id=ta.ticket_id
        WHERE mt.building_id=%s AND ta.assignment_method='Auto Emergency'
        """,
        (building_id,),
    ) or {}

    priorities = query_all(
        """
        SELECT COALESCE(mt.current_priority,'Pending') AS label,COUNT(*) AS value
        FROM maintenance_tickets mt
        WHERE mt.building_id=%s
        GROUP BY COALESCE(mt.current_priority,'Pending')
        ORDER BY value DESC,label
        """,
        (building_id,),
    )

    categories = query_all(
        """
        SELECT COALESCE(c.name,'Pending') AS label,COUNT(*) AS value
        FROM maintenance_tickets mt
        LEFT JOIN issue_categories c ON c.category_id=mt.current_category_id
        WHERE mt.building_id=%s
        GROUP BY COALESCE(c.name,'Pending')
        ORDER BY value DESC,label
        """,
        (building_id,),
    )

    statuses = query_all(
        """
        SELECT mt.current_status AS label,COUNT(*) AS value
        FROM maintenance_tickets mt
        WHERE mt.building_id=%s
        GROUP BY mt.current_status
        ORDER BY value DESC,label
        """,
        (building_id,),
    )

    buildings = query_all(
        """
        SELECT CONCAT(b.block_code,' - ',b.name) AS label,COUNT(mt.ticket_id) AS value
        FROM buildings b
        LEFT JOIN maintenance_tickets mt ON mt.building_id=b.building_id
        WHERE b.building_id=%s
        GROUP BY b.building_id,b.block_code,b.name
        """,
        (building_id,),
    )

    floors = query_all(
        """
        SELECT f.name AS label,COUNT(mt.ticket_id) AS value
        FROM floors f
        LEFT JOIN maintenance_tickets mt ON mt.floor_id=f.floor_id AND mt.building_id=%s
        WHERE f.building_id=%s AND f.status='Active'
        GROUP BY f.floor_id,f.floor_number,f.name
        HAVING COUNT(mt.ticket_id)>0
        ORDER BY value DESC,f.floor_number
        LIMIT 10
        """,
        (building_id, building_id),
    )

    # Percent signs are escaped because PyMySQL uses Python-style percent placeholders.
    monthly = query_all(
        """
        SELECT DATE_FORMAT(mt.submitted_at,'%%Y-%%m') AS month,
               COUNT(*) AS submitted,
               SUM(mt.current_status IN ('Resolved','Closed')) AS completed,
               SUM(mt.current_priority='Emergency' OR mt.current_risk_level='Critical') AS emergency
        FROM maintenance_tickets mt
        WHERE mt.building_id=%s
          AND mt.submitted_at >= DATE_SUB(CURDATE(),INTERVAL 6 MONTH)
        GROUP BY DATE_FORMAT(mt.submitted_at,'%%Y-%%m')
        ORDER BY month
        """,
        (building_id,),
    )

    technicians = query_all(
        """
        SELECT tp.technician_id,u.full_name,tp.availability,tp.current_workload,tp.max_active_jobs,tp.rating,
               COUNT(DISTINCT CASE WHEN ta.assignment_status='Completed' AND mt.building_id=%s
                              THEN ta.assignment_id END) AS completed_jobs,
               ROUND(AVG(CASE WHEN mt.building_id=%s AND ta.accepted_at IS NOT NULL
                         THEN TIMESTAMPDIFF(MINUTE,ta.assigned_at,ta.accepted_at) END),1) AS avg_response_minutes
        FROM technician_profiles tp
        INNER JOIN users u ON u.user_id=tp.user_id
        LEFT JOIN ticket_assignments ta ON ta.technician_id=tp.technician_id
        LEFT JOIN maintenance_tickets mt ON mt.ticket_id=ta.ticket_id
        WHERE tp.active=TRUE AND tp.assigned_building_id=%s AND u.account_status='Active'
        GROUP BY tp.technician_id,u.full_name,tp.availability,tp.current_workload,tp.max_active_jobs,tp.rating
        ORDER BY tp.current_workload DESC,u.full_name
        """,
        (building_id, building_id, building_id),
    )

    ai = query_one(
        """
        SELECT COUNT(ap.prediction_id) AS predictions,
               ROUND(AVG(ap.category_confidence)*100,1) AS avg_category_confidence,
               ROUND(AVG(ap.priority_confidence)*100,1) AS avg_priority_confidence,
               SUM(ap.manual_review_required=TRUE) AS manual_reviews,
               SUM(ap.safety_flag=TRUE) AS safety_predictions
        FROM ai_predictions ap
        INNER JOIN maintenance_tickets mt ON mt.ticket_id=ap.ticket_id
        WHERE mt.building_id=%s AND ap.is_current=TRUE
        """,
        (building_id,),
    ) or {}

    corrections = query_one(
        """
        SELECT COUNT(ac.correction_id) AS c
        FROM ai_corrections ac
        INNER JOIN ai_predictions ap ON ap.prediction_id=ac.prediction_id
        INNER JOIN maintenance_tickets mt ON mt.ticket_id=ap.ticket_id
        WHERE mt.building_id=%s
        """,
        (building_id,),
    ) or {}

    return {
        'scope': {
            'buildingId': _int(scope.get('building_id')),
            'block': scope.get('block_code') or '',
            'building': scope.get('name') or '',
        },
        'summary': {
            'total': _int(summary.get('total')),
            'open': _int(summary.get('open_count')),
            'emergency': _int(summary.get('emergency_count')),
            'completed': _int(summary.get('completed_count')),
            'avgCompletionMinutes': _float(summary.get('avg_completion_minutes')),
            'avgResponseMinutes': _float(response.get('avg_response_minutes')),
            'duplicates': _int(duplicate_row.get('c')),
            'autoAssignments': _int(auto_row.get('c')),
        },
        'priority': [{'label': r['label'], 'value': _int(r['value'])} for r in priorities],
        'categories': [{'label': r['label'], 'value': _int(r['value'])} for r in categories],
        'statuses': [{'label': r['label'], 'value': _int(r['value'])} for r in statuses],
        'buildings': [{'label': r['label'], 'value': _int(r['value'])} for r in buildings],
        'floors': [{'label': r['label'], 'value': _int(r['value'])} for r in floors],
        'monthly': [{
            'month': r['month'], 'submitted': _int(r['submitted']),
            'completed': _int(r['completed']), 'emergency': _int(r['emergency']),
        } for r in monthly],
        'technicians': [{
            'id': _int(r['technician_id']), 'name': r['full_name'], 'availability': r['availability'],
            'workload': _int(r['current_workload']), 'maxJobs': _int(r['max_active_jobs']),
            'completed': _int(r['completed_jobs']), 'avgResponseMinutes': _float(r['avg_response_minutes']),
            'rating': float(r['rating']) if r.get('rating') is not None else None,
        } for r in technicians],
        'ai': {
            'predictions': _int(ai.get('predictions')),
            'avgCategoryConfidence': _float(ai.get('avg_category_confidence')),
            'avgPriorityConfidence': _float(ai.get('avg_priority_confidence')),
            'manualReviews': _int(ai.get('manual_reviews')),
            'safetyPredictions': _int(ai.get('safety_predictions')),
            'corrections': _int(corrections.get('c')),
        },
    }
