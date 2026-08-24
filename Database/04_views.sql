-- HelaFixIt AI reporting and operational views
USE helafixit_ai;

CREATE OR REPLACE VIEW vw_technician_workload AS
SELECT
    tp.technician_id,
    tp.employee_code,
    u.full_name AS technician_name,
    u.phone,
    tp.availability,
    tp.current_workload,
    tp.max_active_jobs,
    tp.emergency_eligible,
    tp.can_work_after_hours,
    tp.rating,
    b.block_code AS assigned_block,
    skill_list.skills,
    COALESCE(job_count.calculated_active_jobs, 0) AS calculated_active_jobs
FROM technician_profiles tp
JOIN users u ON u.user_id = tp.user_id
LEFT JOIN buildings b ON b.building_id = tp.assigned_building_id
LEFT JOIN (
    SELECT
        ts.technician_id,
        GROUP_CONCAT(s.skill_name ORDER BY ts.is_primary DESC, s.skill_name SEPARATOR ', ') AS skills
    FROM technician_skills ts
    JOIN skills s ON s.skill_id = ts.skill_id
    GROUP BY ts.technician_id
) skill_list ON skill_list.technician_id = tp.technician_id
LEFT JOIN (
    SELECT
        technician_id,
        COUNT(*) AS calculated_active_jobs
    FROM ticket_assignments
    WHERE is_current = TRUE
      AND assignment_status IN ('Assigned','Accepted','In Progress','On Hold')
    GROUP BY technician_id
) job_count ON job_count.technician_id = tp.technician_id;

CREATE OR REPLACE VIEW vw_ticket_details AS
SELECT
    t.ticket_id,
    t.ticket_number,
    t.subject,
    t.description,
    t.language_type,
    t.asset_type,
    t.current_priority,
    t.current_risk_score,
    t.current_risk_level,
    t.current_status,
    t.safety_flag,
    t.duplicate_flag,
    t.manual_review_required,
    t.submitted_at,
    t.updated_at,
    ru.full_name AS resident_name,
    ru.email AS resident_email,
    b.block_code,
    f.name AS floor_name,
    COALESCE(un.unit_number, t.unit_number_snapshot) AS unit_number,
    a.name AS area_name,
    ic.name AS current_category,
    ta.assignment_id AS current_assignment_id,
    ta.assignment_method,
    ta.assignment_status,
    ta.assigned_at,
    tp.technician_id,
    tu.full_name AS technician_name,
    tp.availability AS technician_availability
FROM maintenance_tickets t
JOIN resident_profiles rp ON rp.resident_id = t.resident_id
JOIN users ru ON ru.user_id = rp.user_id
JOIN buildings b ON b.building_id = t.building_id
JOIN floors f ON f.floor_id = t.floor_id
LEFT JOIN units un ON un.unit_id = t.unit_id
LEFT JOIN areas a ON a.area_id = t.area_id
LEFT JOIN issue_categories ic ON ic.category_id = t.current_category_id
LEFT JOIN ticket_assignments ta ON ta.ticket_id = t.ticket_id AND ta.is_current = TRUE
LEFT JOIN technician_profiles tp ON tp.technician_id = ta.technician_id
LEFT JOIN users tu ON tu.user_id = tp.user_id;

CREATE OR REPLACE VIEW vw_ai_review_queue AS
SELECT
    p.prediction_id,
    p.ticket_id,
    t.ticket_number,
    t.subject,
    t.description,
    p.predicted_priority,
    p.priority_confidence,
    p.risk_score,
    p.risk_level,
    p.safety_flag,
    p.safety_warning,
    p.duplicate_flag,
    p.duplicate_similarity,
    p.manual_review_required,
    p.review_status,
    p.processed_at,
    c.name AS predicted_category,
    s.skill_name AS recommended_skill,
    tech_user.full_name AS recommended_technician
FROM ai_predictions p
JOIN maintenance_tickets t ON t.ticket_id = p.ticket_id
LEFT JOIN issue_categories c ON c.category_id = p.predicted_category_id
LEFT JOIN skills s ON s.skill_id = p.recommended_skill_id
LEFT JOIN technician_profiles tp ON tp.technician_id = p.recommended_technician_id
LEFT JOIN users tech_user ON tech_user.user_id = tp.user_id
WHERE p.is_current = TRUE
  AND (p.manual_review_required = TRUE OR p.review_status = 'Pending');

CREATE OR REPLACE VIEW vw_emergency_queue AS
SELECT
    t.ticket_id,
    t.ticket_number,
    t.subject,
    t.current_priority,
    t.current_risk_score,
    t.current_risk_level,
    t.current_status,
    t.submitted_at,
    b.block_code,
    f.name AS floor_name,
    a.name AS area_name,
    ta.assignment_id,
    ta.assignment_method,
    ta.assignment_status,
    tu.full_name AS technician_name
