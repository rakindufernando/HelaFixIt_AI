-- HelaFixIt AI workflow procedures
USE helafixit_ai;

DELIMITER $$

DROP PROCEDURE IF EXISTS sp_change_ticket_status$$
CREATE PROCEDURE sp_change_ticket_status(
    IN p_ticket_id BIGINT UNSIGNED,
    IN p_updated_by BIGINT UNSIGNED,
    IN p_new_status VARCHAR(30),
    IN p_note TEXT
)
BEGIN
    DECLARE v_old_status VARCHAR(30);
    DECLARE v_allowed INT DEFAULT 0;
    DECLARE v_requires_note BOOLEAN DEFAULT FALSE;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT current_status INTO v_old_status
    FROM maintenance_tickets
    WHERE ticket_id = p_ticket_id
    FOR UPDATE;

    IF v_old_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Ticket not found';
    END IF;

    IF v_old_status <> p_new_status THEN
        SELECT COUNT(*), COALESCE(MAX(requires_note), FALSE)
        INTO v_allowed, v_requires_note
        FROM ticket_status_transitions
        WHERE from_status = v_old_status
          AND to_status = p_new_status
          AND active = TRUE;

        IF v_allowed = 0 THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Ticket status transition is not allowed';
        END IF;

        IF v_requires_note = TRUE AND (p_note IS NULL OR TRIM(p_note) = '') THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A note is required for this status change';
        END IF;

        UPDATE maintenance_tickets
        SET current_status = p_new_status,
            resolved_at = CASE WHEN p_new_status = 'Resolved' THEN CURRENT_TIMESTAMP ELSE resolved_at END,
            closed_at = CASE WHEN p_new_status = 'Closed' THEN CURRENT_TIMESTAMP ELSE closed_at END,
            cancelled_at = CASE WHEN p_new_status = 'Cancelled' THEN CURRENT_TIMESTAMP ELSE cancelled_at END
        WHERE ticket_id = p_ticket_id;

        INSERT INTO ticket_updates(ticket_id, updated_by, update_type, status_from, status_to, note, resident_visible)
        VALUES(p_ticket_id, p_updated_by, 'Status Update', v_old_status, p_new_status, p_note, TRUE);

        INSERT INTO audit_logs(user_id, action_type, entity_type, entity_id, old_value, new_value, reason)
        VALUES(
            p_updated_by,
            'Ticket Status Changed',
            'maintenance_tickets',
            CAST(p_ticket_id AS CHAR),
            JSON_OBJECT('status', v_old_status),
            JSON_OBJECT('status', p_new_status),
            p_note
        );
    END IF;

    COMMIT;
END$$

DROP PROCEDURE IF EXISTS sp_assign_ticket$$
CREATE PROCEDURE sp_assign_ticket(
    IN p_ticket_id BIGINT UNSIGNED,
    IN p_technician_id BIGINT UNSIGNED,
    IN p_prediction_id BIGINT UNSIGNED,
    IN p_assignment_method VARCHAR(30),
    IN p_assigned_by BIGINT UNSIGNED,
    IN p_assignment_score DECIMAL(5,2),
    IN p_reason VARCHAR(1000)
)
BEGIN
    DECLARE v_old_status VARCHAR(30);
    DECLARE v_new_status VARCHAR(30);
    DECLARE v_technician_user_id BIGINT UNSIGNED;
    DECLARE v_ticket_number VARCHAR(40);
    DECLARE v_assignment_id BIGINT UNSIGNED;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT current_status, ticket_number INTO v_old_status, v_ticket_number
    FROM maintenance_tickets
    WHERE ticket_id = p_ticket_id
    FOR UPDATE;

    IF v_old_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Ticket not found';
    END IF;

    SELECT user_id INTO v_technician_user_id
    FROM technician_profiles
    WHERE technician_id = p_technician_id
      AND active = TRUE
    FOR UPDATE;

    IF v_technician_user_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Technician not found or inactive';
    END IF;

    UPDATE ticket_assignments
    SET is_current = FALSE,
        assignment_status = CASE
            WHEN assignment_status IN ('Completed','Cancelled','Declined','Reassigned') THEN assignment_status
            ELSE 'Reassigned'
        END,
        updated_at = CURRENT_TIMESTAMP
    WHERE ticket_id = p_ticket_id
      AND is_current = TRUE;

    INSERT INTO ticket_assignments(
        ticket_id, technician_id, prediction_id, assignment_method, assigned_by,
        assignment_status, assignment_score, assignment_reason, admin_override,
        override_reason, is_current
    ) VALUES(
        p_ticket_id,
        p_technician_id,
        p_prediction_id,
        CASE
            WHEN p_assignment_method = 'Auto Emergency' THEN 'Auto Emergency'
            WHEN p_assignment_method = 'Reassignment' THEN 'Reassignment'
            ELSE 'Manual'
        END,
        p_assigned_by,
        'Assigned',
        p_assignment_score,
        p_reason,
        CASE WHEN p_assignment_method = 'Reassignment' THEN TRUE ELSE FALSE END,
        CASE WHEN p_assignment_method = 'Reassignment' THEN p_reason ELSE NULL END,
        TRUE
    );

    SET v_assignment_id = LAST_INSERT_ID();
    SET v_new_status = CASE WHEN p_assignment_method = 'Auto Emergency' THEN 'Auto Assigned' ELSE 'Assigned' END;

    UPDATE maintenance_tickets
    SET current_status = v_new_status
    WHERE ticket_id = p_ticket_id;

    INSERT INTO ticket_updates(ticket_id, updated_by, update_type, status_from, status_to, note, resident_visible)
    VALUES(
        p_ticket_id,
        p_assigned_by,
        'System Event',
        v_old_status,
        v_new_status,
        CONCAT('Technician assigned using ', p_assignment_method, '. ', COALESCE(p_reason, '')),
        TRUE
    );

    INSERT INTO notifications(user_id, ticket_id, event_type, channel, title, message, delivery_status)
    VALUES(
        v_technician_user_id,
        p_ticket_id,
        CASE WHEN p_assignment_method = 'Auto Emergency' THEN 'Emergency Assignment' ELSE 'Ticket Assignment' END,
        'In App',
        CASE WHEN p_assignment_method = 'Auto Emergency' THEN 'New emergency job' ELSE 'New assigned job' END,
        CONCAT(v_ticket_number, ' has been assigned to you.'),
        'Delivered'
    );

    IF p_assignment_method = 'Auto Emergency' THEN
        INSERT INTO notifications(user_id, ticket_id, event_type, channel, title, message, delivery_status)
        SELECT
            u.user_id,
            p_ticket_id,
            'Emergency Auto Assignment',
            'In App',
            'Emergency ticket automatically assigned',
            CONCAT(v_ticket_number, ' was automatically assigned and requires admin review.'),
            'Delivered'
        FROM users u
        JOIN roles r ON r.role_id = u.role_id
        WHERE r.role_code = 'apartment_admin'
          AND u.account_status = 'Active';
    END IF;

    INSERT INTO audit_logs(user_id, action_type, entity_type, entity_id, new_value, reason)
    VALUES(
        p_assigned_by,
        CASE WHEN p_assignment_method = 'Auto Emergency' THEN 'Emergency Auto Assignment' ELSE 'Technician Assignment' END,
        'ticket_assignments',
        CAST(v_assignment_id AS CHAR),
        JSON_OBJECT('ticket_id', p_ticket_id, 'technician_id', p_technician_id, 'method', p_assignment_method),
        p_reason
    );

    COMMIT;
