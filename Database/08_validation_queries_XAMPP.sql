USE `helafixit_ai`;

SELECT DATABASE() AS selected_database;

-- Core reference and transaction counts
SELECT COUNT(*) AS role_count FROM roles;
SELECT COUNT(*) AS category_count FROM issue_categories WHERE active=TRUE;
SELECT COUNT(*) AS skill_count FROM skills WHERE active=TRUE;
SELECT COUNT(*) AS pending_registration_requests FROM resident_registration_requests WHERE request_status='Pending';
SELECT COUNT(*) AS active_users FROM users WHERE account_status='Active';
SELECT COUNT(*) AS tickets FROM maintenance_tickets;
SELECT COUNT(*) AS predictions FROM ai_predictions;
SELECT COUNT(*) AS assignments FROM ticket_assignments;
SELECT COUNT(*) AS temporary_password_records FROM temporary_passwords;

-- These queries should return zero rows in a healthy database
SELECT * FROM maintenance_tickets
WHERE current_risk_score IS NOT NULL
  AND (current_risk_score < 0 OR current_risk_score > 100);

SELECT * FROM ai_predictions
WHERE risk_score IS NOT NULL
  AND (risk_score < 0 OR risk_score > 100);

SELECT ticket_id, COUNT(*) AS current_assignment_count
FROM ticket_assignments
WHERE is_current=TRUE
GROUP BY ticket_id
HAVING COUNT(*) > 1;

-- User-management columns and soft-delete check. This query also verifies that
-- the required revision columns exist without reading information_schema.
SELECT user_id,must_change_password,auth_version,is_deleted,deleted_at
FROM users
ORDER BY user_id
LIMIT 1;

SELECT 'deleted_user_count' AS check_name, COUNT(*) AS result_value
FROM users
WHERE is_deleted=TRUE;