FROM maintenance_tickets t
JOIN buildings b ON b.building_id = t.building_id
JOIN floors f ON f.floor_id = t.floor_id
LEFT JOIN areas a ON a.area_id = t.area_id
LEFT JOIN ticket_assignments ta ON ta.ticket_id = t.ticket_id AND ta.is_current = TRUE
LEFT JOIN technician_profiles tp ON tp.technician_id = ta.technician_id
LEFT JOIN users tu ON tu.user_id = tp.user_id
WHERE t.current_priority = 'Emergency'
   OR t.current_risk_level = 'Critical'
   OR t.current_status IN ('Urgent Unassigned','Auto Assigned');

CREATE OR REPLACE VIEW vw_admin_dashboard_metrics AS
SELECT
    SUM(CASE WHEN current_status NOT IN ('Closed','Cancelled') THEN 1 ELSE 0 END) AS open_tickets,
    SUM(CASE WHEN current_priority = 'Emergency' AND current_status NOT IN ('Closed','Cancelled') THEN 1 ELSE 0 END) AS emergency_tickets,
    SUM(CASE WHEN current_risk_level IN ('High','Critical') AND current_status NOT IN ('Closed','Cancelled') THEN 1 ELSE 0 END) AS high_risk_tickets,
    SUM(CASE WHEN current_status = 'Urgent Unassigned' THEN 1 ELSE 0 END) AS urgent_unassigned,
    SUM(CASE WHEN duplicate_flag = TRUE AND current_status NOT IN ('Closed','Cancelled') THEN 1 ELSE 0 END) AS duplicate_tickets,
    SUM(CASE WHEN current_status IN ('Resolved','Closed') THEN 1 ELSE 0 END) AS resolved_or_closed,
    ROUND(AVG(CASE WHEN resolved_at IS NOT NULL THEN TIMESTAMPDIFF(MINUTE, submitted_at, resolved_at) END), 1) AS average_resolution_minutes
FROM maintenance_tickets;

CREATE OR REPLACE VIEW vw_category_report AS
SELECT
    COALESCE(ic.name, 'Unclassified') AS category_name,
    COUNT(*) AS ticket_count,
    SUM(CASE WHEN t.current_priority = 'Emergency' THEN 1 ELSE 0 END) AS emergency_count,
    ROUND(AVG(t.current_risk_score), 2) AS average_risk_score
FROM maintenance_tickets t
LEFT JOIN issue_categories ic ON ic.category_id = t.current_category_id
GROUP BY COALESCE(ic.name, 'Unclassified');

CREATE OR REPLACE VIEW vw_priority_report AS
SELECT
    COALESCE(current_priority, 'Unclassified') AS priority_name,
    COUNT(*) AS ticket_count,
    ROUND(AVG(current_risk_score), 2) AS average_risk_score
FROM maintenance_tickets
GROUP BY COALESCE(current_priority, 'Unclassified');

CREATE OR REPLACE VIEW vw_duplicate_review AS
SELECT
    dm.duplicate_match_id,
    source_t.ticket_number AS source_ticket_number,
    source_t.subject AS source_subject,
    matched_t.ticket_number AS matched_ticket_number,
    matched_t.subject AS matched_subject,
    dm.similarity_score,
    dm.location_match_score,
    dm.match_status,
    dm.created_at,
    dm.reviewed_at,
    reviewer.full_name AS reviewed_by_name
FROM duplicate_matches dm
JOIN maintenance_tickets source_t ON source_t.ticket_id = dm.source_ticket_id
JOIN maintenance_tickets matched_t ON matched_t.ticket_id = dm.matched_ticket_id
LEFT JOIN users reviewer ON reviewer.user_id = dm.reviewed_by;

CREATE OR REPLACE VIEW vw_resident_ticket_summary AS
SELECT
    rp.resident_id,
    u.full_name AS resident_name,
    COUNT(t.ticket_id) AS total_tickets,
    SUM(CASE WHEN t.current_status NOT IN ('Closed','Cancelled') THEN 1 ELSE 0 END) AS active_tickets,
    SUM(CASE WHEN t.current_priority = 'Emergency' AND t.current_status NOT IN ('Closed','Cancelled') THEN 1 ELSE 0 END) AS emergency_tickets,
    SUM(CASE WHEN t.current_status = 'Closed' THEN 1 ELSE 0 END) AS closed_tickets
FROM resident_profiles rp
JOIN users u ON u.user_id = rp.user_id
LEFT JOIN maintenance_tickets t ON t.resident_id = rp.resident_id
GROUP BY rp.resident_id, u.full_name;