END$$

DROP PROCEDURE IF EXISTS sp_record_ai_correction$$
CREATE PROCEDURE sp_record_ai_correction(
    IN p_prediction_id BIGINT UNSIGNED,
    IN p_corrected_by BIGINT UNSIGNED,
    IN p_category_id BIGINT UNSIGNED,
    IN p_priority VARCHAR(20),
    IN p_risk_score DECIMAL(5,2),
    IN p_risk_level VARCHAR(20),
    IN p_skill_id BIGINT UNSIGNED,
    IN p_technician_id BIGINT UNSIGNED,
    IN p_reason VARCHAR(1000)
)
BEGIN
    DECLARE v_ticket_id BIGINT UNSIGNED;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT ticket_id INTO v_ticket_id
    FROM ai_predictions
    WHERE prediction_id = p_prediction_id
    FOR UPDATE;

    IF v_ticket_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Prediction not found';
    END IF;

    INSERT INTO ai_corrections(
        prediction_id, corrected_by, corrected_category_id, corrected_priority,
        corrected_risk_score, corrected_risk_level, corrected_skill_id,
        corrected_technician_id, reason
    ) VALUES(
        p_prediction_id, p_corrected_by, p_category_id, p_priority,
        p_risk_score, p_risk_level, p_skill_id, p_technician_id, p_reason
    );

    UPDATE ai_predictions
    SET review_status = 'Corrected'
    WHERE prediction_id = p_prediction_id;

    UPDATE maintenance_tickets
    SET current_category_id = COALESCE(p_category_id, current_category_id),
        current_priority = COALESCE(p_priority, current_priority),
        current_risk_score = COALESCE(p_risk_score, current_risk_score),
        current_risk_level = COALESCE(p_risk_level, current_risk_level),
        manual_review_required = FALSE
    WHERE ticket_id = v_ticket_id;

    INSERT INTO audit_logs(user_id, action_type, entity_type, entity_id, new_value, reason)
    VALUES(
        p_corrected_by,
        'AI Prediction Corrected',
        'ai_predictions',
        CAST(p_prediction_id AS CHAR),
        JSON_OBJECT(
            'category_id', p_category_id,
            'priority', p_priority,
            'risk_score', p_risk_score,
            'risk_level', p_risk_level,
            'skill_id', p_skill_id,
            'technician_id', p_technician_id
        ),
        p_reason
    );

    COMMIT;
END$$

DROP PROCEDURE IF EXISTS sp_mark_notification_read$$
CREATE PROCEDURE sp_mark_notification_read(
    IN p_notification_id BIGINT UNSIGNED,
    IN p_user_id BIGINT UNSIGNED
)
BEGIN
    UPDATE notifications
    SET read_at = CURRENT_TIMESTAMP,
        delivery_status = 'Read'
    WHERE notification_id = p_notification_id
      AND user_id = p_user_id;
END$$

DROP PROCEDURE IF EXISTS sp_recalculate_technician_workload$$
CREATE PROCEDURE sp_recalculate_technician_workload()
BEGIN
    UPDATE technician_profiles tp
    LEFT JOIN (
        SELECT technician_id, COUNT(*) AS active_jobs
        FROM ticket_assignments
        WHERE is_current = TRUE
          AND assignment_status IN ('Assigned','Accepted','In Progress','On Hold')
        GROUP BY technician_id
    ) x ON x.technician_id = tp.technician_id
    SET tp.current_workload = COALESCE(x.active_jobs, 0);
END$$

DELIMITER ;
