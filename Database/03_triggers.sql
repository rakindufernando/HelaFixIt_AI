-- HelaFixIt AI database triggers
USE helafixit_ai;

DELIMITER $$

DROP TRIGGER IF EXISTS trg_users_email_before_insert$$
CREATE TRIGGER trg_users_email_before_insert
BEFORE INSERT ON users
FOR EACH ROW
BEGIN
    SET NEW.email = LOWER(TRIM(NEW.email));
END$$

DROP TRIGGER IF EXISTS trg_users_email_before_update$$
CREATE TRIGGER trg_users_email_before_update
BEFORE UPDATE ON users
FOR EACH ROW
BEGIN
    SET NEW.email = LOWER(TRIM(NEW.email));
END$$

DROP TRIGGER IF EXISTS trg_ticket_number_before_insert$$
CREATE TRIGGER trg_ticket_number_before_insert
BEFORE INSERT ON maintenance_tickets
FOR EACH ROW
BEGIN
    IF NEW.ticket_number IS NULL OR TRIM(NEW.ticket_number) = '' THEN
        SET NEW.ticket_number = CONCAT(
            'TCK-',
            DATE_FORMAT(CURRENT_TIMESTAMP, '%y%m%d'),
            '-',
            UPPER(SUBSTRING(REPLACE(UUID(), '-', ''), 1, 8))
        );
    END IF;
END$$

DROP TRIGGER IF EXISTS trg_assignment_workload_after_insert$$
CREATE TRIGGER trg_assignment_workload_after_insert
AFTER INSERT ON ticket_assignments
FOR EACH ROW
BEGIN
    IF NEW.is_current = TRUE AND NEW.assignment_status IN ('Assigned','Accepted','In Progress','On Hold') THEN
        UPDATE technician_profiles
        SET current_workload = current_workload + 1
        WHERE technician_id = NEW.technician_id;
    END IF;
END$$

DROP TRIGGER IF EXISTS trg_assignment_workload_after_update$$
CREATE TRIGGER trg_assignment_workload_after_update
AFTER UPDATE ON ticket_assignments
FOR EACH ROW
BEGIN
    DECLARE old_active BOOLEAN DEFAULT FALSE;
    DECLARE new_active BOOLEAN DEFAULT FALSE;

    SET old_active = OLD.is_current = TRUE AND OLD.assignment_status IN ('Assigned','Accepted','In Progress','On Hold');
    SET new_active = NEW.is_current = TRUE AND NEW.assignment_status IN ('Assigned','Accepted','In Progress','On Hold');

    IF OLD.technician_id = NEW.technician_id THEN
        IF old_active = TRUE AND new_active = FALSE THEN
            UPDATE technician_profiles
            SET current_workload = GREATEST(current_workload - 1, 0)
            WHERE technician_id = NEW.technician_id;
        ELSEIF old_active = FALSE AND new_active = TRUE THEN
            UPDATE technician_profiles
            SET current_workload = current_workload + 1
            WHERE technician_id = NEW.technician_id;
        END IF;
    ELSE
        IF old_active = TRUE THEN
            UPDATE technician_profiles
            SET current_workload = GREATEST(current_workload - 1, 0)
            WHERE technician_id = OLD.technician_id;
        END IF;
        IF new_active = TRUE THEN
            UPDATE technician_profiles
            SET current_workload = current_workload + 1
            WHERE technician_id = NEW.technician_id;
        END IF;
    END IF;
END$$

DROP TRIGGER IF EXISTS trg_assignment_workload_after_delete$$
CREATE TRIGGER trg_assignment_workload_after_delete
AFTER DELETE ON ticket_assignments
FOR EACH ROW
BEGIN
    IF OLD.is_current = TRUE AND OLD.assignment_status IN ('Assigned','Accepted','In Progress','On Hold') THEN
        UPDATE technician_profiles
        SET current_workload = GREATEST(current_workload - 1, 0)
        WHERE technician_id = OLD.technician_id;
    END IF;
END$$

DELIMITER ;
